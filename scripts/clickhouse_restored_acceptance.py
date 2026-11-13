#!/usr/bin/env python3
"""Owned read-only inspection of genuinely renamed native backup restores."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import urllib.parse
import uuid

from clickhouse_migrations_acceptance import owned
from drain_evidence_fixture import run_maintenance
from test_support import binary


class ReadCapture:
    def __init__(self, endpoint):
        upstream = urllib.parse.urlsplit(endpoint)
        self.requests = []
        self.responses = []
        owner = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_):
                pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length',0)))
                owner.requests.append(body)
                connection = http.client.HTTPConnection(upstream.hostname,upstream.port,timeout=35)
                try:
                    connection.request('POST',self.path,body=body,headers={'Authorization':self.headers.get('Authorization','')})
                    response=connection.getresponse()
                    payload=response.read()
                    owner.responses.append(dict(status=response.status,error=payload.decode(errors='replace') if response.status != 200 else None))
                    self.send_response(response.status)
                    self.send_header('Content-Length',str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                finally:
                    connection.close()
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()
        self.endpoint='http://127.0.0.1:'+str(self.server.server_address[1])

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)


def verify_namespace(root,native,upgrade,pg_migrate,admin):
    cases=1
    with owned(root,native,upgrade,pg_migrate,admin,access_management=True,backups=True) as h:
        h.begin()
        h.up(first=True)
        context=json.loads(h.run([native,'maintenance','recovery-context','--json']).stdout)['result']
        event=dict(event_id='restored-before',event_name='page_view',account_id='restored',source='web',source_service='restored-web',occurred_at='2026-11-13 12:00:00.000',received_at='2026-11-13 12:00:01.000',user_id='restored-user',anonymous_id='',session_id='restored-session',properties='{}',context='{}',identifiers='{}')
        h.sql('INSERT INTO analytics.events_raw FORMAT JSONEachRow',input=json.dumps(event))
        h.sql("BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('kansoku_backups','restored.zip')")
        h.sql("RESTORE DATABASE analytics AS analytics_restore, DATABASE kansoku_migration_ledger AS kansoku_migration_ledger_restore FROM Disk('kansoku_backups','restored.zip')")
        h.sql('CREATE USER restored_verifier IDENTIFIED WITH no_password')
        for database in ('analytics_restore','kansoku_migration_ledger_restore'):
            h.sql('GRANT SELECT ON '+database+'.* TO restored_verifier')
        for table in ('databases','tables','columns','storage_policies','disks','users'):
            h.sql('GRANT SELECT ON system.'+table+' TO restored_verifier')
        # Public inspection sets bounded synchronous query settings; mode 2
        # permits those settings while still prohibiting every write.
        h.sql('ALTER USER restored_verifier SETTINGS readonly=2')
        env={key:value for key,value in h.env.items() if not key.startswith(('PG','CLICKHOUSE','KANSOKU_'))}
        env.update(KANSOKU_CH_RESTORE_USER='restored_verifier',KANSOKU_CH_RESTORE_PASSWORD='')
        capture=ReadCapture(h.endpoint)
        try:
            command=[native,'verify-restored','--json','--endpoint',capture.endpoint,'--server',h.env['KANSOKU_CH_MIGRATION_SERVER_ID'],'--original-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--original-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],'--application-database','analytics_restore','--ledger-database','kansoku_migration_ledger_restore','--expect-plan-sha256',context['planSha256'],'--expected-definer','default']
            valid=json.loads(h.run(command,env=env,success=False).stdout)['result']
            assert valid['ledger']==dict(compatible=True,current=True,unresolved=False)
            assert valid['schema']['status']=='incomplete' and not valid['authorizedForMutation']
            policy=root/'expected-policy.json'
            policy.write_text(json.dumps(context['retentionPolicy']))
            command += ['--expected-policy',str(policy)]
            complete=json.loads(h.run(command,env=env).stdout)['result']
            assert complete['schema']['matches'] and complete['ledger']['current']
            live_metadata=h.sql("SELECT name,create_table_query FROM system.tables WHERE database IN ('analytics','kansoku_migration_ledger') ORDER BY database,name FORMAT JSONEachRow")
            live_data=h.sql('SELECT event_id,account_id FROM analytics.events_raw ORDER BY event_id')
            for option,replacement in [('--original-ledger',str(uuid.uuid4())),('--server',str(uuid.uuid4())),('--original-target','foreign/original'),('--ledger-database','kansoku_migration_ledger_restore_missing')]:
                wrong=list(command)
                wrong[wrong.index(option)+1]=replacement
                result=json.loads(h.run(wrong,env=env,success=False).stdout)['result']
                assert not result['ledger']['compatible']
            for option,replacement in [('--application-database','analytics'),('--ledger-database','kansoku_migration_ledger'),('--application-database','bad; DROP DATABASE analytics'),('--ledger-database','analytics_restore')]:
                wrong=list(command)
                wrong[wrong.index(option)+1]=replacement
                h.run(wrong,env=env,success=False)
            def mapped(app,ledger,policy_file=policy):
                result=list(command)
                for flag,value in [('--application-database',app),('--ledger-database',ledger),('--expected-policy',str(policy_file))]:
                    result[result.index(flag)+1]=value
                return result
            def restore_copy(suffix,archive='restored.zip'):
                app='analytics_restore_'+suffix
                ledger='kansoku_migration_ledger_restore_'+suffix
                h.sql("RESTORE DATABASE analytics AS "+app+", DATABASE kansoku_migration_ledger AS "+ledger+" FROM Disk('kansoku_backups','"+archive+"')")
                for database in (app,ledger):
                    h.sql('GRANT SELECT ON '+database+'.* TO restored_verifier')
                return app,ledger
            variants=[
                ('type',["ALTER TABLE {app}.retention_policy MODIFY COLUMN cutoff DateTime64(6,'UTC')"],'column metadata: retention_policy'),
                ('default',["ALTER TABLE {app}.events_raw MODIFY COLUMN source String DEFAULT 'changed'"],'definition: events_raw'),
                ('view',["DROP VIEW {app}.organization_traits"],'missing object: organization_traits'),
                ('engine',["RENAME TABLE {app}.retention_policy TO {app}.retention_policy_saved","CREATE TABLE {app}.retention_policy(singleton UInt8,revision UInt64,cutoff DateTime64(3,'UTC')) ENGINE=MergeTree ORDER BY singleton","INSERT INTO {app}.retention_policy VALUES(1,0,'1970-01-01 00:00:00')"],'retention_policy/engine'),
                ('key',["RENAME TABLE {app}.retention_policy TO {app}.retention_policy_saved","CREATE TABLE {app}.retention_policy(singleton UInt8,revision UInt64,cutoff DateTime64(3,'UTC')) ENGINE=ReplacingMergeTree(revision) ORDER BY (singleton,revision)","INSERT INTO {app}.retention_policy VALUES(1,0,'1970-01-01 00:00:00')"],'retention_policy/sorting_key'),
                ('reference',["CREATE OR REPLACE VIEW {app}.events_canonical AS SELECT * FROM analytics.events_canonical"],'definition: events_canonical'),
                ('extra',["CREATE VIEW {app}.analytics_literal_probe AS SELECT 'analytics.events_raw' AS literal,1 AS analytics_extra"],'extra object: analytics_literal_probe'),
            ]
            for label,changes,expected_mismatch in variants:
                app,ledger=restore_copy(label)
                for sql in changes:
                    h.sql(sql.format(app=app))
                report=json.loads(h.run(mapped(app,ledger),env=env,success=False).stdout)['result']
                assert report['ledger']['current'] and expected_mismatch in report['schema']['mismatches'],label
                assert h.sql("SELECT name,create_table_query FROM system.tables WHERE database IN ('analytics','kansoku_migration_ledger') ORDER BY database,name FORMAT JSONEachRow")==live_metadata
                assert h.sql('SELECT event_id,account_id FROM analytics.events_raw ORDER BY event_id')==live_data
                cases+=1
            h.sql('CREATE USER restored_ledger_only IDENTIFIED WITH no_password')
            h.sql('GRANT SELECT ON kansoku_migration_ledger_restore.* TO restored_ledger_only')
            for table in ('databases','tables','columns','storage_policies','disks','users'):
                h.sql('GRANT SELECT ON system.'+table+' TO restored_ledger_only')
            h.sql('ALTER USER restored_ledger_only SETTINGS readonly=2')
            h.run(command,env=dict(env,KANSOKU_CH_RESTORE_USER='restored_ledger_only'),success=False)
            cases+=1

            # Supported administration changes TTL deliberately. Its trusted
            # policy, rather than observed TTL text, determines equivalence.
            h.finish()
            retained=run_maintenance([admin,'apply-retention','--confirm'],env=dict(h.env,KANSOKU_EVENTS_RETENTION_DAYS='365'),producer='Owned schema fixture has joined every client and has no runtime or external schedules.',capture_output=True,text=True,timeout=180)
            assert retained.returncode==0,retained.stderr
            h.sql('SYSTEM STOP TTL MERGES analytics.events_raw')
            current_policy=json.loads(h.run(['psql','-XAtc','SELECT to_jsonb(p) FROM kansoku.retention_policy p']).stdout)
            operated_policy=root/'operated-policy.json'
            operated_policy.write_text(json.dumps(current_policy))
            h.sql("BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('kansoku_backups','operated.zip')")
            app,ledger=restore_copy('operated','operated.zip')
            operated=mapped(app,ledger,operated_policy)
            operated_report=json.loads(h.run(operated,env=env).stdout)['result']
            assert operated_report['schema']['matches']
            wrong_policy=root/'foreign-policy.json'
            wrong_policy.write_text(json.dumps(dict(current_policy,cutoff='2000-01-01T00:00:00Z')))
            h.run(mapped(app,ledger,wrong_policy),env=env,success=False)
            h.sql('ALTER TABLE '+app+'.events_raw MODIFY TTL toDateTime(occurred_at)+INTERVAL 1 DAY')
            h.run(operated,env=env,success=False)
            cases+=1
            assert capture.requests and all(body.lstrip().upper().startswith(b'SELECT') for body in capture.requests)
            (root/'inspection-requests.private.json').write_text(json.dumps([body.decode() for body in capture.requests]))
            assert h.sql('SELECT count() FROM analytics.events_raw').strip()=='1'
            assert h.sql('SELECT count() FROM analytics_restore.events_raw').strip()=='1'
            # The role independently denies writes even if a future implementation
            # accidentally tries one; capture above proves none was attempted.
            h.run(['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--user','restored_verifier','--query','CREATE TEMPORARY TABLE forbidden_probe (x UInt8)'],success=False)
        finally:
            (root/'inspection-requests.private.json').write_text(json.dumps([body.decode() for body in capture.requests]))
            (root/'inspection-responses.private.json').write_text(json.dumps(capture.responses))
            capture.close()
    print('restored inspection: '+str(cases)+' owned read-only cases, 0 failures, 0 skipped',flush=True)
    return cases


def verify_prefix(root,native,upgrade,pg_migrate,admin):
    with owned(root,native,upgrade,pg_migrate,admin,access_management=True,backups=True) as h:
        h.begin()
        h.entry(['--proof-historical-prefix','up','--initialize-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID']],binary=upgrade)
        context=json.loads(h.run([native,'maintenance','recovery-context','--json']).stdout)['result']
        h.sql("BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('kansoku_backups','prefix.zip')")
        h.sql("RESTORE DATABASE analytics AS analytics_restore, DATABASE kansoku_migration_ledger AS kansoku_migration_ledger_restore FROM Disk('kansoku_backups','prefix.zip')")
        h.sql('CREATE USER prefix_verifier IDENTIFIED WITH no_password')
        for database in ('analytics_restore','kansoku_migration_ledger_restore'):
            h.sql('GRANT SELECT ON '+database+'.* TO prefix_verifier')
        for table in ('databases','tables','columns','storage_policies','disks','users'):
            h.sql('GRANT SELECT ON system.'+table+' TO prefix_verifier')
        h.sql('ALTER USER prefix_verifier SETTINGS readonly=2')
        policy=root/'expected-policy.json'
        policy.write_text(json.dumps(context['retentionPolicy']))
        env={key:value for key,value in h.env.items() if not key.startswith(('PG','CLICKHOUSE','KANSOKU_'))}
        env.update(KANSOKU_CH_RESTORE_USER='prefix_verifier',KANSOKU_CH_RESTORE_PASSWORD='')
        capture=ReadCapture(h.endpoint)
        try:
            command=[native,'verify-restored','--json','--endpoint',capture.endpoint,'--server',h.env['KANSOKU_CH_MIGRATION_SERVER_ID'],'--original-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--original-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],'--application-database','analytics_restore','--ledger-database','kansoku_migration_ledger_restore','--expect-plan-sha256',context['planSha256'],'--expected-definer','default','--expected-policy',str(policy)]
            report=json.loads(h.run(command,env=env,success=False).stdout)['result']
            assert report['ledger']==dict(compatible=True,current=False,unresolved=False)
            assert capture.requests and all(body.lstrip().upper().startswith(b'SELECT') for body in capture.requests)
            (root/'inspection-requests.private.json').write_text(json.dumps([body.decode() for body in capture.requests]))
        finally:
            capture.close()
    print('restored prefix: 1 owned read-only case, 0 failures, 0 skipped',flush=True)
    return 1


if __name__=='__main__':
    os.umask(0o077)
    root=Path(tempfile.mkdtemp(prefix='restored-inspection-',dir='.dev/acceptance')).resolve()
    print('Private restored evidence: '+str(root),flush=True)
    executables=[binary('kansoku-server:exe:kansoku-ch-migrate'),subprocess.check_output(['cabal','list-bin','kansoku-server:exe:kansoku-ch-migrate-upgrade-proof','-fmigration-acceptance-probe'],text=True).strip(),binary('kansoku-server:exe:kansoku-migrate'),binary('kansoku-server:exe:kansoku-admin')]
    verify_namespace(root/'current',*executables)
    verify_prefix(root/'prefix',*executables)
