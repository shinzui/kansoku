#!/usr/bin/env python3
"""Required owned proofs of the actual CLI/coordinator boundary; no ambient targets."""
from contextlib import contextmanager
import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid

from isolated_clickhouse import isolated_clickhouse, free_port
from isolated_postgres import isolated_postgres

REPO = Path(__file__).resolve().parents[1]


class FaultProxy:
    """One owned fault after a complete observed response; never log SQL/auth."""
    def __init__(self, endpoint):
        self.upstream = urllib.parse.urlsplit(endpoint)
        self.events = []
        self.match = None
        self.hold = False
        self.release = threading.Event()
        self.triggered = threading.Event()
        owner = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_):
                pass
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                application = not body.lstrip().upper().startswith(b'SELECT') and b'kansoku_migration_ledger' not in body
                connection = http.client.HTTPConnection(owner.upstream.hostname, owner.upstream.port, timeout=60)
                try:
                    connection.request('POST', self.path, body=body, headers={'Authorization': self.headers.get('Authorization', '')})
                    response = connection.getresponse()
                    payload = response.read()
                    owner.events.append(dict(application=application, status=response.status))
                    drop = owner.match and all(part in body for part in (owner.match if isinstance(owner.match, tuple) else (owner.match,)))
                    if drop:
                        owner.match = None
                        owner.triggered.set()
                        if owner.hold:
                            owner.release.wait(timeout=60)
                        self.close_connection = True
                        return
                    self.send_response(response.status)
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                finally:
                    connection.close()
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = 'http://127.0.0.1:' + str(self.server.server_address[1])

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)

    def application_count(self):
        return sum(event['application'] for event in self.events)


class Harness:
    def __init__(self, root, native, upgrade, pg_migrate, admin, env, controller):
        self.root, self.native, self.upgrade, self.pg_migrate, self.admin = Path(root), native, upgrade, pg_migrate, admin
        self.env, self.controller, self.sequence = dict(env), controller, 0
        self.endpoint = 'http://127.0.0.1:' + self.env['CLICKHOUSE_HTTP_PORT']
        identity = self.sql('SELECT toString(serverUUID())').strip()
        self.env.update(KANSOKU_CH_MIGRATION_TARGET='kansoku/owned-' + uuid.uuid4().hex,
                        KANSOKU_CH_MIGRATION_ENDPOINT=self.endpoint,
                        KANSOKU_CH_MIGRATION_SERVER_ID=identity,
                        KANSOKU_CH_MIGRATION_LEDGER_ID=str(uuid.uuid4()))
        self.run([pg_migrate, 'up'])

    def run(self, command, *, success=True, env=None, timeout=480, input=None):
        self.sequence += 1
        result = subprocess.run(command, env=env or self.env, capture_output=True, text=True, timeout=timeout, input=input)
        (self.root / f'command-{self.sequence}.private').write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == success, f'Unexpected CLI outcome at private command {self.sequence}'
        return result

    def sql(self, query, input=None):
        return self.run(['clickhouse-client', '--host', '127.0.0.1', '--port', self.env['CLICKHOUSE_TCP_PORT'], '--query', query], input=input).stdout

    def begin(self):
        result = self.run([self.native, 'maintenance', 'begin', '--json', '--expect-target', self.env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned acceptance', '--reason', 'isolated target proof'])
        self.env['KANSOKU_CH_MIGRATION_SESSION'] = json.loads(result.stdout)['result']['id']

    def counter(self):
        result = self.run([self.native, 'maintenance', 'status', '--json'])
        return json.loads(result.stdout)['result']['entry']

    def drain(self):
        # No submitting client is left running by Harness.run. Fault proxies must
        # be stopped before this method: a delayed proxy could submit afterwards.
        self.controller['restart']()
        self.last_drained_counter = self.counter()
        return self.last_drained_counter

    def audit(self):
        return ['--expect-target', self.env['KANSOKU_CH_MIGRATION_TARGET'], '--actor', 'owned acceptance', '--reason', 'owned clients stopped and server restarted', '--quiescent', '--evidence', str(self.root / 'drain.private')]

    def entry(self, arguments, *, binary=None, success=True, predecessor=None, drain=True):
        n = self.drain() if drain else self.counter()
        if predecessor is not None:
            n = predecessor
        (self.root / 'drain.private').write_text(json.dumps(dict(session=self.env['KANSOKU_CH_MIGRATION_SESSION'], predecessor=n, server=self.env['KANSOKU_CH_MIGRATION_SERVER_ID'], ledger=self.env['KANSOKU_CH_MIGRATION_LEDGER_ID'], clients_stopped=True, server_restarted=drain or getattr(self,'last_drained_counter',None)==n)))
        return self.run([binary or self.native, '--predecessor', str(n), *arguments, '--json', *self.audit()], success=success)

    def observed_entry(self, arguments, *, expected_sql, binary=None, success=True):
        self.drain()
        proxy = FaultProxy(self.endpoint)
        try:
            self.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            result = self.entry(arguments,binary=binary,success=success,drain=False)
            assert proxy.application_count() == expected_sql, 'Selected repair submitted unexpected application SQL'
            (self.root / f'repair-requests-{self.sequence}.private').write_text(json.dumps(proxy.events))
            return result
        finally:
            proxy.close()
            self.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = self.endpoint

    def up(self, *, first=False, **kwargs):
        args = ['up']
        if first:
            args += ['--initialize-ledger', self.env['KANSOKU_CH_MIGRATION_LEDGER_ID']]
        return self.entry(args, **kwargs)

    def finish(self, **kwargs):
        return self.entry(['maintenance', 'finish'], **kwargs)


@contextmanager
def owned(root, native, upgrade, pg_migrate, admin):
    controller = {}
    with isolated_postgres(root / 'postgres') as pg:
        with isolated_clickhouse(directory=root / 'clickhouse', controller=controller) as ch:
            env = dict(pg)
            env.update({key: value for key, value in ch.items() if key.startswith(('CLICKHOUSE_', 'KANSOKU_CLICKHOUSE_', 'KANSOKU_OWNED_CLICKHOUSE_'))})
            yield Harness(root, native, upgrade, pg_migrate, admin, env, controller)


def repair_arguments(h, operation, selected=False, extra=()):
    result = json.loads(h.run([h.upgrade, *extra, 'status', '--guarded', '--json']).stdout)['result']['report']
    migration = result['migrations'][-1]
    args = ['repair', operation, '--expect-position', result['observation']['position'], '--attempt', migration['attempt']]
    if selected:
        step = next(step for step in migration['steps'] if step['state'] in ('uncertain', 'observed-failure'))
        attempt = step['attempt']
        args += ['--step-attempt', attempt['ownerAttempt'], '--step', attempt['step'], '--query-id', attempt['queryId']]
    return args


def recovery_case(root, native, upgrade, pg_migrate, admin, retry):
    with owned(root, native, upgrade, pg_migrate, admin) as h:
        h.begin()
        h.up(first=True)
        h.drain()
        proxy = FaultProxy(h.endpoint)
        proxy.match = b'INSERT INTO analytics.__native_upgrade_probe VALUES'
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            lost = h.up(binary=upgrade, success=False, drain=False)
            assert proxy.triggered.is_set(), 'Fault must follow a demonstrably observed committed response'
            assert json.loads(lost.stdout)['status'] == 'error'
        finally:
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
        # Fresh processes see uncertainty; a complete external drain alone cannot
        # authorize ordinary up to replay the interrupted step.
        h.up(binary=upgrade, success=False)
        h.finish(binary=upgrade, success=False)
        selected = repair_arguments(h, 'retry-step' if retry else 'accept-step', True)
        h.observed_entry(selected, binary=upgrade, expected_sql=1 if retry else 0)
        expected = '2' if retry else '1'
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == expected
        # A stale native position/attempt refuses even with fresh session evidence.
        h.observed_entry(selected, binary=upgrade, success=False, expected_sql=0)
        h.observed_entry(repair_arguments(h, 'resume'), binary=upgrade, expected_sql=1)
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == expected
        h.finish(binary=upgrade)
    return 1


def append_and_initialization_cases(root, native, upgrade, pg_migrate, admin):
    with owned(root / 'append', native, upgrade, pg_migrate, admin) as h:
        h.begin()
        h.up(first=True)
        h.drain()
        proxy = FaultProxy(h.endpoint)
        proxy.match = (b'step-succeeded', b'finish-probe')
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            lost = json.loads(h.up(binary=upgrade, success=False, drain=False).stdout)
            assert proxy.triggered.is_set()
        finally:
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        receipt = lost['error']['primary']['pendingAppend']
        assert receipt
        row = json.loads(h.run([native, 'maintenance', 'status', '--json']).stdout)['result']
        assert receipt in row['pending_receipts']
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
        h.up(binary=upgrade, success=False)
        h.entry(['maintenance', 'reconcile', '--pending-append', receipt], binary=upgrade, success=False)
        # Omission of an exact retained receipt refuses at the app boundary.
        args = repair_arguments(h, 'finalize')
        h.entry(args, binary=upgrade, success=False)
        h.observed_entry([*repair_arguments(h, 'finalize'), '--pending-append', receipt], binary=upgrade, expected_sql=0)
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
        h.finish(binary=upgrade)
    with owned(root / 'initialization', native, upgrade, pg_migrate, admin) as h:
        h.begin()
        ledger = h.env['KANSOKU_CH_MIGRATION_LEDGER_ID']
        h.drain()
        proxy = FaultProxy(h.endpoint)
        proxy.match = b'CREATE TABLE IF NOT EXISTS `kansoku_migration_ledger`'
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            h.up(first=True, success=False, drain=False)
            assert proxy.triggered.is_set()
        finally:
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        h.up(first=True, success=False)
        h.entry(['maintenance', 'reconcile'])
        h.up(first=True)
        row = json.loads(h.run([native, 'maintenance', 'status', '--json']).stdout)['result']
        assert row['ledger_id'] == ledger
        h.finish()
    return 2


def parity_observation(query):
    schema = query("SELECT table,name,type,default_kind,default_expression FROM system.columns WHERE database='analytics' ORDER BY table,position")
    base = dict(source='web', occurred_at='2026-07-01 12:00:00.000', received_at='2026-07-01 12:00:01.000', user_id='parity-user', account_id='migration-parity', session_id='parity-session', url='/migration-parity', properties={'url':'/migration-parity'}, context={})
    page = dict(base, event_id='parity-page', event_name='page_view')
    payment = dict(base, event_id='parity-payment', event_name='payment_completed', properties={'amount':7,'plan':'pro'})
    query('INSERT INTO analytics.events_raw FORMAT JSONEachRow', input='\n'.join(json.dumps(event) for event in [page,page,payment]))
    raw = query("SELECT event_id,event_name,toJSONString(properties) FROM analytics.events_raw WHERE account_id='migration-parity' ORDER BY event_id,event_name")
    derived = query("SELECT event_name,uniqExactMerge(events) FROM analytics.daily_event_counts WHERE account_id='migration-parity' GROUP BY event_name ORDER BY event_name")
    reader = query("SELECT event_id,event_name,canonical_user,properties_json FROM analytics.events_analytics_v1(account='migration-parity',from_time='2026-07-01 00:00:00',to_time='2026-07-02 00:00:00') ORDER BY event_id")
    assert 'page_view' in derived and 'parity-page' in reader
    return dict(schema=schema, raw=raw, derived=derived, reader=reader)


def original_parity(root, expected):
    with isolated_clickhouse(directory=root) as env:
        sequence = 0
        def query(sql, input=None, multi=False):
            nonlocal sequence
            sequence += 1
            args = ['clickhouse-client','--host','127.0.0.1','--port',env['CLICKHOUSE_TCP_PORT']]
            if multi:
                args += ['--multiquery']
            else:
                args += ['--query',sql]
            result = subprocess.run(args, input=input, env=env, text=True, capture_output=True, timeout=120)
            (root / f'parity-{sequence}.private').write_text(result.stdout + result.stderr)
            result.check_returncode()
            return result.stdout
        # Original replay is confined to this separate fresh owned parity fixture.
        # It is never an operator entry point and creates no filename ledger.
        for source in sorted((REPO / 'db/clickhouse/migrations').glob('*.sql')):
            query('', input=source.read_text(), multi=True)
        actual = parity_observation(query)
        assert actual == expected, 'Original/native schema or raw/derived/reader results differ'
        (root / 'observations.private').write_text(json.dumps(actual))
    return 1


def refuse_legacy_case(root, native, upgrade, pg_migrate, admin):
    with owned(root, native, upgrade, pg_migrate, admin) as h:
        h.sql('CREATE DATABASE analytics')
        h.sql('CREATE TABLE analytics.schema_migrations (filename String) ENGINE=MergeTree ORDER BY filename')
        h.sql("INSERT INTO analytics.schema_migrations VALUES ('unimported-development.sql')")
        h.begin()
        h.drain()
        proxy = FaultProxy(h.endpoint)
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            h.up(first=True, success=False, drain=False)
            assert proxy.application_count() == 0
        finally:
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        assert h.sql('SELECT count() FROM analytics.schema_migrations').strip() == '1'
        assert h.sql("SELECT count() FROM system.databases WHERE name='kansoku_migration_ledger'").strip() == '0'
        h.finish(success=False)
    return 1


def verify(root, native, upgrade, pg_migrate, admin, server):
    assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Native migration acceptance requires the qualified Darwin/arm64 artifact; Linux qualification is unresolved'
    from check_clickhouse_conversion import verify as verify_conversion
    verify_conversion()
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Plan and unsupported adoption must work/refuse without live configuration.
    offline = {key: value for key, value in os.environ.items() if not key.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_'))}
    result = subprocess.run([native, 'plan', '--json'], env=offline, capture_output=True, text=True, check=True)
    plan = json.loads(result.stdout)['result']['components']
    assert len(plan) == 1 and len(plan[0]['migrations']) == 25
    assert sum(len(m['steps']) for m in plan[0]['migrations']) == 257
    adoption = subprocess.run([native, 'adopt', 'apply', '--expect-target', 'kansoku/refused', '--expect-absent', '--initialize-ledger', str(uuid.uuid4()), '--actor', 'owned acceptance', '--reason', 'unsupported import check', '--quiescent', '--evidence', 'owned offline proof', '--request', str(root / 'must-not-open.json')], env=offline, capture_output=True, text=True)
    assert adoption.returncode != 0 and 'Legacy import is unsupported' in adoption.stderr
    assert not (root / 'must-not-open.json').exists()
    cases = 2
    with owned(root, native, upgrade, pg_migrate, admin) as h:
        h.begin()
        # No current ledger: recurring up refuses to initialize.
        h.up(success=False)
        h.entry(['maintenance', 'reconcile'])
        assert h.sql("SELECT count() FROM system.databases WHERE name='kansoku_migration_ledger'").strip() == '0'
        h.up(first=True)
        assert h.sql("SELECT count() FROM system.tables WHERE database='analytics' AND startsWith(name,'__chm_legacy_assert_')").strip() == '0'
        h.run([native, 'verify', '--require-current', '--json'])
        native_observation = parity_observation(h.sql)
        h.up(predecessor=0, success=False)
        h.up(binary=upgrade, success=False, drain=True, predecessor=0)
        # Baseline repeat submits no application SQL, counted at the boundary.
        proxy = FaultProxy(h.endpoint)
        try:
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = proxy.endpoint
            h.up(drain=False)
            wrong = dict(h.env, KANSOKU_CH_MIGRATION_SERVER_ID='00000000-0000-0000-0000-000000000000')
            h.run([native,'status','--json'],env=wrong,success=False)
            assert proxy.application_count() == 0
            h.entry(['--proof-change-applied-step', 'up'], binary=upgrade, drain=False, success=False)
            assert proxy.application_count() == 0
        finally:
            proxy.close()
            h.env['KANSOKU_CH_MIGRATION_ENDPOINT'] = h.endpoint
        h.entry(['maintenance', 'reconcile'])
        h.finish()
        cases += 5
        # An appended native migration runs once through a distinct compiled CLI.
        h.begin()
        h.up(binary=upgrade)
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
        h.up(binary=upgrade)
        assert h.sql('SELECT count() FROM analytics.__native_upgrade_probe').strip() == '1'
        h.finish(binary=upgrade)
        cases += 1
    cases += refuse_legacy_case(root / 'refuse-legacy', native, upgrade, pg_migrate, admin)
    cases += original_parity(root / 'original-parity', native_observation)
    cases += append_and_initialization_cases(root / 'boundaries', native, upgrade, pg_migrate, admin)
    for retry in (False, True):
        cases += recovery_case(root / ('retry' if retry else 'accept'), native, upgrade, pg_migrate, admin, retry)
    from clickhouse_coordination_acceptance import verify_coordination
    cases += verify_coordination(root / 'coordination',native,upgrade,pg_migrate,admin,server,owned,FaultProxy,repair_arguments)
    print(f'ClickHouse migrations: {cases} cases, 0 failures, 0 skipped', flush=True)
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary')
    parser.add_argument('--upgrade-binary')
    parser.add_argument('--pg-migrate')
    parser.add_argument('--admin')
    parser.add_argument('--server')
    parser.add_argument('--packaged', action='store_true')
    parser.add_argument('--root')
    args = parser.parse_args()
    supplied = (args.binary,args.upgrade_binary,args.pg_migrate,args.admin,args.server)
    if args.packaged or not any(supplied):
        assert not any(supplied), 'Packaged acceptance cannot mix supplied binaries'
        assert platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Native acceptance is unqualified on this platform; no skip/fallback is allowed'
        def build(attribute):
            result = subprocess.check_output(['nix','build','.#'+attribute,'--no-link','--json'],text=True,cwd=REPO)
            return Path(json.loads(result)[0]['outputs']['out']) / 'bin'
        production = build('kansoku-server')
        proof = build('kansoku-ch-migrate-upgrade-proof')
        args.binary,args.upgrade_binary,args.pg_migrate,args.admin,args.server = map(str,(production/'kansoku-ch-migrate',proof/'kansoku-ch-migrate-upgrade-proof',production/'kansoku-migrate',production/'kansoku-admin',production/'kansoku-server'))
    else:
        assert all(supplied), 'Supply every executable explicitly or use --packaged'
    os.umask(0o077)
    parent = REPO / '.dev/acceptance'
    parent.mkdir(parents=True, exist_ok=True)
    root = Path(args.root or tempfile.mkdtemp(prefix='ch-migrations-', dir=parent))
    print('Private migration acceptance evidence: ' + str(root), flush=True)
    cases = verify(root, args.binary, args.upgrade_binary, args.pg_migrate, args.admin, args.server)
    (root / 'sanitized').mkdir(exist_ok=True)
    (root / 'sanitized/clickhouse-migrations.log').write_text(f'{cases} cases, 0 failures, 0 skipped\n')


if __name__ == '__main__':
    main()
