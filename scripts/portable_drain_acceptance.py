#!/usr/bin/env python3
"""Owned producer/CLI consumer proof for portable drain attestations."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

from clickhouse_migrations_acceptance import owned
from test_support import binary


def verify(root, native, pg_migrate, admin):
    with owned(root, native, native, pg_migrate, '', access_management=True) as h:
        h.sql("CREATE USER runtime IDENTIFIED WITH no_password")
        h.sql("CREATE USER other_app IDENTIFIED WITH no_password")
        h.sql("GRANT SELECT ON system.one TO runtime, other_app")
        h.sql("GRANT SELECT ON system.numbers TO other_app")
        h.env['KANSOKU_CH_DRAIN_SUBMITTERS'] = json.dumps(['runtime', 'default'])
        h.begin()
        started = datetime.now(timezone.utc)
        # Let prior runtime work complete after blocking fresh connections.
        def client(user, query):
            return ['clickhouse-client', '--host', '127.0.0.1', '--port', h.env['CLICKHOUSE_TCP_PORT'], '--user', user, '--query', query]
        old = subprocess.Popen(client('runtime', 'SELECT sleep(2) FROM system.one'), env=h.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sentinel = subprocess.Popen(client('other_app', 'SELECT sleep(1) FROM system.numbers LIMIT 1000 SETTINGS max_block_size=1'), env=h.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while h.sql("SELECT count() FROM system.processes WHERE user='runtime'").strip() != '1':
                assert time.monotonic() < deadline, 'prior runtime request did not start'
                time.sleep(.05)
            h.sql('ALTER USER runtime HOST NONE')
            started = datetime.now(timezone.utc)
            h.run(client('runtime', 'SELECT 1 FROM system.one'), success=False)
            h.run(client('other_app', 'SELECT 1 FROM system.one'))
            old.communicate(timeout=10)
            assert old.returncode == 0
            server_pid = (root / 'clickhouse/pid').read_text()
            before = h.sql('SELECT toString(serverUUID()), toString(uptime())').strip().split('\t')
            now = datetime.now(timezone.utc)
            receipt = root / 'portable-drain.json'
            proof = b'owned runtime login exclusion; prior request completed; no scheduled submitters'
            (root / 'procedure.private').write_bytes(proof)
            document = dict(schemaVersion=1, target=h.env['KANSOKU_CH_MIGRATION_TARGET'],
                            servers=[h.env['KANSOKU_CH_MIGRATION_SERVER_ID']], ledger=h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],
                            databases=['analytics', 'kansoku_migration_ledger'], submitters=['runtime', 'default'],
                            availablePrincipals=['default'], owner=dict(kind='migration-session', id=h.env['KANSOKU_CH_MIGRATION_SESSION'], predecessor=0),
                            exclusionStartedAt=started.isoformat(), drainedAt=now.isoformat(), expiresAt=(now + timedelta(minutes=10)).isoformat(),
                            procedureReference=str(root / 'procedure.private'), procedureSha256=hashlib.sha256(proof).hexdigest(),
                            submittersBlocked=True, schedulesPaused=True, backgroundChangesSettled=True, operatorAttested=True)
            def entry(success):
                receipt.write_text(json.dumps(document))
                return h.run([native, '--predecessor', '0', '--drain-evidence', str(receipt), 'up', '--initialize-ledger', h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'], '--json', *h.audit()], success=success)
            document['owner']['predecessor'] = 1
            entry(False)
            assert h.counter() == 0
            document['owner']['predecessor'] = 0
            assert sentinel.poll() is None, sentinel.communicate()[1].decode()
            entry(True)
            assert h.counter() == 1
            retained = h.run(['psql', '-XAt', '-c', "SELECT quiescence->'drainEvidence'->'owner'->>'predecessor' FROM kansoku.clickhouse_migration_sessions"]).stdout.strip()
            assert retained == '0'
            original_digest = hashlib.sha256(receipt.read_bytes()).hexdigest()
            document['owner']['predecessor'] = 1
            receipt.write_text(json.dumps(document))
            h.run([native, '--predecessor', '1', '--drain-evidence', str(receipt), 'maintenance', 'reconcile', '--json', *h.audit()], success=False)
            assert h.counter() == 1
            document['drainedAt'] = datetime.now(timezone.utc).isoformat()
            receipt.write_text(json.dumps(document))
            h.run([native, '--predecessor', '1', '--drain-evidence', str(receipt), 'maintenance', 'reconcile', '--json', *h.audit()])
            audits = h.run(['psql', '-XAt', '-c', "SELECT entry::text || ':' || (evidence->>'drainEvidenceSha256') FROM kansoku.clickhouse_migration_entry_audit ORDER BY entry"]).stdout.strip().splitlines()
            assert audits == ['1:' + original_digest, '2:' + hashlib.sha256(receipt.read_bytes()).hexdigest()]
            h.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', 'ALTER TABLE kansoku.clickhouse_migration_entry_audit ADD CONSTRAINT owned_reject_entry CHECK (entry <> 3)'])
            document['owner']['predecessor'] = 2
            document['drainedAt'] = datetime.now(timezone.utc).isoformat()
            receipt.write_text(json.dumps(document))
            h.run([native, '--predecessor', '2', '--drain-evidence', str(receipt), 'maintenance', 'reconcile', '--json', *h.audit()], success=False)
            assert h.counter() == 2
            assert h.run(['psql', '-XAt', '-c', 'SELECT count(*) FROM kansoku.clickhouse_migration_entry_audit']).stdout.strip() == '2'
            h.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', 'ALTER TABLE kansoku.clickhouse_migration_entry_audit DROP CONSTRAINT owned_reject_entry'])


            assert sentinel.poll() is None, sentinel.communicate()[1].decode()
            h.run(client('other_app', 'SELECT 1 FROM system.one'))
            after = h.sql('SELECT toString(serverUUID()), toString(uptime())').strip().split('\t')
            assert (root / 'clickhouse/pid').read_text() == server_pid
            assert before[0] == after[0] and int(after[1]) >= int(before[1])
        finally:
            for process in (old, sentinel):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
    with owned(root / 'prepared-job', native, native, pg_migrate, '', access_management=True) as h:
        h.begin()
        h.up(first=True)
        h.finish()
        # Preparation must succeed even with an unavailable ClickHouse endpoint.
        env = dict(h.env, CLICKHOUSE_TCP_PORT='1')
        result = h.run([admin, 'apply-retention', '--prepare'], env=env)
        prepared = json.loads(result.stdout)
        assert prepared['next_attempt'] == 1 and prepared['stage'] == 'created'
        h.run([admin, 'apply-retention', '--prepare'], env=env, success=False)
        h.run([admin, 'apply-retention', '--prepare', '--confirm'], env=env, success=False)
        fence = h.run(['psql', '-XAt', '-c', "SELECT active_job::text FROM kansoku.maintenance_fence"]).stdout.strip()
        assert fence == prepared['job_id']
        now = datetime.now(timezone.utc)
        job_proof = b'fixture exclusively owns default and drain_admin submitters; no schedules; previous clients reaped before each attestation'
        job_procedure = h.root / 'procedure.private'
        job_procedure.write_bytes(job_proof)
        job_document = dict(document, procedureReference=str(job_procedure), procedureSha256=hashlib.sha256(job_proof).hexdigest(), target=h.env['KANSOKU_CH_MIGRATION_TARGET'],
                            servers=[h.env['KANSOKU_CH_MIGRATION_SERVER_ID']], ledger=h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],
                            submitters=['default'], owner=dict(kind='data-job', id=prepared['job_id'], attempt=2),
                            exclusionStartedAt=now.isoformat(), drainedAt=now.isoformat(), expiresAt=(now + timedelta(minutes=10)).isoformat())
        receipt = h.root / 'job-drain.json'
        receipt.write_text(json.dumps(job_document))
        env.update(KANSOKU_CH_DRAIN_SERVERS=json.dumps(job_document['servers']), KANSOKU_CH_DRAIN_SUBMITTERS='["default"]', KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS='["default"]')
        # Wrong next attempt refuses before discovery, preserving the fence.
        h.run([admin, 'resume-job', '--id', prepared['job_id'], '--confirm', '--drain-evidence', str(receipt)], env=env, success=False)
        state = h.run(['psql', '-XAt', '-c', "SELECT stage || ':' || native_attempt::text FROM kansoku.maintenance_jobs"]).stdout.strip()
        assert state == 'created:1'
        status = json.loads(h.run([admin, 'job-status', '--id', prepared['job_id']], env=env).stdout)
        assert status['next_attempt'] == 2 and status['fenced']
        # A visible earlier native INSERT contradicts a positive attestation.
        writer = subprocess.Popen(['clickhouse-client', '--host', '127.0.0.1', '--port', h.env['CLICKHOUSE_TCP_PORT'], '--query', 'INSERT INTO analytics.events_raw FORMAT JSONEachRow'], env=h.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            writer.stdin.write(b'\n')
            writer.stdin.flush()
            deadline = time.monotonic() + 10
            while h.sql("SELECT count() FROM system.processes WHERE query LIKE 'INSERT INTO analytics.events_raw%'").strip() != '1':
                assert time.monotonic() < deadline, 'prior INSERT did not start'
                time.sleep(.05)
            env['CLICKHOUSE_TCP_PORT'] = h.env['CLICKHOUSE_TCP_PORT']
            job_document['drainedAt'] = datetime.now(timezone.utc).isoformat()
            receipt.write_text(json.dumps(job_document))
            h.run([admin, 'resume-job', '--id', prepared['job_id'], '--confirm', '--drain-evidence', str(receipt)], env=env, success=False)
            state = h.run(['psql', '-XAt', '-c', "SELECT stage || ':' || native_attempt::text FROM kansoku.maintenance_jobs"]).stdout.strip()
            assert state == 'created:2'
        finally:
            writer.stdin.close()
            try:
                writer.wait(timeout=10)
            except subprocess.TimeoutExpired:
                writer.terminate()
                writer.wait(timeout=10)
        job_document['owner']['attempt'] = 3
        job_document['drainedAt'] = datetime.now(timezone.utc).isoformat()
        h.sql('CREATE USER drain_admin IDENTIFIED WITH no_password')
        h.sql('GRANT SELECT, INSERT, ALTER, CREATE TABLE, DROP TABLE, TRUNCATE, OPTIMIZE ON analytics.* TO drain_admin')
        h.sql('GRANT SELECT ON system.* TO drain_admin')
        h.sql('REVOKE SELECT ON system.processes FROM drain_admin')
        env['CLICKHOUSE_TCP_PORT'] = h.env['CLICKHOUSE_TCP_PORT']
        env['KANSOKU_CLICKHOUSE_USER'] = 'drain_admin'
        env['KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS'] = '["drain_admin"]'
        job_document['availablePrincipals'] = ['drain_admin']
        job_document['submitters'] = ['default', 'drain_admin']
        receipt.write_text(json.dumps(job_document))
        h.run(['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'], '--user', 'drain_admin', '--query', 'SELECT count() FROM system.processes'], env=env, success=False)
        result = h.run([admin, 'resume-job', '--id', prepared['job_id'], '--confirm', '--drain-evidence', str(receipt)], env=env)
        assert json.loads(result.stdout)['stage'] == 'complete'
        consumed = h.run(['psql', '-XAt', '-c', "SELECT drain_evidence->'owner'->>'attempt' FROM kansoku.maintenance_jobs"]).stdout.strip()
        assert consumed == '3'
        audit = h.run(['psql', '-XAt', '-c', "SELECT observations->0->>'result', evidence_sha256 FROM kansoku.maintenance_drain_attempts WHERE attempt=3"]).stdout.strip().split('|')
        assert audit == ['ObservationUnavailable', hashlib.sha256(receipt.read_bytes()).hexdigest()]
        # Erasure also refuses a denied process read without external evidence.
        refusal = h.run([admin, 'erase-user', '--account', 'portable', '--user', 'absent-subject', '--confirm'], env=env, success=False)
        assert 'prepared with fence retained' in refusal.stderr
        latest = json.loads(h.run([admin, 'list-jobs', '--limit', '1'], env=env).stdout)[0]
        prepared = dict(job_id=latest['id'])
        h.run([admin, 'resume-job', '--id', prepared['job_id'], '--confirm'], env=env, success=False)
        status = json.loads(h.run([admin, 'job-status', '--id', prepared['job_id']], env=env).stdout)
        assert status['next_attempt'] == 2 and status['stage'] == 'created' and status['fenced']
        # Grant only SELECT, retaining the absence of SHOW PROCESSLIST. The own
        # user view remains supplementary, never global drain authority.
        h.sql('GRANT SELECT ON system.processes TO drain_admin')
        now = datetime.now(timezone.utc)
        job_document.update(owner=dict(kind='data-job', id=prepared['job_id'], attempt=2), exclusionStartedAt=now.isoformat(), drainedAt=now.isoformat(), expiresAt=(now + timedelta(minutes=10)).isoformat())
        receipt.write_text(json.dumps(job_document))
        result = h.run([admin, 'resume-job', '--id', prepared['job_id'], '--confirm', '--drain-evidence', str(receipt)], env=env)
        assert json.loads(result.stdout)['stage'] == 'complete'

    print('portable drain: 2 owned producer/consumer cases, 0 failures, 0 skipped', flush=True)
    return 2


def verify_repair(root, native, upgrade, pg_migrate, admin):
    from clickhouse_migrations_acceptance import FaultProxy, repair_arguments
    for visible in (False, True):
        with owned(root / ('own-user' if visible else 'denied'), native, upgrade, pg_migrate, admin, access_management=True) as h:
            h.begin()
            h.up(first=True)
            h.sql('CREATE USER scoped_migrator IDENTIFIED WITH no_password')
            h.sql('GRANT SELECT, INSERT, ALTER, CREATE TABLE, DROP TABLE, CREATE VIEW, DROP VIEW ON analytics.* TO scoped_migrator')
            h.sql('GRANT SELECT, INSERT ON kansoku_migration_ledger.* TO scoped_migrator')
            for table in ['databases','tables','columns','storage_policies','disks']:
                h.sql('GRANT SELECT ON system.' + table + ' TO scoped_migrator')
            if visible:
                h.sql('GRANT SELECT ON system.processes TO scoped_migrator')
            h.sql('CREATE USER other_app IDENTIFIED WITH no_password')
            h.sql('GRANT SELECT ON system.one TO other_app')
            h.sql('GRANT SELECT ON system.numbers TO other_app')
            sentinel = subprocess.Popen(['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--user','other_app','--query','SELECT sleep(1) FROM system.numbers LIMIT 1000 SETTINGS max_block_size=1'],env=h.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            pid = (h.root / 'clickhouse/pid').read_text()
            try:
                # The fixture admits no runtime or scheduled submitters. Each
                # CLI is synchronous and joined before the next entry. The
                # operator retains exclusive submission rights for this app;
                # unrelated other_app remains admitted throughout.
                h.controller['drain'] = lambda: None
                h.controller['drain_procedure'] = 'Owned app has no runtime or scheduled submitters. All prior CLI processes joined; the operator exclusively controls default and scoped_migrator credentials. App-scoped background changes are settled by the backup producer. Unrelated other_app remains admitted; no server restart.'
                h.controller['submitters'] = ['default','scoped_migrator']
                h.env['KANSOKU_CLICKHOUSE_USER'] = 'scoped_migrator'
                h.env['KANSOKU_CLICKHOUSE_PASSWORD'] = ''
                h.drain()
                proxy = FaultProxy(h.endpoint)
                proxy.match = b'INSERT INTO analytics.__native_upgrade_probe VALUES'
                try:
                    h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
                    h.up(binary=upgrade, success=False, drain=False)
                    assert proxy.triggered.is_set()
                finally:
                    proxy.close()
                    h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
                args = repair_arguments(h,'accept-step',True)
                expected = 'no-visible-recorded-queries' if visible else 'unavailable'
                # An audit write failure must block authorization and SQL.
                before = json.loads(h.run([upgrade,'status','--guarded','--json']).stdout)['result']['report']['observation']['position']
                h.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',"ALTER TABLE kansoku.clickhouse_repair_observations ADD CONSTRAINT owned_reject_observation CHECK (false)"])
                h.observed_entry(args,binary=upgrade,success=False,expected_sql=0)
                after = json.loads(h.run([upgrade,'status','--guarded','--json']).stdout)['result']['report']['observation']['position']
                assert before == after
                h.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c','ALTER TABLE kansoku.clickhouse_repair_observations DROP CONSTRAINT owned_reject_observation'])
                h.observed_entry(args,binary=upgrade,expected_sql=0)
                rows = h.run(['psql','-XAt','-c',"SELECT observation->>'state' FROM kansoku.clickhouse_repair_observations ORDER BY id"]).stdout.strip().splitlines()
                assert rows == [expected]
                observed_count = h.run(['psql','-XAt','-c',"SELECT observation->'activeCount' FROM kansoku.clickhouse_repair_observations"]).stdout.strip()
                assert observed_count == ('0' if visible else 'null')
                status = json.loads(h.run([native,'maintenance','status','--json']).stdout)['result']
                assert status['repair_observation']['entry'] == status['entry']
                assert status['repair_observation']['observation'] == dict(state=expected, activeCount=0 if visible else None)
                count = h.counter()
                h.observed_entry(args,binary=upgrade,success=False,expected_sql=0)
                assert h.counter() == count + 1
                assert h.run(['psql','-XAt','-c','SELECT count(*) FROM kansoku.clickhouse_repair_observations']).stdout.strip() == '1'
                h.observed_entry(repair_arguments(h,'resume'),binary=upgrade,expected_sql=1)
                h.finish(binary=upgrade)
                assert h.run(['psql','-XAt','-c','SELECT count(*)=2 AND count(DISTINCT entry)=2 FROM kansoku.clickhouse_repair_observations']).stdout.strip() == 't'
                assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
                assert (h.root / 'clickhouse/pid').read_text() == pid
                assert sentinel.poll() is None
                h.run(['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--user','other_app','--query','SELECT 1 FROM system.one'])
            finally:
                if sentinel.poll() is None:
                    sentinel.terminate()
                sentinel.communicate(timeout=10)
    return 2


if __name__ == '__main__':
    parent = Path('.dev/acceptance')
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='portable-drain-', dir=parent)).resolve()
    print('Private portable drain evidence: ' + str(root), flush=True)
    verify(root, binary('kansoku-server:exe:kansoku-ch-migrate'), binary('kansoku-server:exe:kansoku-migrate'), binary('kansoku-server:exe:kansoku-admin'))
