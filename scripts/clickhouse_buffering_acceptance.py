#!/usr/bin/env python3
"""Owned packaged-server buffering proof; prerequisites and every selected case are required."""
import argparse
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

from native_clickhouse_fixture import fixture, IMAGE, VERSION
from isolated_clickhouse import free_port
from isolated_postgres import isolated_postgres
from replicated_clickhouse import NativeProxy
from test_support import binary, execute


def eventually(check, label, seconds=60):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, urllib.error.URLError) as error:
            last = type(error).__name__
        time.sleep(.1)
    raise AssertionError(f'{label} exceeded {seconds}s ({last})')


def http(base, path, payload=None, key=None):
    headers = {'Content-Type': 'application/json'}
    if key:
        headers['X-Api-Key'] = key
    request = urllib.request.Request(base + path, data=None if payload is None else json.dumps(payload).encode(), headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=3)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read().decode()
        return response.status, json.loads(body) if 'json' in response.headers.get('Content-Type', '') else body


@contextmanager
def child(command, env, root, name):
    with (root / (name + '.private.log')).open('w') as output:
        process = subprocess.Popen(command, env=env, stdout=output, stderr=output)
        (root / (name + '.pid')).write_text(str(process.pid))
        try:
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


@contextmanager
def stalled_native():
    stopped = threading.Event()
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            stopped.wait(180)
    class Server(socketserver.ThreadingTCPServer):
        daemon_threads = True
    with Server(('127.0.0.1', 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            stopped.set()
            server.shutdown()
            thread.join(timeout=3)


class Case:
    def __init__(self, packaged, binaries, family, scenario):
        self.family, self.scenario = family, scenario
        parent = Path('.dev/acceptance').resolve()
        parent.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='buffering-', dir=parent))
        self.root.chmod(0o700)
        self.binaries = binaries
        self.sequence = 0
        self.report = dict(status='failed', case=scenario, topology=family, packaged=packaged,
                           platform=('Darwin arm64 client / Linux arm64 Apple Container stores' if VERSION.startswith('26.3') else 'Darwin arm64 Nix client and ClickHouse stores'),
                           image=IMAGE, version=VERSION, skipped=0, accepted=[], sourceRevision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                           binaries=binaries, sourceState=('working-tree' if subprocess.check_output(['git','status','--porcelain'], text=True).strip() else 'clean'), observations=[])
        print(f'Buffering {family}/{scenario}; private evidence {self.root}', flush=True)

    def run(self, command, env, **kwargs):
        self.sequence += 1
        result = execute(command, env=env, timeout=180, **kwargs)
        (self.root / f'command-{self.sequence}.private.log').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, f'command {self.sequence} failed; evidence {self.root}'
        return result.stdout

    def pg(self, sql):
        return self.run(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', sql], self.env).strip()

    def migrate(self, data, query, env, direct=False):
        if not direct:
            for database in ['analytics', 'kansoku_migration_ledger']:
                query(0, "CREATE DATABASE " + database + " ON CLUSTER fixture ENGINE=Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')")
        ids = [query(i, 'SELECT toString(serverUUID()) AS id')[0]['id'] for i in range(len(data['nativePorts']))]
        env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/buffering-' + uuid.uuid4().hex,
                   KANSOKU_CH_MIGRATION_ENDPOINT=data['endpoint'],
                   KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()),
                   KANSOKU_CLICKHOUSE_USER='default' if direct else 'app', KANSOKU_CLICKHOUSE_PASSWORD='test-password')
        if direct:
            env['KANSOKU_CH_MIGRATION_SERVER_ID'] = ids[0]
        else:
            env.update(KANSOKU_CH_MIGRATION_CLUSTER='fixture', KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(ids))
        cli = self.binaries['kansoku-ch-migrate']
        def invoke(arguments):
            return json.loads(self.run([cli, *arguments, '--json'], env))
        begun = invoke(['maintenance', 'begin', '--expect-target', env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned buffering proof', '--reason', 'Plan 72'])
        env['KANSOKU_CH_MIGRATION_SESSION'] = begun['result']['id']
        evidence = ['--expect-target', env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned buffering proof', '--reason', 'fresh owned stores and completed synchronous clients', '--quiescent', '--evidence', str(self.root)]
        invoke(['--predecessor', '0', 'up', '--initialize-ledger', env['KANSOKU_CH_MIGRATION_LEDGER_ID'], *evidence])
        status = invoke(['maintenance', 'status'])
        invoke(['--predecessor', str(status['result']['entry']), 'maintenance', 'finish', *evidence])
        env.pop('KANSOKU_CH_MIGRATION_SESSION')
        return ids

    def event(self, base, key):
        identifier = 'buffer-' + uuid.uuid4().hex
        event = dict(eventId=identifier, eventName='page_view', source='web', sourceService='buffer-proof',
                     occurredAt=datetime.now(timezone.utc).isoformat(), receivedAt=datetime.now(timezone.utc).isoformat(), userId='buffer-user',
                     properties={'url':'https://example.test/buffering'}, context={})
        code, body = http(base, '/v1/events', event, key)
        assert code == 202, (code, body)
        self.report['accepted'].append(identifier)
        return identifier

    def health(self, base, code=200, pipeline=None):
        live, ready = http(base, '/health/live'), http(base, '/health/ready')
        assert live[0] == 200 and ready[0] == code, (live, ready)
        if pipeline is not None:
            result = http(base, '/health/pipeline')
            assert result[0] == pipeline, result
            assert set(result[1]) == {'status', 'check', 'failingSince'}, result
            self.report['observations'].append(dict(ready=ready, pipeline=result))
            return result

    def exercise(self):
        direct = self.family == 'direct'
        try:
            with fixture(direct=direct) as (data, query, request, lifecycle), isolated_postgres(self.root / 'postgres') as env, NativeProxy(data['nativePorts']) as proxy, ExitStack() as extra:
                self.env = env
                self.run([self.binaries['kansoku-migrate'], 'up'], env)
                ids = self.migrate(data, query, env, direct)
                self.report['replicaIds'] = ids
                env.update(KANSOKU_CLICKHOUSE_HOST='127.0.0.1', CLICKHOUSE_TCP_PORT=str(proxy.port),
                           KANSOKU_SERVER_PORT=str(free_port()), KANSOKU_QUEUE_NAME='buffer_events',
                           KANSOKU_WRITER_MAX_BATCH='1', KANSOKU_WRITER_MAX_LATENCY_MS='50',
                           KANSOKU_QUEUE_POLL_INTERVAL_SEC='1', KANSOKU_READY_MAX_QUEUE_DEPTH='1',
                           KANSOKU_READY_MAX_FLUSH_AGE_SEC='2', OTEL_TRACES_EXPORTER='none')
                key = self.run([self.binaries['kansoku-server'], 'issue-key', '--kind', 'write', '--account', 'buffer-account'], env).strip().splitlines()[1]
                base = 'http://127.0.0.1:' + env['KANSOKU_SERVER_PORT']
                stopped = []
                mismatch = self.scenario.startswith('mismatch')
                stall = self.scenario.endswith('stall')
                warm = self.scenario == 'mismatch-cached'
                originals = {}
                def damage():
                    for index in range(len(ids)):
                        path = Path(data['root']) / ('r'+str(index+1)) / 'config.xml'
                        originals[index] = path.read_text()
                        # Preserve two expected local UUIDs but make cluster cardinality unsafe.
                        path.write_text(originals[index].replace('</shard>', '<replica><host>127.0.0.1</host><port>9000</port></replica></shard>'))
                        query(index, 'SYSTEM RELOAD CONFIG')
                if mismatch and not warm:
                    if self.scenario == 'mismatch-target':
                        rogue, rogue_query, _, _ = extra.enter_context(fixture(direct=True))
                        rogue_query(0, 'CREATE DATABASE analytics ENGINE=Atomic')
                        rogue_query(0, "CREATE USER app IDENTIFIED WITH plaintext_password BY 'test-password'")
                        rogue_query(0, 'GRANT SELECT ON *.* TO app')
                        proxy.ports = rogue['nativePorts']
                    elif self.scenario == 'mismatch-rollout':
                        env['KANSOKU_CH_MIGRATION_REPLICA_IDS'] = ids[0] + ',00000000-0000-0000-0000-000000000000'
                    elif self.scenario == 'mismatch-direct':
                        env.pop('KANSOKU_CH_MIGRATION_CLUSTER')
                        env.pop('KANSOKU_CH_MIGRATION_REPLICA_IDS')
                    else:
                        damage()
                elif not warm and not stall:
                    stopped = list(range(len(ids))) if direct or self.scenario.endswith('all') else [1]
                    for index in stopped:
                        lifecycle(index)
                with stalled_native() as stall_port:
                    if stall:
                        proxy.ports = [stall_port]
                    launched = time.monotonic()
                    with child([self.binaries['kansoku-server']], env, self.root, 'server') as process:
                        pid = process.pid
                        eventually(lambda: process.poll() is None and http(base, '/health/ready')[0] == 200, 'admission startup', 10)
                        self.health(base)
                        if warm:
                            self.event(base, key)
                            eventually(lambda: self.pg("SELECT count(*) FROM pgmq.q_buffer_events") == '0', 'warm writer drain')
                            self.report['warmAccepted'] = list(self.report['accepted'])
                            damage()
                        if mismatch:
                            eventually(lambda: http(base, '/health/pipeline')[1]['check'] == 'clickhouse_topology_mismatch', 'empty queue mismatch observation', 25)
                        submissions_before = proxy.insert_submissions
                        self.event(base, key)
                        assert int(self.pg("SELECT count(*) FROM pgmq.q_buffer_events")) >= 1
                        self.report['startupToPersistedEventSeconds'] = time.monotonic() - launched
                        if not warm and not mismatch:
                            assert self.report['startupToPersistedEventSeconds'] < 10
                        assert int(self.pg("SELECT count(*) FROM pgmq.q_buffer_events")) >= 1
                        self.event(base, key)
                        self.event(base, key)
                        depth = len(self.report['accepted']) - len(self.report.get('warmAccepted', []))
                        began = time.monotonic()
                        while time.monotonic() - began < 5:
                            self.health(base, pipeline=503)
                            assert int(self.pg("SELECT count(*) FROM pgmq.q_buffer_events")) >= depth
                            assert process.poll() is None and process.pid == pid
                            time.sleep(.5)
                        self.event(base, key)
                        metrics = http(base, '/internal/metrics')[1]
                        assert 'kansoku_queue_length' in metrics and 'kansoku_writer_breaker_state' in metrics
                        def sampled_failure():
                            values = {}
                            for line in http(base, '/internal/metrics')[1].splitlines():
                                if line and not line.startswith('#'):
                                    fields = line.split()
                                    if len(fields) == 2:
                                        values[fields[0]] = float(fields[1])
                            self.report['failureMetrics'] = {k:v for k,v in values.items() if k in ['kansoku_queue_length','kansoku_queue_oldest_message_age_seconds','kansoku_writer_breaker_state']}
                            return values.get('kansoku_queue_length', 0) >= 3 and values.get('kansoku_queue_oldest_message_age_seconds', 0) >= 5 and values.get('kansoku_writer_breaker_state', 0) >= 1
                        eventually(sampled_failure, 'queue depth, oldest age and open breaker metrics', 25)
                        self.report['metrics'] = metrics
                        if mismatch:
                            assert proxy.insert_submissions == submissions_before, 'unsafe topology submitted an event INSERT'
                            self.report['unsafeInsertSubmissions'] = 0
                            for index in range(len(ids)):
                                actual = query(index, 'SELECT event_id FROM analytics.events_raw ORDER BY event_id')
                                assert [row['event_id'] for row in actual] == sorted(self.report.get('warmAccepted', [])), actual
                        restored = time.monotonic()
                        for index in stopped:
                            lifecycle.start(index)
                        if stall or self.scenario == 'mismatch-target':
                            proxy.ports = data['nativePorts']
                        for index, text in originals.items():
                            path = Path(data['root']) / ('r'+str(index+1)) / 'config.xml'
                            path.write_text(text)
                            query(index, 'SYSTEM RELOAD CONFIG')
                        if self.scenario in ['mismatch-rollout', 'mismatch-direct']:
                            # Environment changes require a rollout; the queue is retained.
                            process.terminate()
                            process.wait(timeout=40)
                            env.update(KANSOKU_CH_MIGRATION_CLUSTER='fixture', KANSOKU_CH_MIGRATION_REPLICA_IDS=','.join(ids))
                            with child([self.binaries['kansoku-server']], env, self.root, 'rollout') as rolled:
                                self.finish(base, query, ids, restored, rolled)
                            self.report['requiresRollout'] = True
                        else:
                            self.finish(base, query, ids, restored, process)
                            assert process.pid == pid and process.poll() is None
                            self.report['sameServerPid'] = True
                            if self.scenario.startswith('admission'):
                                begun = json.loads(self.run([self.binaries['kansoku-ch-migrate'], 'maintenance', 'begin', '--expect-target', env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned buffering proof', '--reason', 'maintenance admission check', '--json'], env))
                                assert begun['result']['id']
                                code, _ = http(base, '/v1/events', dict(eventId='maintenance-protected', eventName='page_view', source='web', occurredAt=datetime.now(timezone.utc).isoformat(), receivedAt=datetime.now(timezone.utc).isoformat(), userId='buffer-user', properties={}, context={}), key)
                                assert code == 503, 'maintenance did not protect ingest'
                                self.report['maintenanceIngestStatus'] = code
                                self.run(['pg_ctl', '-D', env['KANSOKU_OWNED_POSTGRES_ROOT'], 'stop', '-m', 'fast'], env)
                                eventually(lambda: http(base, '/health/ready')[0] == 503, 'PostgreSQL admission failure', 5)
                                self.report['postgresReadyStatus'] = 503
                        self.report['serverPid'] = pid
                assert proxy.idle.wait(5), 'cancelled observer/writer leaked native sockets'
            self.report['status'] = 'passed'
            return self.report
        finally:
            (self.root / 'report.private.json').write_text(json.dumps(self.report, indent=2))

    def finish(self, base, query, ids, restored, process):
        def first_written():
            return len(query(0, 'SELECT event_id FROM analytics.events_canonical')) > len(self.report.get('warmAccepted', []))
        eventually(first_written, 'first recovered write', max(.1, 60 - (time.monotonic() - restored)))
        self.report['firstRecoveredWriteSeconds'] = time.monotonic() - restored
        eventually(lambda: self.pg("SELECT count(*) FROM pgmq.q_buffer_events") == '0', 'queue drained', max(.1, 120 - (time.monotonic() - restored)))
        self.report['drainSeconds'] = time.monotonic() - restored
        for index in range(len(ids)):
            expected = sorted(self.report['accepted'])
            def replicated():
                actual = query(index, 'SELECT event_id FROM analytics.events_canonical ORDER BY event_id')
                return [row['event_id'] for row in actual] == expected
            eventually(replicated, 'independent exact canonical IDs')
            physical = query(index, 'SELECT event_id,count() AS n FROM analytics.events_raw GROUP BY event_id ORDER BY event_id')
            assert [row['event_id'] for row in physical] == expected and all(row['n'] == 1 for row in physical), physical
            self.report.setdefault('replicaResults', []).append(dict(id=ids[index], physical=physical, canonical=expected))
        assert self.pg("SELECT count(*) FROM pgmq.a_buffer_events") == '0'
        eventually(lambda: http(base, '/health/pipeline')[0] == 200, 'pipeline recovery', 30)
        self.health(base, pipeline=200)
        assert process.poll() is None


def public_report(report):
    summary = {key:value for key,value in report.items() if key not in ['binaries','serverPid','replicaIds','metrics','observations']}
    summary['healthObservations'] = []
    for observation in report['observations']:
        value = dict(ready=observation['ready'][0], pipeline=observation['pipeline'][0], check=observation['pipeline'][1]['check'])
        if value not in summary['healthObservations']:
            summary['healthObservations'].append(value)
    return summary


def main():
    os.umask(0o077)
    for sig in [signal.SIGINT, signal.SIGTERM]:
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(RuntimeError('owned buffering proof interrupted')))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packaged', action='store_true')
    parser.add_argument('--package-output', help='Use an already built immutable Nix package output (requires --packaged)')
    parser.add_argument('--production-fixture', action='store_true', help='Major qualification: exact Altinity Linux image with Apple Container')
    parser.add_argument('--case', choices=['startup','admission','recovery','mismatch'])
    args = parser.parse_args()
    if args.production_fixture:
        global fixture, IMAGE, VERSION
        from apple_clickhouse_fixture import fixture, IMAGE, VERSION
    names = ['kansoku-server','kansoku-admin','kansoku-ch-migrate','kansoku-migrate']
    if args.package_output and not args.packaged:
        parser.error('--package-output requires --packaged')
    if args.packaged:
        package = args.package_output or json.loads(subprocess.check_output(['nix','build','.#kansoku-server','--no-link','--no-write-lock-file','--json'], text=True))[0]['outputs']['out']
        binaries = {name: package+'/bin/'+name for name in names}
    else:
        binaries = {name: binary('kansoku-server:exe:'+name) for name in names}
    scenarios = {
        'startup': [('replicated','startup-one'),('replicated','startup-all'),('direct','startup-all'),('replicated','startup-stall'),('direct','startup-stall')],
        'admission': [('replicated','admission-one'),('replicated','admission-all'),('direct','admission-all')],
        'recovery': [('replicated','recovery-one'),('direct','recovery-all')],
        'mismatch': [('replicated','mismatch-target'),('replicated','mismatch-inventory'),('replicated','mismatch-cached'),('replicated','mismatch-rollout'),('replicated','mismatch-direct')],
    }
    selected = scenarios[args.case] if args.case else [case for group in scenarios.values() for case in group]
    assert selected, 'zero selected cases'
    reports = [Case(args.packaged, binaries, *case).exercise() for case in selected]
    destination = Path('docs/evidence/clickhouse-buffering')
    destination.mkdir(parents=True, exist_ok=True)
    summary = [public_report(report) for report in reports]
    (destination / ('acceptance-'+('production-' if args.production_fixture else 'nix-')+(args.case or 'all')+('-packaged' if args.packaged else '-development')+'.json')).write_text(json.dumps(summary, indent=2)+'\n')
    families = ', '.join(sorted({report['topology'] for report in reports}))
    print(f'ClickHouse buffering acceptance passed: {len(reports)} cases; {families} topologies; zero skipped', flush=True)


if __name__ == '__main__':
    main()
