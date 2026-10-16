"""Separate-process traffic, administrator, backend-loss and predecessor proofs."""
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def eventually(check, label, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise AssertionError('Coordination deadline: ' + label)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def verify_coordination(root, native, upgrade, pg_migrate, admin, server, owned, proxy_factory, repair_arguments):
    with owned(root / 'delayed-writer', native, upgrade, pg_migrate, admin) as h:
        def pg(sql, success=True):
            return h.run(['psql','-XAt','-v','ON_ERROR_STOP=1','-c',sql], success=success).stdout.strip()
        h.begin()
        h.up(first=True)
        h.finish()
        h.sql('CREATE TABLE analytics.__pre_session_writer (id UInt8) ENGINE=MergeTree ORDER BY id')
        # Retain a real native INSERT across loss of the cooperating PG backend.
        # Its client can submit the actual rows later, after the traffic lock was
        # released. Neither empty rows nor backend disappearance is drain proof.
        holder = subprocess.Popen(['psql','-XAt','-v','ON_ERROR_STOP=1'], env=dict(h.env, PGAPPNAME='migration-pre-session-writer'), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        writer = subprocess.Popen(['clickhouse-client','--host','127.0.0.1','--port',h.env['CLICKHOUSE_TCP_PORT'],'--query_id','migration_presession_' + uuid.uuid4().hex,'--query','INSERT INTO analytics.__pre_session_writer FORMAT JSONEachRow'], env=h.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        begin = None
        service_process = None
        try:
            holder.stdin.write('SELECT pg_advisory_lock_shared(726401,1);\n')
            holder.stdin.flush()
            eventually(lambda: pg("SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING(pid) WHERE a.application_name='migration-pre-session-writer' AND l.locktype='advisory' AND l.classid=726401 AND l.objid=1 AND granted") == '1', 'pre-session traffic backend')
            writer.stdin.write('\n')
            writer.stdin.flush()
            eventually(lambda: h.sql("SELECT count() FROM system.processes WHERE query LIKE 'INSERT INTO analytics.__pre_session_writer%'").strip() == '1', 'native INSERT survives backend')
            begin = subprocess.Popen([native,'maintenance','begin','--json','--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned acceptance','--reason','pre-session writer drain'], env=h.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            eventually(lambda: pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1', 'fence persisted before traffic exclusion')
            pg("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='migration-pre-session-writer'")
            stdout, stderr = begin.communicate(timeout=40)
            (h.root / 'begin-after-backend-loss.private').write_text(stdout + stderr)
            assert begin.returncode == 0
            h.env['KANSOKU_CH_MIGRATION_SESSION'] = json.loads(stdout)['result']['id']
            h.run([upgrade,'--predecessor','0','up','--json','--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--actor','owned acceptance','--reason','no external drain yet'], success=False)
            assert h.sql("SELECT count() FROM system.tables WHERE database='analytics' AND name='__native_upgrade_probe'").strip() == '0'
            writer.stdin.write('{"id":7}\n')
            writer.stdin.close()
            writer.wait(timeout=20)
            assert writer.returncode == 0
            assert h.sql('SELECT count() FROM analytics.__pre_session_writer').strip() == '1'
            pg('SELECT kansoku.require_traffic_lock()', success=False)
            h.run([admin,'apply-retention','--confirm'], success=False)
            assert pg('SELECT count(*) FROM kansoku.maintenance_jobs') == '0'
            job = pg("INSERT INTO kansoku.maintenance_jobs(kind,scope) VALUES('retention','{}') RETURNING id") .splitlines()[0]
            h.run([admin,'resume-job','--id',job,'--confirm'], success=False)
            # HTTP admission exercises the actual Haskell session path as well
            # as the database-side admission above.
            write = h.run([admin,'issue-key','--kind','write','--account','migration-fence','--description','owned proof']).stdout.splitlines()[-2]
            service = h.run([admin,'issue-key','--kind','service','--account','migration-fence','--description','owned proof']).stdout.splitlines()[-2]
            from isolated_clickhouse import free_port
            port = free_port()
            with (h.root / 'service.private').open('w') as output:
                service_process = subprocess.Popen([server], env=dict(h.env,KANSOKU_SERVER_PORT=str(port),KANSOKU_QUEUE_NAME='mf_' + uuid.uuid4().hex[:16],OTEL_SDK_DISABLED='true'), stdout=output,stderr=output)
            base = 'http://127.0.0.1:' + str(port)
            def ready():
                assert service_process.poll() is None
                try:
                    return urllib.request.urlopen(base + '/health/ready',timeout=2).status == 200
                except (OSError, urllib.error.URLError):
                    return False
            eventually(ready,'fenced service readiness')
            for path, token, payload in [('/metrics/events?from=2026-07-01&to=2026-07-02',service,None),('/v1/events',write,dict(eventId='migration-fenced',eventName='page_view',schemaVersion=1,source='web',sourceService='migration-proof',occurredAt='2026-07-01T12:00:00Z',properties={'url':'/proof'},url='/proof'))]:
                headers = {'Authorization':'Bearer ' + token,'Content-Type':'application/json'}
                request = urllib.request.Request(base+path,headers=headers,data=None if payload is None else json.dumps(payload).encode())
                try:
                    urllib.request.urlopen(request,timeout=5)
                    raise AssertionError('Fenced HTTP operation was admitted')
                except urllib.error.HTTPError as error:
                    body = json.load(error)
                    assert error.code == 503 and body['code'] == 'maintenance_unavailable'
            stop(service_process)
            h.up(binary=upgrade)
            h.finish(binary=upgrade)
        finally:
            for process in (service_process, begin, writer, holder):
                if process is not None:
                    stop(process)
    with owned(root / 'process-loss', native, upgrade, pg_migrate, admin) as h:
        h.begin()
        h.up(first=True)
        n = h.drain()
        proxy = proxy_factory(h.endpoint)
        proxy.match = b'INSERT INTO analytics.__native_upgrade_probe VALUES'
        proxy.hold = True
        process = None
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            with (h.root / 'killed-entry.private').open('w') as output:
                process = subprocess.Popen([upgrade,'--predecessor',str(n),'up','--json',*h.audit()],env=h.env,stdout=output,stderr=output)
            assert proxy.triggered.wait(timeout=40), 'Native mutation did not reach the owned fault boundary'
            current = h.counter()
            # Both processes use real, fully authorized mutation inputs. They
            # must fail on held exclusion, before any competing native SQL.
            count = proxy.application_count()
            h.entry(['up'], binary=upgrade, predecessor=current, drain=False, success=False)
            h.run([admin,'apply-retention','--confirm'], success=False)
            assert proxy.application_count() == count
            process.kill()
            process.wait(timeout=10)
            h.entry(['up'], binary=upgrade, drain=False, success=False)
            assert proxy.application_count() == count
        finally:
            if process is not None:
                stop(process)
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        # Close every submitting client/proxy and restart before explicit recovery.
        h.entry(repair_arguments(h,'accept-step',True),binary=upgrade)
        h.entry(repair_arguments(h,'resume'),binary=upgrade)
        h.finish(binary=upgrade)
    with owned(root / 'surviving-mutation', native, upgrade, pg_migrate, admin) as h:
        h.begin()
        h.up(first=True)
        h.finish()
        h.sql('CREATE TABLE analytics.__native_survivor (id UInt8,value UInt8) ENGINE=MergeTree ORDER BY id')
        h.sql('INSERT INTO analytics.__native_survivor VALUES (1,0)')
        h.begin()
        n = h.drain()
        h.sql('SYSTEM STOP MERGES analytics.__native_survivor')
        extra = ['--proof-surviving-mutation']
        process = None
        try:
            with (h.root / 'killed-active-mutation.private').open('w') as output:
                process = subprocess.Popen([upgrade,*extra,'--predecessor',str(n),'up','--json',*h.audit()],env=h.env,stdout=output,stderr=output)
            eventually(lambda: h.sql("SELECT count() FROM system.mutations WHERE database='analytics' AND table='__native_survivor' AND NOT is_done").strip() == '1','synchronous native mutation admitted')
            snapshot = json.loads(h.run([upgrade,*extra,'status','--json']).stdout)['result']['report']
            migration = snapshot['migrations'][-1]
            attempt = migration['steps'][0]['attempt']
            query = attempt['queryId']
            process.kill()
            process.wait(timeout=10)
            assert h.sql("SELECT count() FROM system.processes WHERE query_id='"+query+"'").strip() == '1', 'Killed client must leave a demonstrably active server query'
            h.entry([*extra,'up'],binary=upgrade,drain=False,success=False)
            # Adversarial negative input: a false quiescence assertion cannot
            # override positive evidence of the retained active migration query.
            request = [upgrade,*extra,'--predecessor',str(h.counter()),'repair','accept-step','--json','--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--expect-position',snapshot['observation']['position'],'--attempt',migration['attempt'],'--step-attempt',attempt['ownerAttempt'],'--step',attempt['step'],'--query-id',query,'--actor','owned negative proof','--reason','deliberately false external evidence must refuse active query','--quiescent','--evidence','owned adversarial input, not a real drain attestation']
            result = json.loads(h.run(request,success=False).stdout)
            assert result['error']['primary']['code'] == 'prior-queries-active'
            h.sql('SYSTEM START MERGES analytics.__native_survivor')
            eventually(lambda: h.sql("SELECT count() FROM system.mutations WHERE database='analytics' AND table='__native_survivor' AND is_done").strip() == '1','positive native mutation completion')
            assert h.sql('SELECT value FROM analytics.__native_survivor').strip() == '1'
            h.observed_entry([*extra,*repair_arguments(h,'accept-step',True,extra)],binary=upgrade,expected_sql=0)
            h.observed_entry([*extra,*repair_arguments(h,'finalize',extra=extra)],binary=upgrade,expected_sql=0)
            assert h.sql('SELECT value FROM analytics.__native_survivor').strip() == '1'
            h.entry([*extra,'maintenance','finish'],binary=upgrade)
        finally:
            if process is not None:
                stop(process)
            import sys
            primary = sys.exc_info()[1]
            try:
                h.sql('SYSTEM START MERGES analytics.__native_survivor')
            except BaseException as cleanup:
                if primary is None:
                    raise
                (h.root / 'secondary-cleanup.private').write_text(type(cleanup).__name__)
    return 3
