#!/usr/bin/env python3
"""Owned shared-server principal and maintenance qualification; never ambient stores."""
import argparse
import hashlib
import shutil
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from admin_acceptance import owned_process
from clickhouse_migrations_acceptance import owned, packaged_binaries, FaultProxy, repair_arguments
from clickhouse_restored_acceptance import ReadCapture
from drain_evidence_fixture import write_evidence
from isolated_clickhouse import free_port
from enrichment_acceptance import event

PRINCIPALS = ['default', 'runtime', 'migrator', 'data_admin', 'reader', 'verifier']
METADATA = ['databases', 'tables', 'columns', 'storage_policies', 'disks']


def eventually(check, label, seconds=40):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.2)
    raise AssertionError('Shared maintenance deadline: ' + label)


def client(h, user, sql):
    return ['clickhouse-client', '--host', '127.0.0.1', '--port', h.env['CLICKHOUSE_TCP_PORT'],
            '--user', user, '--query', sql]


def install_principals(h, own_processes=False):
    grants = {name: [] for name in PRINCIPALS if name != 'default'}
    for name in grants:
        h.sql('CREATE USER ' + name + ' IDENTIFIED WITH no_password')
    def grant(name, privilege, scope):
        sql = 'GRANT ' + privilege + ' ON ' + scope + ' TO ' + name
        h.sql(sql)
        grants[name].append(sql)
    for database in ['analytics', 'kansoku_migration_ledger']:
        grant('migrator', 'SELECT, INSERT, CREATE DATABASE, CREATE TABLE, CREATE VIEW, ALTER TABLE, ALTER VIEW, DROP TABLE, DROP VIEW, TRUNCATE', database + '.*')
    grant('runtime', 'SELECT', 'analytics.*')
    grant('runtime', 'INSERT', 'analytics.events_raw')
    grant('runtime', 'CREATE ARBITRARY TEMPORARY TABLE', '*.*')
    grant('data_admin', 'SELECT, INSERT, ALTER DELETE, ALTER UPDATE, ALTER TTL, TRUNCATE', 'analytics.*')
    grant('data_admin', 'ALTER MATERIALIZE COLUMN', 'analytics.events_raw')
    for name in ['runtime', 'migrator', 'data_admin', 'verifier']:
        for table in METADATA if name in ['migrator', 'verifier'] else ['databases', 'tables']:
            grant(name, 'SELECT', 'system.' + table)
    grant('runtime', 'SELECT(database,table,name,active)', 'system.parts')
    grant('data_admin', 'SELECT', 'system.columns')
    grant('data_admin', 'SELECT', 'system.mutations')
    grant('verifier', 'SELECT(name)', 'system.users')
    for table in ['events_resolved', 'events_resolved_v3', 'events_analytics_v1']:
        grant('reader', 'SELECT', 'analytics.' + table)
    if own_processes:
        for name in ['runtime', 'migrator', 'data_admin']:
            grant(name, 'SELECT', 'system.processes')
        policy = 'CREATE ROW POLICY scoped_processes ON system.processes FOR SELECT USING user=currentUser() TO runtime, migrator, data_admin'
        h.sql(policy)
        grants['operator_policies'] = [policy]
    for database in ['analytics_restore', 'kansoku_migration_ledger_restore']:
        grant('verifier', 'SELECT', database + '.*')
    h.sql('ALTER USER reader SETTINGS readonly=2')
    h.sql('ALTER USER verifier SETTINGS readonly=2')
    (h.root / 'principal-grants.json').write_text(json.dumps(grants, indent=2))
    return grants


class OtherApplication:
    def __init__(self, h):
        self.h = h
        self.marker = 'other_app_private_' + uuid.uuid4().hex
        self.stopped = threading.Event()
        self.failures = []
        self.samples = 0
        self.long = None
        self.thread = None
        h.sql('CREATE DATABASE other_app')
        h.sql('CREATE TABLE other_app.state (value UInt64) ENGINE=MergeTree ORDER BY value')
        h.sql('INSERT INTO other_app.state VALUES (7)')
        h.sql('ALTER TABLE other_app.state DELETE WHERE value=0 SETTINGS mutations_sync=2')
        assert int(h.sql("SELECT count() FROM system.mutations WHERE database='other_app'").strip()) > 0
        h.sql('CREATE USER other_app IDENTIFIED WITH no_password')
        h.sql('GRANT SELECT, INSERT ON other_app.* TO other_app')
        h.sql('GRANT SELECT ON system.numbers TO other_app')
        self.grants = h.sql('SHOW GRANTS FOR other_app')
        self.pid = (h.root / 'clickhouse/pid').read_text()
        self.identity = h.sql('SELECT toString(serverUUID())').strip()
        self.start_time = self._start_time()
        try:
            self.long = subprocess.Popen(client(h, 'other_app', '/* ' + self.marker + ' */ SELECT sleep(0.1) FROM system.numbers LIMIT 10000 SETTINGS max_block_size=1') + ['--query_id', self.marker],
                                         env=h.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            eventually(lambda: h.sql("SELECT count() FROM system.processes WHERE user='other_app'").strip() == '1', 'other application query starts')
            self.thread = threading.Thread(target=self._sample, daemon=True)
            self.thread.start()
        except BaseException:
            self.close()
            raise

    def _start_time(self):
        return subprocess.check_output(['ps', '-p', self.pid.strip(), '-o', 'lstart='], text=True).strip()

    def _sample(self):
        while not self.stopped.is_set():
            try:
                result = subprocess.run(client(self.h, 'other_app', 'SELECT sum(value) FROM other_app.state'), env=self.h.env,
                                        capture_output=True, text=True, timeout=5)
                if result.returncode or result.stdout.strip() != '7':
                    self.failures.append('other application fresh query failed')
                self.samples += 1
            except BaseException as error:
                self.failures.append(type(error).__name__)
            self.stopped.wait(.5)

    def checkpoint(self, label):
        assert self.long.poll() is None, 'other application long query ended at ' + label
        assert not self.failures, self.failures
        assert self.h.run(client(self.h, 'other_app', 'SELECT sum(value) FROM other_app.state')).stdout.strip() == '7'
        assert (self.h.root / 'clickhouse/pid').read_text() == self.pid
        assert self.h.sql('SELECT toString(serverUUID())').strip() == self.identity
        assert self._start_time() == self.start_time
        assert self.h.sql('SHOW GRANTS FOR other_app') == self.grants
        with (self.h.root / 'availability.jsonl').open('a') as output:
            output.write(json.dumps(dict(phase=label, samples=self.samples, failures=len(self.failures), pid=self.pid.strip(), processStart=self.start_time, server=self.identity)) + '\n')

    def close(self):
        self.stopped.set()
        if self.thread is not None and self.thread.ident is not None:
            self.thread.join(timeout=10)
            assert not self.thread.is_alive()
        if self.long is not None:
            if self.long.poll() is None:
                self.long.terminate()
            self.long.communicate(timeout=10)


@contextmanager
def runtime(h, binaries, *, credential=None, postgres=None):
    port = free_port()
    queue = 'shared_' + uuid.uuid4().hex
    if postgres is None:
        h.run(['psql', '-XAtc', "SELECT pgmq.create('" + queue + "')"])
    credential = credential or dict(CLICKHOUSE_USER='runtime', CLICKHOUSE_PASSWORD='')
    settings = dict(h.env, KANSOKU_CLICKHOUSE_USER=credential['CLICKHOUSE_USER'], KANSOKU_CLICKHOUSE_PASSWORD=credential['CLICKHOUSE_PASSWORD'],
                    KANSOKU_SERVER_PORT=str(port), KANSOKU_QUEUE_NAME=queue,
                    KANSOKU_WRITER_MAX_LATENCY_MS='100', KANSOKU_QUEUE_POLL_INTERVAL_SEC='1',
                    OTEL_TRACES_EXPORTER='none', OTEL_METRICS_EXPORTER='none')
    if postgres is not None:
        settings.update(PGUSER=postgres['POSTGRES_USER'], PGPASSWORD=postgres['POSTGRES_PASSWORD'],
                        PG_CONNECTION_STRING='host=127.0.0.1 port='+h.env['PGPORT']+' dbname=kansoku user='+postgres['POSTGRES_USER']+' password='+postgres['POSTGRES_PASSWORD'])
    with (h.root / 'runtime.private').open('a') as output:
        with owned_process([binaries['server']], settings, h.root, 'scoped-runtime', stop_timeout=40, stdout=output, stderr=output) as process:
            base = 'http://127.0.0.1:' + str(port)
            eventually(lambda: ready(base, process), 'scoped runtime readiness')
            yield base, queue


def request(base, path, token=None, body=None, expected=200):
    headers = {'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    command = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(), headers=headers)
    try:
        response = urllib.request.urlopen(command, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        answer = json.load(response)
        assert response.status == expected, (path, response.status, answer)
        return answer


def ready(base, process):
    assert process.poll() is None, 'scoped runtime exited before readiness'
    try:
        return request(base, '/health/ready')['status'] == 'ok'
    except (OSError, AssertionError):
        return False


def issue(h, admin, kind):
    return h.run([admin, 'issue-key', '--kind', kind, '--account', 'shared-proof', '--description', 'owned shared fixture']).stdout.splitlines()[-2]


def pg(h, sql, settings=None):
    return h.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', sql], env=settings).stdout.strip()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def proof(h, path, owner, settings=None):
    return write_evidence(path, settings or h.env, owner,
                          'Owned runtime and reader logins excluded; owned runtime stopped and joined; all earlier direct clients joined; no external schedules remain. The fixture alone controls maintenance credentials. App background work is settled; other_app stays available.',
                          submitters=PRINCIPALS, available_principals=['default', 'migrator', 'data_admin', 'verifier'])


def snapshot_point(h):
    queues = json.loads(pg(h, "SELECT coalesce(jsonb_agg(queue_name ORDER BY queue_name),'[]'::jsonb) FROM pgmq.meta"))
    queued = {}
    for queue in queues:
        table = '"q_' + queue.replace('"','""') + '"'
        queued[queue] = json.loads(pg(h,"SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY msg_id),'[]'::jsonb) FROM pgmq." + table + ' q'))
    return dict(session=json.loads(pg(h, 'SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s WHERE completed_at IS NULL')),
                policy=json.loads(pg(h, 'SELECT to_jsonb(p) FROM kansoku.retention_policy p')),
                accepted=pg(h, 'SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY account_id,event_id),\'[]\'::jsonb) FROM kansoku.accepted_events a'),
                dispositions=pg(h, 'SELECT coalesce(jsonb_agg(to_jsonb(d) ORDER BY account_id,event_id),\'[]\'::jsonb) FROM kansoku.event_dispositions d'),
                queued=queued,
                raw=[json.loads(line) for line in h.sql('SELECT * FROM analytics.events_raw ORDER BY event_id FORMAT JSONEachRow').splitlines()])


def assert_point(h, point):
    observed = snapshot_point(h)
    assert observed == point, 'three-store restore differs from its complete pre-change point'


def reject_partial_backup(h, binaries, other):
    context = json.loads(h.run([binaries['upgrade'], 'maintenance', 'recovery-context', '--json']).stdout)['result']
    predecessor = h.counter()
    drain = h.root / 'partial-backup-drain.json'
    settings = proof(h, drain, dict(kind='migration-session', id=h.env['KANSOKU_CH_MIGRATION_SESSION'], predecessor=predecessor))
    started = datetime.now(timezone.utc).isoformat()
    dump = h.root / 'partial-postgres.dump'
    h.run(['pg_dump', '--format=custom', '--file', str(dump)])
    completed = datetime.now(timezone.utc).isoformat()
    failed = h.run(client(h, 'default', "BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO Disk('owned_missing_disk','must-fail.zip')"), success=False)
    assert failed.returncode != 0 and dump.stat().st_size > 0
    receipt = h.root / 'partial-postgres.receipt'
    receipt.write_text(json.dumps(dict(exitCode=0, format='pg_dump custom')))
    manifest = {key:context[key] for key in ['target','servers','ledger','session','predecessor','planSha256','postgresDatabase','retentionPolicy','coordinatorState']}
    manifest.update(schemaVersion=1, id=str(uuid.uuid4()), drainSha256=digest(drain), stableFrom=started,
                    stableUntil=json.loads(drain.read_text())['expiresAt'], coordinatorSnapshotPhase='fenced-before-native-entry',
                    backgroundChangesSettled=True, operatorAttested=True,
                    snapshots=[dict(store='postgresql',database=context['postgresDatabase'],startedAt=started,completedAt=completed,
                                    artifactReference=str(dump),artifactSha256=digest(dump),verificationReference=str(receipt),verificationSha256=digest(receipt),complete=True)])
    path = h.root / 'partial-recovery-set.json'
    path.write_text(json.dumps(manifest))
    h.run([binaries['upgrade'],'--predecessor',str(predecessor),'--drain-evidence',str(drain),'--recovery-set',str(path),'up','--json',*h.audit()], env=settings, success=False)
    assert h.counter() == predecessor
    assert pg(h, 'SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1'
    assert h.sql("SELECT count() FROM system.tables WHERE database='analytics' AND name='__native_upgrade_probe'").strip() == '0'
    other.checkpoint('partial-backup-refused-before-native-entry')


def inspect_copy(h, binaries, other, manifest):
    archive = next(s['artifactReference'] for s in manifest['snapshots'] if s['store']=='clickhouse')
    name = Path(archive).name
    h.sql("RESTORE DATABASE analytics AS analytics_restore, DATABASE kansoku_migration_ledger AS kansoku_migration_ledger_restore FROM Disk('kansoku_backups','" + name + "')")
    policy = h.root / 'scratch-policy.json'
    policy.write_text(json.dumps(manifest['retentionPolicy']))
    expectations = json.loads(h.run([binaries['native'],'restored-expectations','--json']).stdout)['result']
    settings = {key:value for key,value in h.env.items() if not key.startswith(('PG','CLICKHOUSE','KANSOKU_'))}
    settings.update(KANSOKU_CH_RESTORE_USER='verifier', KANSOKU_CH_RESTORE_PASSWORD='')
    capture = ReadCapture(h.endpoint)
    try:
        command = [binaries['native'],'verify-restored','--json','--endpoint',capture.endpoint,'--server',h.env['KANSOKU_CH_MIGRATION_SERVER_ID'],
                   '--original-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--original-ledger',h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],
                   '--application-database','analytics_restore','--ledger-database','kansoku_migration_ledger_restore',
                   '--expect-plan-sha256',expectations['planSha256'],'--expected-definer','migrator','--expected-policy',str(policy)]
        report = json.loads(h.run(command,env=settings).stdout)['result']
        assert report['schema']['matches'] and report['ledger']==dict(compatible=True,current=True,unresolved=False)
        assert not report['authorizedForMutation']
        h.run(client(h,'verifier','CREATE TEMPORARY TABLE forbidden (id UInt8)'),success=False)
        h.run(client(h,'verifier','TRUNCATE TABLE analytics_restore.events_raw'),success=False)
        h.run(client(h,'verifier','SELECT auth_params FROM system.users'),success=False)
        h.sql('ALTER TABLE analytics_restore.events_raw ADD COLUMN unreviewed UInt8 DEFAULT 1')
        drift = json.loads(h.run(command,env=settings,success=False).stdout)['result']
        assert drift['ledger']['current'] and not drift['schema']['matches']
        assert capture.requests and all(body.lstrip().upper().startswith(b'SELECT') for body in capture.requests)
        (h.root/'inspection-requests.private.json').write_text(json.dumps([body.decode() for body in capture.requests]))
    finally:
        capture.close()
    other.checkpoint('read-only-renamed-copy-and-unchanged-history-drift')


def data_job(h, binaries, other, arguments, event_days=None):
    settings = dict(h.env, KANSOKU_CLICKHOUSE_USER='data_admin', KANSOKU_CLICKHOUSE_PASSWORD='')
    if event_days is not None:
        settings['KANSOKU_EVENTS_RETENTION_DAYS'] = str(event_days)
    prepared = json.loads(h.run([binaries['admin'],*arguments,'--prepare'],env=settings).stdout)
    status = json.loads(h.run([binaries['admin'],'job-status','--id',prepared['job_id']],env=settings).stdout)
    # The actual persistent fence has excluded cooperating operations; runtime
    # is already stopped and every fixture-owned native submitter is joined.
    pg(h, 'SELECT pg_advisory_lock(726401,1)')
    drain = h.root / ('job-drain-' + str(uuid.uuid4()) + '.json')
    bound = proof(h,drain,dict(kind='data-job',id=prepared['job_id'],attempt=status['next_attempt']),settings)
    completed = json.loads(h.run([binaries['admin'],'resume-job','--id',prepared['job_id'],'--confirm','--drain-evidence',str(drain)],env=bound).stdout)
    assert completed['stage'] == 'complete'
    assert pg(h, 'SELECT count(*) FROM kansoku.maintenance_fence WHERE active_job IS NOT NULL') == '0'
    other.checkpoint('data-job-' + arguments[0])


def rebuilt_roundtrip(source, other, binaries, manifest_path, original_drain, point, native_point):
    manifest = json.loads(manifest_path.read_text())
    dump = next(s['artifactReference'] for s in manifest['snapshots'] if s['store']=='postgresql')
    archive = next(s['artifactReference'] for s in manifest['snapshots'] if s['store']=='clickhouse')
    with owned(source.root/'rebuilt',binaries['native'],binaries['upgrade'],binaries['pg_migrate'],binaries['admin'],access_management=True) as h:
        install_principals(h)
        h.env.update(KANSOKU_CLICKHOUSE_USER='migrator',KANSOKU_CLICKHOUSE_PASSWORD='')
        h.run(['pg_restore','--dbname=postgres','--clean','--if-exists','--no-owner','--exit-on-error',dump])
        shutil.copyfile(archive,Path(h.env['KANSOKU_OWNED_CLICKHOUSE_BACKUP_ROOT'])/'point.zip')
        h.sql("RESTORE DATABASE analytics, DATABASE kansoku_migration_ledger FROM Disk('kansoku_backups','point.zip')")
        for key in ['KANSOKU_CH_MIGRATION_TARGET','KANSOKU_CH_MIGRATION_LEDGER_ID','KANSOKU_CH_MIGRATION_SESSION']:
            h.env[key] = source.env[key]
        assert_point(h,point)
        old = source.env['KANSOKU_CH_MIGRATION_SERVER_ID']
        new = h.env['KANSOKU_CH_MIGRATION_SERVER_ID']
        assert old != new
        h.run([binaries['upgrade'],'maintenance','status','--json'],success=False)
        owner = dict(kind='migration-session',id=h.env['KANSOKU_CH_MIGRATION_SESSION'],predecessor=manifest['predecessor'])
        drain = h.root/'rebuilt-drain.json'
        settings = proof(h,drain,owner)
        observation = json.loads(h.run([binaries['upgrade'],'maintenance','recovery-observation','--json']).stdout)['result']
        assert observation['ledgerSha256'] == native_point['ledgerSha256']
        receipt = h.root/'restore-verification.json'
        receipt.write_text(json.dumps(dict(schemaVersion=1,mode='live-recovery',target=h.env['KANSOKU_CH_MIGRATION_TARGET'],oldServer=old,newServer=new,
            ledger=h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'],session=owner['id'],recoverySetId=manifest['id'],recoverySetSha256=digest(manifest_path),
            ledgerSha256=observation['ledgerSha256'],inspectedAt=datetime.now(timezone.utc).isoformat(),expiresAt=json.loads(drain.read_text())['expiresAt'],allStoresRestored=True,operatorAttested=True)))
        command=[binaries['upgrade'],'--recovery-set',str(manifest_path),'--drain-evidence',str(drain),'maintenance','rebind','--json',
                 '--expect-target',h.env['KANSOKU_CH_MIGRATION_TARGET'],'--old-server',old,'--new-server',new,'--original-drain',str(original_drain),
                 '--restore-verification',str(receipt),'--actor','owned shared proof','--reason','verified rebuilt common snapshot','--evidence',str(receipt)]
        # A subprocess proxy consumes the committed response but drops it
        # before its caller receives any bytes, matching a lost CLI reply.
        proxy = h.root/'drop-rebind-output.py'
        proxy.write_text("import subprocess,sys\nr=subprocess.run(sys.argv[1:],capture_output=True)\nassert r.returncode==0,r.stderr\nsys.exit(1)\n")
        h.run(['python3',str(proxy),*command],env=settings,success=False)
        assert pg(h,'SELECT count(*) FROM kansoku.clickhouse_server_rebindings') == '1'
        status=json.loads(h.run([binaries['upgrade'],'maintenance','status','--json']).stdout)['result']
        status.pop('repair_observation')
        assert status == dict(point['session'],server_id=new)
        assert pg(h,'SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1'
        first=json.loads(h.run(command,env=settings).stdout)['result']
        second=json.loads(h.run(command,env=settings).stdout)['result']
        assert first == second
        assert pg(h,'SELECT count(*) FROM kansoku.clickhouse_server_rebindings') == '1'
        h.controller['drain'] = lambda: None
        h.controller['submitters'] = PRINCIPALS
        h.controller['available_principals'] = ['default','migrator','data_admin','verifier']
        h.controller['drain_procedure'] = 'Fresh rebuilt fixture exclusively owns every credential; full PostgreSQL and both ClickHouse stores restored and verified; all direct clients joined, no runtime/schedules exist; background changes settled.'
        h.up(binary=binaries['upgrade'])
        h.finish(binary=binaries['upgrade'])
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
    other.checkpoint('separate-rebuilt-server-rebind-lost-response-and-replay')


def shared_ceremony(h, other, binaries, own_processes, now, service):
    active_external = []
    def drain():
        h.sql('ALTER USER runtime HOST NONE')
        h.sql('ALTER USER reader HOST NONE')
        assert not any(process.poll() is None for process in active_external), 'an earlier migration-credential client remains; runtime-only quiescence is incomplete'
        assert h.sql("SELECT count() FROM system.processes WHERE user IN ('runtime','reader','migrator','data_admin') AND query_kind='Insert'").strip() == '0'
    h.controller['drain'] = drain
    h.controller['drain_procedure'] = 'Runtime and reader logins excluded; the owned runtime process is stopped and joined; earlier migration-credential client joined; all direct clients synchronous; no external schedules; app background changes settled. Maintenance credentials remain under exclusive fixture control; other_app remains available.'
    h.begin()
    external = subprocess.Popen(client(h,'migrator','INSERT INTO analytics.events_raw FORMAT JSONEachRow'),env=h.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    active_external.append(external)
    try:
        external.stdin.write('\n')
        external.stdin.flush()
        eventually(lambda: h.sql("SELECT count() FROM system.processes WHERE user='migrator' AND query_kind='Insert'").strip() == '1', 'earlier migration-credential request starts')
        if own_processes:
            assert h.run(client(h,'runtime',"SELECT count() FROM system.processes WHERE user='migrator'")).stdout.strip() == '0'
        try:
            drain()
            raise AssertionError('producer accepted runtime-only exclusion with an active external writer')
        except AssertionError as failure:
            assert 'earlier migration-credential client remains' in str(failure)
        h.run([binaries['upgrade'],'--predecessor','0','up','--json',*h.audit()],success=False)
        assert h.counter() == 0
    finally:
        external.stdin.close()
        external.wait(timeout=20)
        assert external.returncode == 0
    drain()
    other.checkpoint('runtime-and-external-submitter-exclusion')
    reject_partial_backup(h,binaries,other)
    proxy = FaultProxy(h.endpoint)
    proxy.match = b'INSERT INTO analytics.__native_upgrade_probe VALUES'
    try:
        h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
        command, settings = h.entry_command(['up'],binary=binaries['upgrade'])
        manifest_path = Path(command[command.index('--recovery-set')+1])
        manifest = json.loads(manifest_path.read_text())
        original_drain = Path(command[command.index('--drain-evidence')+1])
        point = snapshot_point(h)
        native_point = json.loads(h.run([binaries['upgrade'],'maintenance','recovery-observation','--json']).stdout)['result']
        h.run(command,env=settings,success=False)
        assert proxy.triggered.is_set()
    finally:
        proxy.close()
        h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
    assert pg(h, 'SELECT count(*) FROM kansoku.maintenance_fence WHERE active_migration_session IS NOT NULL') == '1'
    h.observed_entry(repair_arguments(h,'accept-step',True),binary=binaries['upgrade'],expected_sql=0)
    h.observed_entry(repair_arguments(h,'resume'),binary=binaries['upgrade'],expected_sql=1)
    h.finish(binary=binaries['upgrade'])
    assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
    states = json.loads(pg(h,"SELECT jsonb_agg(observation->>'state' ORDER BY id) FROM kansoku.clickhouse_repair_observations"))
    assert states == [ 'no-visible-recorded-queries' if own_processes else 'unavailable' ] * 2
    other.checkpoint('interrupted-native-upgrade-and-explicit-repair')
    data_job(h,binaries,other,['apply-retention'],event_days=30)
    assert h.sql("SELECT count() FROM analytics.events_raw WHERE account_id='shared-proof'").strip() == '2'
    data_job(h,binaries,other,['erase-user','--account','shared-proof','--user','shared-user','--delete-events'])
    assert h.sql("SELECT user_id FROM analytics.events_raw WHERE account_id='shared-proof'").strip() == 'kept-user'
    inspect_copy(h,binaries,other,manifest)
    rebuilt_roundtrip(h,other,binaries,manifest_path,original_drain,point,native_point)
    h.sql('ALTER USER runtime HOST LOCAL')
    h.sql('ALTER USER reader HOST LOCAL')
    with runtime(h,binaries) as (base,_):
        params={'from':(now-timedelta(days=1)).date().isoformat(),'to':(now+timedelta(days=1)).date().isoformat(),'timeGrain':'none'}
        report=request(base,'/metrics/events?'+urllib.parse.urlencode(params),service)
        assert sum(p['value'] for p in report['points']) == 1
        h.run(client(h,'reader',"SELECT count() FROM analytics.events_analytics_v1(account='shared-proof',from_time='"+params['from']+" 00:00:00',to_time='"+params['to']+" 00:00:00')"))
        other.checkpoint('deliberate-runtime-reader-resume-and-public-definer')


def role_probe(root, binaries, roles_only, *, own_processes):
    with owned(root, binaries['native'], binaries['upgrade'], binaries['pg_migrate'], binaries['admin'],
               access_management=True, query_logging=True) as h:
        install_principals(h, own_processes)
        other = OtherApplication(h)
        try:
            h.env.update(KANSOKU_CLICKHOUSE_USER='migrator', KANSOKU_CLICKHOUSE_PASSWORD='')
            h.controller['drain'] = lambda: None
            h.controller['submitters'] = PRINCIPALS
            h.controller['available_principals'] = ['default', 'migrator', 'data_admin', 'verifier']
            h.controller['drain_procedure'] = 'The fixture exclusively owns every app credential and submitting client; preceding synchronous clients joined, no runtime or schedules started; unrelated other_app remains admitted. App background changes settle before evidence.'
            h.begin()
            h.up(first=True)
            h.finish()
            other.checkpoint('scoped-native-initialization')
            # Restricted metadata must retain actual tenant visibility, even
            # when callers deliberately omit their usual database predicates.
            for user in ['runtime', 'migrator', 'data_admin']:
                assert not h.run(client(h, user, "SELECT create_table_query FROM system.tables WHERE database='other_app'")).stdout.strip()
                h.run(client(h, user, 'SELECT * FROM other_app.state'), success=False)
                h.run(client(h, user, 'ALTER USER other_app HOST NONE'), success=False)
                processes = h.run(client(h, user, 'SELECT query FROM system.processes'), success=own_processes)
                assert other.marker not in processes.stdout
                h.run(client(h, user, 'SELECT query FROM system.query_log'), success=False)
                killed = subprocess.run(client(h,user,"KILL QUERY WHERE query_id='" + other.marker + "' SYNC"),env=h.env,capture_output=True,text=True,timeout=10)
                assert (killed.returncode == 0 and not killed.stdout.strip()) or 'Code: 497' in killed.stderr
                assert other.long.poll() is None
                assert h.sql("SELECT count() FROM system.processes WHERE query_id='"+other.marker+"'").strip() == '1'
            assert h.run(client(h, 'runtime', "SELECT database,table,name,active FROM system.parts WHERE database='other_app'")).stdout.strip() == ''
            assert h.run(client(h, 'data_admin', "SELECT * FROM system.mutations WHERE database='other_app'")).stdout.strip() == ''
            h.run(client(h, 'runtime', 'CREATE TABLE analytics.forbidden (id UInt8) ENGINE=MergeTree ORDER BY id'), success=False)
            external = h.run(client(h, 'runtime', "SELECT * FROM url('http://127.0.0.1:1/', 'TSV', 'id UInt8')"), success=False)
            assert 'Code: 497' in external.stderr
            write, service = issue(h, binaries['admin'], 'write'), issue(h, binaries['admin'], 'service')
            with runtime(h, binaries) as (base, queue):
                now = datetime.now(timezone.utc)
                stamp = (now - timedelta(hours=1)).isoformat()
                payload = event('shared-event', 'shared-session', timestamp=stamp)
                payload.update(schemaVersion=1, sourceService='shared', userId='shared-user', context={})
                request(base, '/v1/events', write, payload, expected=202)
                keep = event('shared-keep', 'keep-session', timestamp=stamp)
                keep.update(schemaVersion=1, userId='kept-user', context={})
                old = event('shared-old', 'old-session', timestamp=(now-timedelta(days=120)).isoformat())
                old.update(schemaVersion=1, userId='old-user', context={})
                request(base, '/v1/events', write, keep, expected=202)
                request(base, '/v1/events', write, old, expected=202)
                params = {'from':(now - timedelta(days=1)).date().isoformat(), 'to':(now + timedelta(days=1)).date().isoformat(),
                          'timeGrain':'none', 'filter':json.dumps(dict(dimension='user_id', op='eq', value='shared-user'))}
                path = '/metrics/events?' + urllib.parse.urlencode(params)
                eventually(lambda: sum(point['value'] for point in request(base, path, service)['points']) == 1, 'scoped writer and identity metric')
                h.sql('SYSTEM FLUSH LOGS')
                assert int(h.sql("SELECT count() FROM system.query_log WHERE user='runtime' AND type='QueryFinish' AND position(query,'CREATE TEMPORARY TABLE kansoku_context_cache')>0").strip()) > 0
                h.run(client(h, 'reader', "SELECT count() FROM analytics.events_analytics_v1(account='shared-proof',from_time='" + params['from'] + " 00:00:00',to_time='" + params['to'] + " 00:00:00')"))
                eventually(lambda: h.sql("SELECT count() FROM analytics.events_raw WHERE account_id='shared-proof'").strip() == '3', 'all scoped writer events complete')
                other.checkpoint('scoped-writer-identity-cache-and-reader')
            if not roles_only:
                shared_ceremony(h, other, binaries, own_processes, now, service)
        finally:
            other.close()
    print(('Shared principal development proof' if roles_only else 'Shared maintenance ceremony') + ': ' + ('own-user' if own_processes else 'denied') + ' visibility; owned scoped initializer/runtime/cache/reader passed' + ('; integrated release coverage is unrun' if roles_only else '; complete joined ceremony passed'), flush=True)


def verify(root, binaries):
    for own_processes in (False, True):
        role_probe(root / ('own-user' if own_processes else 'denied'), binaries, False, own_processes=own_processes)
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--roles-only', action='store_true', help='Development subset; never counts as integrated release acceptance')
    args = parser.parse_args()
    os.umask(0o077)
    parent = Path('.dev/acceptance').resolve()
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='shared-maintenance-', dir=parent))
    print('Private shared maintenance evidence: ' + str(root), flush=True)
    binaries = packaged_binaries()
    for own_processes in (False, True):
        role_probe(root / ('own-user' if own_processes else 'denied'), binaries, args.roles_only, own_processes=own_processes)
    if not args.roles_only:
        (root/'sanitized').mkdir()
        (root/'sanitized/shared-maintenance.log').write_text('2 complete generic shared-server ceremonies; 0 failures; 0 skipped; Nagare integration is separately unrun\n')
        print('Shared maintenance: 2 complete generic ceremonies, 0 failures, 0 skipped; Nagare is separately unrun', flush=True)


if __name__ == '__main__':
    main()
