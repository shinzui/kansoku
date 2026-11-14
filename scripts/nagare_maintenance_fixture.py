"""Private, explicitly owned local Nagare fixture used by EP-53's platform drill."""
import base64
from contextlib import contextmanager, ExitStack
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import uuid

from clickhouse_migrations_acceptance import Harness, packaged_binaries
from isolated_clickhouse import free_port


class NagareHarness(Harness):
    def __init__(self, root, environment, binaries, operator, kube):
        self.operator, self.kube = operator, kube
        super().__init__(root, binaries['native'], binaries['upgrade'], binaries['pg_migrate'],
                         binaries['admin'], environment, {'restart': self.refuse_restart})
        self.sequence = len(list(self.root.glob('command-*.private'))) + 1

    def refuse_restart(self):
        raise AssertionError('The shared Nagare server must remain running')

    def query_as(self, credential, query, *, success=True, input=None):
        return self.run(['clickhouse-client', '--host', '127.0.0.1', '--port', self.env['CLICKHOUSE_TCP_PORT'],
                         '--user', credential['CLICKHOUSE_USER'], '--password', credential['CLICKHOUSE_PASSWORD'],
                         '--query', query], success=success, input=input)

    def sql(self, query, input=None):
        return self.query_as(self.operator, query, input=input).stdout

    def audit(self):
        return ['--expect-target', self.env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned Nagare acceptance',
                '--reason', 'reviewed runtime quiesce and app-scoped external client drain; shared server remained running',
                '--quiescent', '--evidence', str(self.root/'platform-audit.private.json')]

    def process_identity(self):
        pod = json.loads(subprocess.check_output(self.kube + ['get', 'pod', 'kansoku-ch-0', '-o', 'json']))
        stat = subprocess.check_output(self.kube + ['exec', 'kansoku-ch-0', '--', 'sh', '-c',
            'cat /proc/1/stat'], text=True)
        assert '(clickhouse-serv)' in stat, 'Qualified server is no longer PID 1'
        # Linux stat's comm may contain spaces; fields after ')' begin with field 3.
        return dict(pod=pod['metadata']['uid'], restartCount=pod['status']['containerStatuses'][0]['restartCount'],
                    pid=stat.split(' ', 1)[0], startTicks=stat.rsplit(')', 1)[1].split()[19],
                    server=self.sql('SELECT toString(serverUUID())').strip())


def nagare(root, *arguments, capture=True):
    result = subprocess.run([sys.executable, str(root/'run.py'), *arguments], capture_output=capture,
                            text=True, timeout=600)
    if capture:
        with (root/'nagare-commands.private').open('a') as output:
            output.write(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout


def reviewed(root, label, *arguments):
    review = root/'reviews'/label
    assert not review.exists(), 'Each operation requires its own immutable review'
    nagare(root, *arguments, '--save-plan', str(review))
    return nagare(root, 'inventory', 'apply', str(review), '--yes')


def secret(kube, name):
    document = json.loads(subprocess.check_output(kube + ['get', 'secret', name, '-o', 'json']))
    return {key: base64.b64decode(value).decode() for key, value in document['data'].items()}


@contextmanager
def connected(root, *, initialize=False):
    root = Path(root).resolve()
    fixture = json.loads((root/'fixture.json').read_text())
    assert fixture['owner'] == 'kansoku-ep53' and fixture['cluster'].startswith('kansoku-ep53')
    config = root/'config/nagare/kubeconfigs/local.yaml'
    kube = ['kubectl', '--kubeconfig', str(config), '-n', 'personal']
    node = json.loads(subprocess.check_output(kube + ['get', 'node', fixture['cluster'], '-o', 'json']))
    assert node['metadata']['uid'] == fixture['nodeUID'], 'Owned node incarnation changed'
    assert node['status']['nodeInfo']['architecture'] == 'arm64'
    pod = json.loads(subprocess.check_output(kube + ['get', 'pod', 'kansoku-ch-0', '-o', 'json']))
    image = pod['status']['containerStatuses'][0]['imageID']
    assert image.endswith('sha256:63e02621435cde1146ab0fde66057091ee75b312d12917c0109a6a0c99bc7ce1'), 'Nagare backend differs from the qualified official OCI index'
    with ExitStack() as stack:
        ports = {}
        for service, remote, key in [('kansoku-ch', 9000, 'tcp'), ('kansoku-ch', 8123, 'http'), ('kansoku-pg', 5432, 'pg')]:
            port = free_port()
            ports[key] = port
            output = stack.enter_context((root/(key+'-forward.private')).open('a'))
            process = subprocess.Popen(kube + ['port-forward', 'svc/'+service, str(port)+':'+str(remote)], stdout=output, stderr=output)
            def stop(p=process):
                if p.poll() is None:
                    p.terminate()
                p.wait(timeout=10)
            stack.callback(stop)
            deadline = time.monotonic() + 20
            while True:
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=1):
                        break
                except OSError:
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(.1)
        credentials = {key: secret(kube, name) for key, name in dict(
            operator='nagare-db-kansoku-ch', migration='kansoku-ch-app-migration', runtime='kansoku-ch-app-runtime',
            pg_migration='kansoku-pg-app-migration', pg_runtime='kansoku-pg-app-runtime',
            other_migration='other-ch-app-migration', other_runtime='other-ch-app-runtime').items()}
        ch, pg = credentials['migration'], credentials['pg_migration']
        environment = {key:value for key,value in os.environ.items() if not key.startswith(('KANSOKU_', 'CLICKHOUSE_', 'PG'))}
        environment.update(PGHOST='127.0.0.1', PGPORT=str(ports['pg']), PGUSER=pg['POSTGRES_USER'],
            PGPASSWORD=pg['POSTGRES_PASSWORD'], PGDATABASE='kansoku',
            PG_CONNECTION_STRING=f'host=127.0.0.1 port={ports["pg"]} user={pg["POSTGRES_USER"]} password={pg["POSTGRES_PASSWORD"]} dbname=kansoku',
            CLICKHOUSE_TCP_PORT=str(ports['tcp']), CLICKHOUSE_HTTP_PORT=str(ports['http']),
            KANSOKU_CLICKHOUSE_HOST='127.0.0.1', KANSOKU_CLICKHOUSE_USER=ch['CLICKHOUSE_USER'],
            KANSOKU_CLICKHOUSE_PASSWORD=ch['CLICKHOUSE_PASSWORD'], NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost',
            OTEL_TRACES_EXPORTER='none', OTEL_METRICS_EXPORTER='none')
        binaries = packaged_binaries()
        run = root/('ceremony-'+uuid.uuid4().hex)
        run.mkdir(mode=0o700)
        h = NagareHarness(run, environment, binaries, credentials['operator'], kube)
        retained = root/'identities.private.json'
        if initialize:
            assert not retained.exists(), 'Initialization requires a fresh identity'
            h.begin()
            retained.write_text(json.dumps({key:value for key,value in h.env.items() if key.startswith('KANSOKU_CH_MIGRATION_')}))
        identity = json.loads(retained.read_text())
        assert identity['KANSOKU_CH_MIGRATION_SERVER_ID'] == h.env['KANSOKU_CH_MIGRATION_SERVER_ID']
        identity.pop('KANSOKU_CH_MIGRATION_ENDPOINT', None)
        if not initialize:
            identity.pop('KANSOKU_CH_MIGRATION_SESSION', None)
        h.env.update(identity)
        yield h, binaries, credentials


def drain_evidence(h, root, credentials, *, job=None):
    reports = {}
    for app in ['kansoku-ch-app', 'kansoku-pg-app']:
        report = json.loads(nagare(root, 'db', 'app-database', 'evidence', app, '-n', 'personal', '--json'))
        assert report['drain'] is not None and report['activeRuns'] == 0
        reports[app] = report
    assert reports['kansoku-ch-app']['server']['serverUUID'] == h.env['KANSOKU_CH_MIGRATION_SERVER_ID']
    for user in ['runtime', 'pg_runtime']:
        # Runtime clients are joined by the caller; the operator alone retains
        # migration and server credentials throughout this fixture's ceremony.
        assert credentials[user]
    tables = h.sql("SELECT name FROM system.tables WHERE database='analytics' AND position(engine,'MergeTree')>0").splitlines()
    for table in tables:
        h.sql('SYSTEM STOP TTL MERGES analytics.`'+table.replace('`','``')+'`')
    deadline = time.monotonic() + 60
    while h.sql("SELECT (SELECT count() FROM system.mutations WHERE database='analytics' AND NOT is_done)+(SELECT count() FROM system.merges WHERE database='analytics')").strip() != '0':
        assert time.monotonic() < deadline, 'App background work has not settled'
        time.sleep(.1)
    for app in ['kansoku-ch-app','kansoku-pg-app']:
        schedule = json.loads(subprocess.check_output(h.kube + ['get','cronjob','nagare-appdb-'+app,'-o','json']))
        assert schedule['spec'].get('suspend') is True and not schedule.get('status',{}).get('active')
    h.query_as(credentials['runtime'],'SELECT 1',success=False)
    now = datetime.now(timezone.utc)
    procedure = h.root/('procedure-'+uuid.uuid4().hex+'.private.json')
    procedure.write_text(json.dumps(dict(reports=reports, operator='kansoku-ep53',
        procedure='Actual reviewed Nagare runtime quiesce pauses/drains both schedules. Owned runtimes and all earlier native clients joined. All remaining submitting credentials are held exclusively by this fixture. App mutations/merges settled; unrelated other_app stays admitted.')))
    users = [credentials[name]['CLICKHOUSE_USER'] for name in ['operator', 'migration', 'runtime']]
    available = users[:2]
    owner = job or dict(kind='migration-session', id=h.env['KANSOKU_CH_MIGRATION_SESSION'], predecessor=h.counter())
    value = dict(schemaVersion=1, target=h.env['KANSOKU_CH_MIGRATION_TARGET'], servers=[h.env['KANSOKU_CH_MIGRATION_SERVER_ID']],
        ledger=h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'], databases=['analytics','kansoku_migration_ledger'],
        submitters=users, availablePrincipals=available, owner=owner, exclusionStartedAt=now.isoformat(), drainedAt=now.isoformat(),
        expiresAt=(now+timedelta(minutes=30)).isoformat(), procedureReference=str(procedure),
        procedureSha256=hashlib.sha256(procedure.read_bytes()).hexdigest(), submittersBlocked=True, schedulesPaused=True,
        backgroundChangesSettled=True, operatorAttested=True)
    path = h.root/('drain-'+uuid.uuid4().hex+'.json')
    path.write_text(json.dumps(value))
    (h.root/'platform-audit.private.json').write_text(json.dumps(dict(procedure=str(procedure),drain=str(path),serverRestarted=False)))
    settings = dict(h.env, KANSOKU_CH_DRAIN_SERVERS=json.dumps(value['servers']), KANSOKU_CH_DRAIN_SUBMITTERS=json.dumps(users),
                    KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS=json.dumps(available))
    return path, settings, owner


def initialize_fixture(root):
    """Initialize only a fresh reviewed fixture; never clear a failed owner."""
    for app, key in [('kansoku-ch-app', 'ch'), ('kansoku-pg-app', 'pg')]:
        reviewed(root, 'init-quiesce-'+key, 'db', 'app-database', 'quiesce', app, '-n', 'personal', '--users', 'runtime')
    with connected(root, initialize=True) as (h, binaries, credentials):
        drain, environment, owner = drain_evidence(h, root, credentials)
        identity = h.process_identity()
        h.run([h.native, '--drain-evidence', str(drain), '--predecessor', '0', 'up', '--json',
               '--initialize-ledger', h.env['KANSOKU_CH_MIGRATION_LEDGER_ID'], *h.audit()], env=environment)
        drain, environment, owner = drain_evidence(h, root, credentials)
        h.run([h.native, '--drain-evidence', str(drain), '--predecessor', str(owner['predecessor']),
               'maintenance', 'finish', '--json', *h.audit()], env=environment)
        assert identity == h.process_identity()
    for app, key in [('kansoku-ch-app', 'ch'), ('kansoku-pg-app', 'pg')]:
        reviewed(root, 'init-resume-'+key, 'db', 'app-database', 'resume', app, '-n', 'personal')
