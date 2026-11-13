#!/usr/bin/env python3
"""Actual three-store backup/restore proof on a fresh owned direct fixture."""
from datetime import datetime, timezone
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import uuid

from clickhouse_migrations_acceptance import owned, FaultProxy, repair_arguments
from drain_evidence_fixture import run_maintenance, write_evidence
from test_support import binary


def verify(root, native, upgrade, pg_migrate, admin, interrupted=False):
    with owned(root, native, upgrade, pg_migrate, admin, access_management=True, backups=True) as h:
        def pg(sql, env=None):
            return h.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', sql], env=env).stdout.strip()
        h.begin()
        h.up(first=True)
        h.finish()
        event = dict(event_id='recovery-before', event_name='page_view', account_id='recovery', source='web', source_service='recovery-web', occurred_at='2026-11-13 12:00:00.000', received_at='2026-11-13 12:00:01.000', user_id='recovery-user', anonymous_id='recovery-cookie', session_id='recovery-session', properties='{"url":"/before"}', context='{}', identifiers='{}')
        h.sql('INSERT INTO analytics.events_raw FORMAT JSONEachRow', input=json.dumps(event))
        pg("SELECT pgmq.create('recovery_queue')")
        queued = dict(eventId='queued-before', eventName='page_view', accountId='recovery', source='web', sourceService='recovery-web', occurredAt='2026-11-13T12:00:00Z', receivedAt='2026-11-13T12:00:01Z', schemaVersion=1, properties={'url':'/queued'}, context={})
        # This ASCII/integer-only payload has the same canonical bytes under
        # RFC8785; delivery/authentication clocks are excluded by acceptance.
        stable = {key:value for key,value in queued.items() if key not in ('accountId','receivedAt','sentAt')}
        digest = hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(',',':')).encode()).hexdigest()
        pg("INSERT INTO kansoku.accepted_events(account_id,event_id,producer_payload_hash) VALUES('recovery','queued-before','" + digest + "')")
        pg("SELECT pgmq.send('recovery_queue','" + json.dumps(queued).replace("'", "''") + "'::jsonb,0)")
        pg("INSERT INTO kansoku.event_dispositions(account_id,event_id,scrub_identity) VALUES('recovery','reserved-before',true)")
        retained = run_maintenance([admin,'apply-retention','--confirm'], env=dict(h.env,KANSOKU_EVENTS_RETENTION_DAYS='365'), producer='Backup fixture owns and has joined every native submitter; no runtime consumer is started', capture_output=True,text=True,timeout=180)
        assert retained.returncode == 0, retained.stderr
        h.begin()
        pending_receipt = None
        if interrupted:
            h.drain()
            proxy = FaultProxy(h.endpoint)
            proxy.match = (b'step-succeeded',b'finish-probe')
            try:
                h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
                lost = json.loads(h.up(binary=upgrade,success=False,drain=False).stdout)
                assert proxy.triggered.is_set()
                pending_receipt = lost['error']['primary']['pendingAppend']
                assert pending_receipt
            finally:
                proxy.close()
                h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
            h.drain()
        h.sql('SYSTEM STOP TTL MERGES analytics.events_raw')
        assert h.sql("SELECT count() FROM system.mutations WHERE database='analytics' AND NOT is_done").strip() == '0'
        h.sql('CREATE USER recovery_other_app IDENTIFIED WITH no_password')
        h.sql('GRANT SELECT ON system.one TO recovery_other_app')
        h.sql('GRANT SELECT ON system.numbers TO recovery_other_app')
        client = ['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--user','recovery_other_app','--query']
        other = subprocess.Popen(client + ['SELECT sleep(1) FROM system.numbers LIMIT 1000 SETTINGS max_block_size=1'], env=h.env, stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        (root/'other-app.pid').write_text(str(other.pid))
        try:
            server_pid = (root/'clickhouse/pid').read_text()
            evidence = root/'migration-drain.json'
            predecessor = h.counter()
            settings = write_evidence(evidence,h.env,dict(kind='migration-session',id=h.env['KANSOKU_CH_MIGRATION_SESSION'],predecessor=predecessor),'Fixture owns all native submitters and all preceding synchronous writes completed; no runtime/schedules exist; unrelated application remains available.')
            context = json.loads(h.run([upgrade,'maintenance','recovery-context','--json'],env=settings).stdout)['result']
            assert context['fenced'] and context['predecessor'] == predecessor
            operation = [*repair_arguments(h,'finalize'),'--pending-append',pending_receipt] if interrupted else ['up']
            command = [upgrade,'--predecessor',str(predecessor),'--drain-evidence',str(evidence),*operation,'--json','--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned recovery proof','--reason','post-backup native suffix','--quiescent','--evidence',str(evidence)]
            if not interrupted:
                missing = h.run(command,env=settings,success=False)
                assert '--recovery-set FILE required' in missing.stderr and h.counter() == predecessor

            session_status = json.loads(h.run([native,'maintenance','status','--json']).stdout)['result']
            session_status.pop('repair_observation')
            stored_session = json.loads(pg('SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s WHERE completed_at IS NULL'))
            assert session_status == stored_session
            observation_query = "SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY id),'[]'::jsonb) FROM kansoku.clickhouse_repair_observations o"
            point = dict(session=stored_session, repair_observations=pg(observation_query), policy=json.loads(pg('SELECT to_jsonb(p) FROM kansoku.retention_policy p')), accepted=pg('SELECT row_to_json(a) FROM kansoku.accepted_events a ORDER BY account_id,event_id'), queue=pg('SELECT message::text FROM pgmq.q_recovery_queue ORDER BY msg_id'), dispositions=pg('SELECT row_to_json(d) FROM kansoku.event_dispositions d ORDER BY account_id,event_id'), raw=h.sql('SELECT event_id,account_id,user_id,properties FROM analytics.events_raw ORDER BY event_id'), canonical=h.sql('SELECT event_id,account_id FROM analytics.events_canonical ORDER BY event_id'))
            def ledger(database):
                names = h.sql("SELECT name FROM system.tables WHERE database='" + database + "' ORDER BY name").strip().splitlines()
                return {name:h.sql('SELECT * FROM `' + database + '`.`' + name.replace('`','``') + '` ORDER BY tuple(*) FORMAT JSONEachRow') for name in names}
            point['ledger'] = ledger('kansoku_migration_ledger')
            point['ledgerObservation'] = json.loads(h.run([upgrade,'maintenance','recovery-observation','--json']).stdout)['result']
            started = datetime.now(timezone.utc).isoformat()
            dump = root/'postgres.dump'
            h.run(['pg_dump','--format=custom','--file',str(dump)])
            postgres_done = datetime.now(timezone.utc).isoformat()
            # A real native backup failure after PostgreSQL completed must not
            # create authority to apply the suffix or release the fence.
            failed_backup = h.run(['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--query',"BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('missing_recovery_disk','partial.zip')"], success=False)
            assert failed_backup.returncode != 0 and dump.is_file()
            if not interrupted:
                h.run(command,env=settings,success=False)
            assert h.counter() == predecessor
            assert pg('SELECT active_migration_session::text FROM kansoku.maintenance_fence') == h.env['KANSOKU_CH_MIGRATION_SESSION']
            h.sql("BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('kansoku_backups','point.zip')")
            clickhouse_done = datetime.now(timezone.utc).isoformat()
            archive = Path(h.env['KANSOKU_OWNED_CLICKHOUSE_BACKUP_ROOT'])/'point.zip'
            assert dump.is_file() and archive.is_file()
            migration_started = datetime.now(timezone.utc).isoformat()
            pg_receipt = root/'postgres-verification.private'
            pg_receipt.write_text(json.dumps(dict(exitCode=0,format='pg_dump custom',sha256=hashlib.sha256(dump.read_bytes()).hexdigest())))
            ch_receipt = root/'clickhouse-verification.private'
            ch_receipt.write_text(json.dumps(dict(status='BACKUP_CREATED',sha256=hashlib.sha256(archive.read_bytes()).hexdigest())))
            def snapshot(store,database,begin,end,artifact,receipt):
                return dict(store=store,database=database,startedAt=begin,completedAt=end,artifactReference=str(artifact),artifactSha256=hashlib.sha256(artifact.read_bytes()).hexdigest(),verificationReference=str(receipt),verificationSha256=hashlib.sha256(receipt.read_bytes()).hexdigest(),complete=True)
            manifest = {key:context[key] for key in ['target','servers','ledger','session','predecessor','planSha256','postgresDatabase','retentionPolicy','coordinatorState']}
            manifest.update(schemaVersion=1,id=str(uuid.uuid4()),drainSha256=hashlib.sha256(evidence.read_bytes()).hexdigest(),stableFrom=started,stableUntil=json.loads(evidence.read_text())['expiresAt'],coordinatorSnapshotPhase='fenced-before-native-entry',backgroundChangesSettled=True,operatorAttested=True,snapshots=[snapshot('postgresql',context['postgresDatabase'],started,postgres_done,dump,pg_receipt),snapshot('clickhouse','analytics',postgres_done,clickhouse_done,archive,ch_receipt),snapshot('clickhouse','kansoku_migration_ledger',postgres_done,clickhouse_done,archive,ch_receipt)])
            recovery_file = root/'recovery-set.json'
            valid_snapshots = manifest['snapshots']
            manifest['snapshots'] = valid_snapshots[:2]
            recovery_file.write_text(json.dumps(manifest))
            h.run([command[0],'--recovery-set',str(recovery_file),*command[1:]],env=settings,success=False)
            assert h.counter() == predecessor and ledger('kansoku_migration_ledger') == point['ledger']
            manifest['snapshots'] = valid_snapshots
            recovery_file.write_text(json.dumps(manifest))
            h.run([command[0],'--recovery-set',str(recovery_file),*command[1:]],env=settings)
            accepted = json.loads(pg("SELECT to_jsonb(r) FROM kansoku.maintenance_recovery_sets r WHERE session_id='"+h.env['KANSOKU_CH_MIGRATION_SESSION']+"' ORDER BY predecessor DESC LIMIT 1"))
            assert accepted['kind'] == 'snapshot' and accepted['document_sha256'] == hashlib.sha256(recovery_file.read_bytes()).hexdigest()

            migration_done = datetime.now(timezone.utc).isoformat()
            assert ledger('kansoku_migration_ledger') != point['ledger']
            # Deliberate post-point changes prove the restores did not just read
            # current live state or back up one database independently later.
            pg("INSERT INTO kansoku.accepted_events(account_id,event_id,producer_payload_hash) VALUES('recovery','after','" + 'f'*64 + "')")
            event['event_id'] = 'recovery-after'
            h.sql('INSERT INTO analytics.events_raw FORMAT JSONEachRow',input=json.dumps(event))

            h.run(['createdb','--template=template0','recovery_restored'])
            restored = dict(h.env, PGDATABASE='recovery_restored')
            h.run(['pg_restore','--dbname=recovery_restored','--no-owner','--exit-on-error',str(dump)],env=restored)
            h.sql("RESTORE DATABASE analytics AS recovery_analytics, DATABASE kansoku_migration_ledger AS recovery_ledger FROM Disk('kansoku_backups','point.zip')")
            assert json.loads(pg('SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s WHERE completed_at IS NULL',restored)) == point['session']
            assert pg(observation_query,restored) == point['repair_observations']
            assert json.loads(pg('SELECT to_jsonb(p) FROM kansoku.retention_policy p',restored)) == point['policy']
            assert pg('SELECT row_to_json(a) FROM kansoku.accepted_events a ORDER BY account_id,event_id',restored) == point['accepted']
            assert pg('SELECT message::text FROM pgmq.q_recovery_queue ORDER BY msg_id',restored) == point['queue']
            assert pg('SELECT row_to_json(d) FROM kansoku.event_dispositions d ORDER BY account_id,event_id',restored) == point['dispositions']
            assert pg('SELECT active_migration_session::text FROM kansoku.maintenance_fence',restored) == h.env['KANSOKU_CH_MIGRATION_SESSION']
            assert h.sql('SELECT event_id,account_id,user_id,properties FROM recovery_analytics.events_raw ORDER BY event_id') == point['raw']
            assert h.sql('SELECT event_id,account_id FROM recovery_analytics.events_canonical ORDER BY event_id') == point['canonical']
            assert ledger('recovery_ledger') == point['ledger']
            assert h.sql("SELECT count() FROM system.tables WHERE database='recovery_analytics' AND name='__native_upgrade_probe'").strip() == ('1' if interrupted else '0')
            assert other.poll() is None, other.communicate()[1].decode()
            h.run(client+['SELECT 1 FROM system.one'])
            assert (root/'clickhouse/pid').read_text() == server_pid
            with owned(root/'rebuilt',native,upgrade,pg_migrate,admin,backups=True) as rebuilt:
                new_server = rebuilt.env['KANSOKU_CH_MIGRATION_SERVER_ID']
                old_server = h.env['KANSOKU_CH_MIGRATION_SERVER_ID']
                assert new_server != old_server
                rebuilt.run(['pg_restore','--dbname=postgres','--clean','--if-exists','--no-owner','--exit-on-error',str(dump)])
                shutil.copyfile(archive,Path(rebuilt.env['KANSOKU_OWNED_CLICKHOUSE_BACKUP_ROOT'])/'point.zip')
                rebuilt.sql("RESTORE DATABASE analytics, DATABASE kansoku_migration_ledger FROM Disk('kansoku_backups','point.zip')")
                for key in ('KANSOKU_CH_MIGRATION_TARGET','KANSOKU_CH_MIGRATION_LEDGER_ID','KANSOKU_CH_MIGRATION_SESSION'):
                    rebuilt.env[key] = h.env[key]
                # Editing the UUID cannot load the original owner or acquire its
                # lease. Adoption is a separate, explicit audited operation.
                rebuilt.run([upgrade,'maintenance','status','--json'],success=False)
                owner = dict(kind='migration-session',id=h.env['KANSOKU_CH_MIGRATION_SESSION'],predecessor=predecessor)
                current_drain = root/'rebuilt-drain.json'
                rebuilt_settings = write_evidence(current_drain,rebuilt.env,owner,'Fixture owns the rebuilt server and every client; full three-store restore completed synchronously and no runtime/schedules are started.')
                observation = json.loads(rebuilt.run([upgrade,'maintenance','recovery-observation','--json']).stdout)['result']
                assert observation['ledgerSha256'] == point['ledgerObservation']['ledgerSha256']
                restored_receipt = root/'live-restore.json'
                receipt = dict(schemaVersion=1,mode='live-recovery',target=h.env['KANSOKU_CH_MIGRATION_TARGET'],oldServer=old_server,newServer=new_server,ledger=h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],session=owner['id'],recoverySetId=manifest['id'],recoverySetSha256=hashlib.sha256(recovery_file.read_bytes()).hexdigest(),ledgerSha256=observation['ledgerSha256'],inspectedAt=datetime.now(timezone.utc).isoformat(),expiresAt=json.loads(current_drain.read_text())['expiresAt'],allStoresRestored=True,operatorAttested=True)
                restored_receipt.write_text(json.dumps(receipt))
                rebind = [upgrade,'--recovery-set',str(recovery_file),'--drain-evidence',str(current_drain),'maintenance','rebind','--json','--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--old-server',old_server,'--new-server',new_server,'--original-drain',str(evidence),'--restore-verification',str(restored_receipt),'--actor','owned recovery proof','--reason','verified rebuilt three-store restore','--evidence',str(restored_receipt)]
                receipt['mode'] = 'scratch-inspection'
                restored_receipt.write_text(json.dumps(receipt))
                rebuilt.run(rebind,env=rebuilt_settings,success=False)
                receipt['mode'] = 'live-recovery'
                restored_receipt.write_text(json.dumps(receipt))
                rebound = json.loads(rebuilt.run(rebind,env=rebuilt_settings).stdout)['result']
                replay = json.loads(rebuilt.run(rebind,env=rebuilt_settings).stdout)['result']
                assert rebound == replay
                status = json.loads(rebuilt.run([upgrade,'maintenance','status','--json']).stdout)['result']
                retained_observation = status.pop('repair_observation')
                assert (retained_observation is None) == (json.loads(point['repair_observations']) == [])
                restored_observations = rebuilt.run(['psql','-XAtc',observation_query]).stdout.strip()
                assert json.loads(restored_observations) == json.loads(point['repair_observations'])
                expected_session = dict(point['session'],server_id=new_server)
                assert status == expected_session
                assert rebuilt.sql('SELECT event_id,account_id,user_id,properties FROM analytics.events_raw ORDER BY event_id') == point['raw']
                assert rebuilt.run(['psql','-XAtc','SELECT active_migration_session::text FROM kansoku.maintenance_fence']).stdout.strip() == owner['id']
                assert rebuilt.run(['psql','-XAtc','SELECT count(*) FROM kansoku.clickhouse_server_rebindings']).stdout.strip() == '1'
                wrong = list(rebind)
                wrong[wrong.index('--old-server')+1] = str(uuid.uuid4())
                rebuilt.run(wrong,env=rebuilt_settings,success=False)
                if interrupted:
                    assert pending_receipt in status['pending_receipts'] and status['outcome'] == 'failed'
                    rebuilt.up(binary=upgrade,success=False)
                    rebuilt.entry(repair_arguments(rebuilt,'finalize'),binary=upgrade,success=False)
                    rebuilt.entry([*repair_arguments(rebuilt,'finalize'),'--pending-append',pending_receipt],binary=upgrade)
                    rebuilt.finish(binary=upgrade)
            ordering=dict(migrationInvokedAt=migration_started,migrationCompletedAt=migration_done,started=started,postgresCompletedAt=postgres_done,clickhouseCompletedAt=clickhouse_done,postgresSha256=hashlib.sha256(dump.read_bytes()).hexdigest(),clickhouseSha256=hashlib.sha256(archive.read_bytes()).hexdigest(),coverage=['postgresql/kansoku+pgmq','clickhouse/analytics','clickhouse/kansoku_migration_ledger'],restoredAgreement=True,serverRestarted=False)
            (root/'ordering.private.json').write_text(json.dumps(ordering,indent=2))
        finally:
            if other.poll() is None:
                other.terminate()
                other.wait(timeout=10)
    print('recovery roundtrip ('+('interrupted' if interrupted else 'clean')+'): 1 owned three-store case, 0 failures, 0 skipped',flush=True)
    return 1


if __name__ == '__main__':
    os.umask(0o077)
    parent=Path('.dev/acceptance')
    parent.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='recovery-',dir=parent)).resolve()
    print('Private recovery evidence: '+str(root),flush=True)
    executables = [binary('kansoku-server:exe:kansoku-ch-migrate'),subprocess.check_output(['cabal','list-bin','kansoku-server:exe:kansoku-ch-migrate-upgrade-proof','-fmigration-acceptance-probe'],text=True).strip(),binary('kansoku-server:exe:kansoku-migrate'),binary('kansoku-server:exe:kansoku-admin')]
    verify(root/'clean',*executables)
    verify(root/'interrupted',*executables,interrupted=True)
