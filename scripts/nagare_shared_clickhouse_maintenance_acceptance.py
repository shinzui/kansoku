#!/usr/bin/env python3
"""Run the actual reviewed Nagare ceremony on an explicitly prepared owned local fixture."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import threading
import time
import urllib.parse
import uuid

from clickhouse_migrations_acceptance import FaultProxy, repair_arguments
from clickhouse_restored_acceptance import ReadCapture
from enrichment_acceptance import event
from nagare_maintenance_fixture import connected, drain_evidence, nagare, reviewed, secret
from shared_clickhouse_maintenance_acceptance import runtime, request, issue, eventually, pg, snapshot_point


def native_client(h, credential, query):
    return ['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],
            '--user',credential['CLICKHOUSE_USER'],'--password',credential['CLICKHOUSE_PASSWORD'],'--query',query]


class OtherApplication:
    def __init__(self,h,credentials):
        self.h,self.credential=h,credentials['other_runtime']
        self.name='ep53_'+uuid.uuid4().hex[:12]
        work=self.name+'_work'
        h.query_as(credentials['other_migration'],'CREATE TABLE other_app.'+self.name+' (value UInt64) ENGINE=MergeTree ORDER BY value')
        h.query_as(credentials['other_migration'],'INSERT INTO other_app.'+self.name+' VALUES (7)')
        h.query_as(credentials['other_migration'],'CREATE TABLE other_app.'+work+' (n UInt64) ENGINE=MergeTree ORDER BY n')
        h.query_as(credentials['other_migration'],'INSERT INTO other_app.'+work+' FORMAT TSV',input=''.join(str(n)+'\n' for n in range(10000)))
        self.identity=h.process_identity()
        self.grants=h.sql('SHOW GRANTS FOR '+self.credential['CLICKHOUSE_USER'])
        self.long=subprocess.Popen(native_client(h,self.credential,'SELECT sleepEachRow(0.1) FROM numbers(10000) SETTINGS max_block_size=1'),env=h.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        eventually(lambda:h.sql("SELECT count() FROM system.processes WHERE user='"+self.credential['CLICKHOUSE_USER']+"'").strip()=='1','other app long query reaches server')
        self.stop=threading.Event();self.failures=[];self.samples=0;self.closed=False
        self.thread=threading.Thread(target=self.poll,daemon=True);self.thread.start()

    def poll(self):
        while not self.stop.is_set():
            try:
                p=subprocess.run(native_client(self.h,self.credential,'SELECT sum(value) FROM other_app.'+self.name),env=self.h.env,capture_output=True,text=True,timeout=5)
                if p.returncode or p.stdout.strip()!='7':self.failures.append('other app fresh query failed')
                self.samples+=1
            except BaseException as error:self.failures.append(type(error).__name__)
            self.stop.wait(.5)

    def checkpoint(self,label):
        assert self.long.poll() is None, 'other app long query ended at '+label
        assert not self.failures,self.failures
        assert self.h.query_as(self.credential,'SELECT * FROM other_app.'+self.name+' FORMAT TSV').stdout.strip()=='7'
        assert self.h.process_identity()==self.identity,'shared server process changed'
        assert self.h.sql('SHOW GRANTS FOR '+self.credential['CLICKHOUSE_USER'])==self.grants
        with (self.h.root/'availability.jsonl').open('a') as out:out.write(json.dumps(dict(phase=label,samples=self.samples,failures=0,identity=self.identity))+'\n')

    def close(self):
        if self.closed:return
        self.stop.set();self.thread.join(timeout=10);assert not self.thread.is_alive()
        if self.long.poll() is None:self.long.terminate()
        self.long.communicate(timeout=10)
        self.closed=True
        assert not self.failures,self.failures


def seed(h,binaries,credentials):
    with runtime(h,binaries,credential=credentials['runtime'],postgres=credentials['pg_runtime']) as (base,_):
        write,service=issue(h,binaries['admin'],'write'),issue(h,binaries['admin'],'service')
        now=datetime.now(timezone.utc)
        for identifier,user,days in [('shared','shared-user',0),('keep','kept-user',0),('old','old-user',120)]:
            payload=event('nagare-'+identifier,'nagare-'+identifier,timestamp=(now-timedelta(days=days)).isoformat())
            payload.update(schemaVersion=1,userId=user,context={})
            request(base,'/v1/events',write,payload,expected=202)
        parameters={'from':(now-timedelta(days=1)).date().isoformat(),'to':(now+timedelta(days=1)).date().isoformat(),'timeGrain':'none',
                    'filter':json.dumps(dict(dimension='user_id',op='eq',value='shared-user'))}
        eventually(lambda:sum(p['value'] for p in request(base,'/metrics/events?'+urllib.parse.urlencode(parameters),service)['points'])==1,'real Nagare runtime cache metric')
        eventually(lambda:h.sql("SELECT count() FROM analytics.events_raw WHERE account_id='shared-proof'").strip()=='3','real Nagare writer inserts')
        h.begin()
        request(base,'/metrics/events?'+urllib.parse.urlencode(parameters),service,expected=503)
    return now,service


def object_bytes(h,url):
    parsed=urllib.parse.urlsplit(url)
    assert parsed.scheme=='s3' and parsed.netloc=='nagare-backups'
    assert parsed.path.startswith('/app-databases/personal/')
    command=['kubectl','--kubeconfig',str(Path(h.kube[2])),'-n','nagare-system','exec','ep53-object-reader','--',
        'sh','-c','mc alias set local http://minio.nagare-system.svc.cluster.local:9000 "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" >/dev/null; exec mc cat "$1"','sh','local/'+parsed.netloc+parsed.path]
    return subprocess.check_output(command,timeout=60)


def backup(h,root,app,label):
    began=datetime.now(timezone.utc).isoformat()
    backup_id=uuid.uuid4().hex[:10]
    reviewed(root,label+'-backup','db','app-database','backup',app,'-n','personal','--backup-id',backup_id)
    name='nagare-appdb-'+app+'-'+backup_id
    job=json.loads(subprocess.check_output(h.kube+['get','job',name,'-o','json']))
    assert job['status'].get('succeeded')==1,'backup Job did not complete'
    uid=job['metadata']['uid']
    reviewed(root,label+'-ingest','db','app-database','backup-receipts',app,'-n','personal','--backup-id',uid)
    evidence=json.loads(nagare(root,'db','app-database','evidence',app,'-n','personal','--json'))
    retained=h.root/(label+'-nagare-evidence.json');retained.write_text(json.dumps(evidence))
    assert evidence['backup']['backupId']==uid
    archive=object_bytes(h,evidence['backup']['object'])
    receipt=object_bytes(h,evidence['backup']['receipt'])
    signed=json.loads(receipt)
    assert hashlib.sha256(archive).hexdigest()==signed['payload']['sha256']
    assert signed['payload']['jobUid']==uid and signed['payload']['object']==evidence['backup']['object']
    artifact=h.root/(label+'.gz');artifact.write_bytes(archive)
    verification=h.root/(label+'.receipt.json');verification.write_bytes(receipt)
    done=datetime.now(timezone.utc).isoformat()
    return dict(uid=uid,app=app,started=began,completed=done,artifact=artifact,receipt=verification,evidence=retained)


def recovery_manifest(h,context,drain,backups,root):
    def snapshot(source,store,database):
        return dict(store=store,database=database,startedAt=source['started'],completedAt=source['completed'],
            artifactReference=str(source['artifact']),artifactSha256=hashlib.sha256(source['artifact'].read_bytes()).hexdigest(),
            verificationReference=str(source['receipt']),verificationSha256=hashlib.sha256(source['receipt'].read_bytes()).hexdigest(),complete=True)
    document={key:context[key] for key in ['target','servers','ledger','session','predecessor','planSha256','postgresDatabase','retentionPolicy','coordinatorState']}
    snapshots=[snapshot(backups[0],'postgresql',context['postgresDatabase'])]
    if len(backups)>1:snapshots.extend(snapshot(backups[1],'clickhouse',db) for db in ['analytics','kansoku_migration_ledger'])
    document.update(schemaVersion=1,id=str(uuid.uuid4()),drainSha256=hashlib.sha256(drain.read_bytes()).hexdigest(),stableFrom=backups[0]['started'],
        stableUntil=json.loads(drain.read_text())['expiresAt'],coordinatorSnapshotPhase='fenced-before-native-entry',
        backgroundChangesSettled=True,operatorAttested=True,snapshots=snapshots)
    path=h.root/('recovery-'+uuid.uuid4().hex+'.json');path.write_text(json.dumps(document));return path


def entry(h,root,credentials,arguments,manifest=None,success=True):
    drain,settings,owner=drain_evidence(h,root,credentials)
    command=[h.upgrade,'--predecessor',str(owner['predecessor']),'--drain-evidence',str(drain)]
    if manifest:command+=['--recovery-set',str(manifest)]
    return h.run(command+arguments+['--json',*h.audit()],env=settings,success=success)


def data_job(h,root,binaries,credentials,arguments,event_days=None):
    settings=dict(h.env)
    if event_days is not None:settings['KANSOKU_EVENTS_RETENTION_DAYS']=str(event_days)
    prepared=json.loads(h.run([binaries['admin'],*arguments,'--prepare'],env=settings).stdout)
    status=json.loads(h.run([binaries['admin'],'job-status','--id',prepared['job_id']],env=settings).stdout)
    pg(h,'SELECT pg_advisory_lock(726401,1)')
    drain,settings,_=drain_evidence(h,root,credentials,job=dict(kind='data-job',id=prepared['job_id'],attempt=status['next_attempt']))
    if event_days is not None:settings['KANSOKU_EVENTS_RETENTION_DAYS']=str(event_days)
    result=json.loads(h.run([binaries['admin'],'resume-job','--id',prepared['job_id'],'--confirm','--drain-evidence',str(drain)],env=settings).stdout)
    assert result['stage']=='complete'


def verifier_config(h,root):
    databases=['analytics_restore_ep53','kansoku_migration_ledger_restore_ep53']
    objects=[]
    for database in databases:
        objects.extend((database.removesuffix('_restore_ep53'),name) for name in h.sql("SELECT name FROM system.tables WHERE database='"+database+"' ORDER BY name").splitlines())
    assert objects
    pairs='['+','.join('('+json.dumps(db)+','+json.dumps(table)+')' for db,table in objects)+']'
    declaration=r"""
verificationReader :: AppDatabaseReader
verificationReader = AppDatabaseReader
 { name = ok (mkReaderName "verifier")
 , objects = case map (\(db,table) -> ReaderRestoredRelation (ok (mkLogicalDatabaseName db)) "ep53" (ok (mkRelationName table))) PAIRS of
     x:xs -> x:|xs
     [] -> error "empty verifier inventory"
 , limits = defaultReaderLimits ClickHouse
 , consumers = []
 , retired = False
 , exceptions = [SystemDatabases,SystemTables,SystemColumns,SystemDisks,SystemStoragePolicies,SystemUserNames]
 }
""".replace('PAIRS',pairs)
    text=(root/'AppDatabases.hs').read_text()
    text=text.replace('mkNamespace)','mkNamespace,mkReaderName)')
    text,count=re.subn(r'(?m)^(\s*)& #runtime \.~',r'\1& #readers .~ [verificationReader]\n\1& #runtime .~',text)
    assert count==1, 'Expected one ClickHouse runtime access declaration'
    text+=declaration
    config=root/'AppDatabasesWithVerifier.hs';config.write_text(text);return config


def inspect(h,binaries,credential,policy,definer):
    captured=h.root/'restored-policy.json';captured.write_text(json.dumps(policy))
    metadata=json.loads(h.run([binaries['native'],'restored-expectations','--json']).stdout)['result']
    env={key:value for key,value in h.env.items() if not key.startswith(('PG','CLICKHOUSE','KANSOKU_'))}
    env.update(KANSOKU_CH_RESTORE_USER=credential['CLICKHOUSE_USER'],KANSOKU_CH_RESTORE_PASSWORD=credential['CLICKHOUSE_PASSWORD'])
    capture=ReadCapture(h.endpoint)
    try:
        command=[binaries['native'],'verify-restored','--json','--endpoint',capture.endpoint,'--server',h.env['KANSOKU_CH_MIGRATION_SERVER_ID'],
            '--original-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--original-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],
            '--application-database','analytics_restore_ep53','--ledger-database','kansoku_migration_ledger_restore_ep53',
            '--expect-plan-sha256',metadata['planSha256'],'--expected-definer',definer,'--expected-policy',str(captured)]
        report=json.loads(h.run(command,env=env).stdout)['result']
        assert report['schema']['matches'] and report['ledger']==dict(compatible=True,current=True,unresolved=False)
        assert not report['authorizedForMutation']
        h.query_as(credential,'SELECT auth_params FROM system.users',success=False)
        h.query_as(credential,'CREATE TEMPORARY TABLE forbidden (id UInt8)',success=False)
        h.query_as(credential,'TRUNCATE TABLE analytics_restore_ep53.events_raw',success=False)
        assert not h.query_as(credential,"SELECT create_table_query FROM system.tables WHERE database='other_app'").stdout.strip()
        h.sql('ALTER TABLE analytics_restore_ep53.events_raw ADD COLUMN unreviewed UInt8 DEFAULT 1')
        drift=json.loads(h.run(command,env=env,success=False).stdout)['result']
        assert drift['ledger']['current'] and not drift['schema']['matches']
        assert capture.requests and all(body.lstrip().upper().startswith(b'SELECT') for body in capture.requests)
        (h.root/'verifier-queries.private.json').write_text(json.dumps([body.decode() for body in capture.requests]))
    finally:capture.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--resume-fenced',action='store_true',help='Resume the same retained pre-entry owner after a failed fixture phase')
    args=parser.parse_args();os.umask(0o077);root=args.root.resolve()
    with connected(root) as (h,binaries,credentials):
        other=OtherApplication(h,credentials)
        try:
            other.checkpoint('before-runtime')
            if args.resume_fenced:
                status=json.loads(h.run([h.native,'maintenance','status','--json']).stdout)['result']
                assert status['completed_at'] is None and status['entry']==0
                h.env['KANSOKU_CH_MIGRATION_SESSION']=status['id']
                assert h.sql("SELECT count() FROM analytics.events_raw WHERE account_id='shared-proof'").strip()=='3'
                now,service=datetime.now(timezone.utc),None
            else:
                now,service=seed(h,binaries,credentials)
            other.checkpoint('real-writer-cache-and-persistent-fence')
            # Runtime-only platform quiesce deliberately cannot exclude an
            # earlier writable client using the migration credential.
            external=subprocess.Popen(native_client(h,credentials['migration'],'INSERT INTO analytics.events_raw FORMAT JSONEachRow'),env=h.env,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                external.stdin.write('\n');external.stdin.flush()
                eventually(lambda:h.sql("SELECT count() FROM system.processes WHERE user='"+credentials['migration']['CLICKHOUSE_USER']+"' AND query_kind='Insert'").strip()=='1','earlier migrator reaches server')
                for app,suffix in [('kansoku-ch-app','ch'),('kansoku-pg-app','pg')]:
                    schedule=json.loads(subprocess.check_output(h.kube+['get','cronjob','nagare-appdb-'+app,'-o','json']))
                    if args.resume_fenced and schedule['spec'].get('suspend') is True:
                        existing=json.loads(nagare(root,'db','app-database','evidence',app,'-n','personal','--json'))
                        assert existing['drain'] is not None
                    else:
                        reviewed(root,h.root.name+'-quiesce-'+suffix,'db','app-database','quiesce',app,'-n','personal','--users','runtime')
                assert external.poll() is None,'runtime-only quiesce must not claim migration-client drain'
                refused=h.query_as(credentials['migration'],'SELECT query FROM system.processes',success=False)
                assert 'Code: 497' in refused.stderr
                h.run([h.upgrade,'up','--json',*h.audit()],success=False);assert h.counter()==0
            finally:
                external.stdin.close();external.wait(timeout=20);assert external.returncode==0
            other.checkpoint('runtime-only-gap-refused-and-full-client-drain')
            drain,settings,owner=drain_evidence(h,root,credentials)
            context=json.loads(h.run([h.upgrade,'maintenance','recovery-context','--json']).stdout)['result']
            point=snapshot_point(h)
            point['nativeLedger']=[json.loads(row) for row in h.sql('SELECT * FROM kansoku_migration_ledger.events ORDER BY sequence FORMAT JSONEachRow').splitlines()]
            pg_backup=backup(h,root,'kansoku-pg-app',h.root.name+'-pg')
            partial=recovery_manifest(h,context,drain,[pg_backup],root)
            h.run([h.upgrade,'--drain-evidence',str(drain),'--predecessor','0','--recovery-set',str(partial),'up','--json',*h.audit()],env=settings,success=False)
            assert h.counter()==0 and h.sql("SELECT count() FROM system.tables WHERE database='analytics' AND name='__native_upgrade_probe'").strip()=='0'
            ch_backup=backup(h,root,'kansoku-ch-app',h.root.name+'-ch')
            manifest=recovery_manifest(h,context,drain,[pg_backup,ch_backup],root)
            other.checkpoint('complete-platform-receipts-before-native-entry')
            proxy=FaultProxy(h.endpoint);proxy.match=b'INSERT INTO analytics.__native_upgrade_probe VALUES'
            try:
                h.env['KANSOKU_CH_MIGRATION_ENDPOINT']=proxy.endpoint
                h.run([h.upgrade,'--drain-evidence',str(drain),'--predecessor','0','--recovery-set',str(manifest),'up','--json',*h.audit()],env=dict(settings,KANSOKU_CH_MIGRATION_ENDPOINT=proxy.endpoint),success=False)
                assert proxy.triggered.is_set()
            finally:proxy.close();h.env['KANSOKU_CH_MIGRATION_ENDPOINT']=h.endpoint
            entry(h,root,credentials,repair_arguments(h,'accept-step',True))
            entry(h,root,credentials,repair_arguments(h,'resume'))
            h.run([h.upgrade,'verify','--require-current','--guarded','--json'])
            entry(h,root,credentials,['maintenance','finish'])
            other.checkpoint('explicit-repair-with-denied-diagnostics')
            data_job(h,root,binaries,credentials,['apply-retention'],event_days=30)
            assert h.sql("SELECT count() FROM analytics.events_raw WHERE account_id='shared-proof'").strip()=='2'
            data_job(h,root,binaries,credentials,['erase-user','--account','shared-proof','--user','shared-user','--delete-events'])
            assert h.sql("SELECT user_id FROM analytics.events_raw WHERE account_id='shared-proof'").strip()=='kept-user'
            other.checkpoint('scoped-retention-and-erasure')
            # Finish the platform restore/verification phase below; a failure
            # deliberately leaves the platform quiesced for explicit recovery.
            (h.root/'checkpoint.private.json').write_text(json.dumps(dict(manifest=str(manifest),backups=[{k:str(v) for k,v in b.items()} for b in [pg_backup,ch_backup]],point=point,now=now.isoformat(),service=service)))
            for item,suffix in [(pg_backup,'pg'),(ch_backup,'ch')]:
                reviewed(root,h.root.name+'-restore-'+suffix,'db','app-database','restore',item['app'],'-n','personal','--backup-id',item['uid'],'--restore-id','ep53')
            saved=h.env
            try:
                h.env=dict(saved,PGDATABASE='kansoku_restore_ep53',PG_CONNECTION_STRING=saved['PG_CONNECTION_STRING'].replace('dbname=kansoku','dbname=kansoku_restore_ep53'))
                restored=snapshot_point(h)
                restored['raw']=[json.loads(row) for row in h.sql('SELECT * FROM analytics_restore_ep53.events_raw ORDER BY event_id FORMAT JSONEachRow').splitlines()]
                restored['nativeLedger']=[json.loads(row) for row in h.sql('SELECT * FROM kansoku_migration_ledger_restore_ep53.events ORDER BY sequence FORMAT JSONEachRow').splitlines()]
                assert restored==point,'actual Nagare three-store restores differ from their common point'
            finally:h.env=saved
            other.checkpoint('actual-platform-three-store-restores')
            # Kansoku's session/jobs have completed. Platform resume can now
            # restore its normal declarations; clients remain held by the fixture.
            for app,suffix in [('kansoku-ch-app','ch'),('kansoku-pg-app','pg')]:
                reviewed(root,h.root.name+'-resume-'+suffix,'db','app-database','resume',app,'-n','personal')
            config=verifier_config(h,root)
            reviewed(root,h.root.name+'-verifier','db','app-database','plan','--config',str(config))
            verifier=secret(h.kube,'kansoku-ch-app-reader-verifier')
            inspect(h,binaries,verifier,json.loads(manifest.read_text())['retentionPolicy'],credentials['migration']['CLICKHOUSE_USER'])
            other.checkpoint('readonly-restored-schema-and-matching-history-drift')
            if service is None:service=issue(h,binaries['admin'],'service')
            with runtime(h,binaries,credential=credentials['runtime'],postgres=credentials['pg_runtime']) as (base,_):
                parameters={'from':(now-timedelta(days=1)).date().isoformat(),'to':(now+timedelta(days=1)).date().isoformat(),'timeGrain':'none'}
                report=request(base,'/metrics/events?'+urllib.parse.urlencode(parameters),service)
                assert sum(p['value'] for p in report['points'])==1
            other.checkpoint('deliberate-runtime-resume-after-completed-jobs')
            replan=nagare(root,'db','app-database','plan','--config',str(config))
            assert replan.strip()=='no operations',replan
            other.checkpoint('final-no-drift')
            other.close()
            assert not args.resume_fenced, 'Recovered development phases passed; a fresh continuous full ceremony is still required for release evidence'
            (h.root/'sanitized').mkdir()
            (h.root/'sanitized/nagare-maintenance.log').write_text('1 complete owned local Nagare ceremony; 0 failures; 0 skipped; actual reviewed grants/quiesce/backups/restores; continuous other-app queries and unchanged server process; final grant re-plan has no operations\n')
            print('Nagare local shared maintenance: 1 complete ceremony, 0 failures, 0 skipped; final re-plan has no operations',flush=True)
            print('Private Nagare ceremony evidence: '+str(h.root),flush=True)
        finally:other.close()


if __name__=='__main__':main()
