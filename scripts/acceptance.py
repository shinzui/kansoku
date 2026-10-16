#!/usr/bin/env python3
"""Executable acceptance: fresh data, owned processes, private raw and sanitized evidence."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid

from clickhouse_migrations_acceptance import verify as verify_clickhouse_migrations
from ingest_acceptance import verify_ingest
from json_storage_acceptance import verify_json_storage
from acceptance_fixture_isolation import verify_fixture_isolation
from activity_acceptance import verify_activity
from funnel_acceptance import verify_funnels
from traits_acceptance import verify_traits
from cohorts_acceptance import verify_cohorts
from custom_metrics_acceptance import verify_custom_metrics
from admin_acceptance import verify_admin
from beacon_acceptance import verify_beacon_browser
from identity_browser_acceptance import verify_identity_browser
from sdk_protocol_acceptance import verify_sdk_protocol
from enrichment_acceptance import ADDRESSES, verify_enrichment, verify_country_disabled
from isolated_clickhouse import isolated_clickhouse, apply_migrations, free_port
from test_support import binary, execute, hspec, probes

REPO = Path(__file__).resolve().parent.parent
SUITE = REPO / 'kansoku-api/test/hurl'
os.chdir(REPO)
os.umask(0o077)
# Only the parent directory is configurable. Every run creates its own fresh child.
parent = Path(os.environ.get('KANSOKU_ACCEPTANCE_ROOT', REPO / '.dev/acceptance')).resolve()
parent.mkdir(parents=True, exist_ok=True)
ROOT = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
SAFE = ROOT / 'sanitized'
SAFE.mkdir()
TOKENS = []
CHILDREN = []


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def interrupted(signum, frame):
    raise RuntimeError(f'acceptance interrupted by signal {signum}')


for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, interrupted)


@contextmanager
def child(command, env, name):
    with (ROOT / f'{name}.log').open('w') as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        CHILDREN.append(process)
        with (ROOT / 'processes.jsonl').open('a') as inventory:
            inventory.write(json.dumps(dict(pid=process.pid, name=name)) + '\n')
        try:
            yield process
        finally:
            stop(process)


def run(command, env, name, timeout=180, **kwargs):
    result = execute(command, env=env, timeout=timeout, **kwargs)
    (ROOT / f'{name}.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    if name in ('native-recovery', 'native-limits'):
        summaries = re.findall(r'(\d+) examples?, (\d+) failures(?:, (\d+) pending)?', result.stdout)
        if not summaries or any(int(count) == 0 or int(failed) != 0 or int(pending or 0) != 0
                                for count, failed, pending in summaries):
            raise RuntimeError(f'{name}: missing nonzero, passing, non-pending native evidence')
    print(f'{name}: passed', flush=True)
    return result.stdout


def wait_for(process, check, label):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'{label} exited during startup; see private logs')
        try:
            if check():
                return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(.1)
    raise RuntimeError(f'{label} did not become ready in 30 seconds')


def request(base, path, token=None, headers=None):
    hdrs = dict(headers or {})
    if token:
        hdrs['Authorization'] = f'Bearer {token}'
    with urllib.request.urlopen(urllib.request.Request(base + path, headers=hdrs), timeout=3) as response:
        return json.load(response)


def hurl(files, env, name, variables=()):
    command = ['hurl', '--test', '--jobs', '1', '--variables-file', str(SUITE / 'vars.env'),
               '--secrets-file', str(ROOT / 'secrets.env'), '--file-root', str(ROOT)]
    for value in variables:
        command.extend(['--variable', value])
    output = run(command + [str(SUITE / file) for file in files], env, name)
    # Hurl prints its summary on stderr; inspect the complete captured log.
    report = (ROOT / f'{name}.log').read_text()
    match = re.search(r'Executed files:\s*(\d+)', report)
    requests = re.search(r'Executed requests:\s*(\d+)', report)
    if not match or int(match[1]) != len(files) or not requests or int(requests[1]) == 0 or not re.search(r'Failed files:\s*0', report):
        raise RuntimeError(f'{name}: missing nonzero Hurl execution summary')
    print(f'{name}: {match[1]} files, {requests[1]} requests, zero failed files', flush=True)
    return output


def clean_environment():
    # Do not inherit ambient service locations, exporters, credentials, or test switches.
    return {key: value for key, value in os.environ.items()
            if not key.startswith(('PG', 'CLICKHOUSE', 'KANSOKU_', 'OTEL_'))}


def seed(env):
    rows = []
    for user, variant in [('u1', 'control'), ('u2', 'treatment')]:
        for event, minute, props in [('experiment_viewed', 0, {'experiment': 'checkout_v2', 'variant': variant}),
                                     ('page_view', 1, {}), ('signup_started', 2, {})]:
            rows.append((user, event, 1, minute, props))
    rows += [('u1', 'signup_completed', 1, 3, {}), ('u1', 'feature_used', 2, 0, {'feature': 'export'}),
             ('u1', 'payment_completed', 2, 1, {'amount': 7, 'plan': 'pro'}), ('u1', 'page_view', 2, 2, {}),
             ('u1', 'page_view', 1, 4, {})]
    events = [dict(event_id=f'fixture_{i}', event_name=event, source='web',
                   occurred_at=f'2026-07-{day:02} 12:{minute:02}:00', received_at='2026-07-12 12:00:00',
                   user_id=user, account_id='mp4_metrics', session_id=f'{user}_{day}', url='/home',
                   properties=json.dumps(props), context='{}')
              for i, (user, event, day, minute, props) in enumerate(rows)]
    client = ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT']]
    run(client + ['--query', 'INSERT INTO analytics.events_raw FORMAT JSONEachRow'], env, 'seed-metrics',
        input='\n'.join(json.dumps(event) for event in events))
    run(client + ['--query', '''INSERT INTO analytics.events_raw
      (event_id,event_name,source,occurred_at,received_at,user_id,account_id,properties,context)
      SELECT concat('high_',toString(number)), 'payment_completed', 'web',
      toDateTime64('2026-07-01 12:00:00',3,'UTC'), toDateTime64('2026-07-01 12:00:01',3,'UTC'),
      concat('u',toString(number)), 'mp4_highcard',
      concat('{"amount":1,"plan":"g',leftPad(toString(number),5,'0'),'"}'), '{}' FROM numbers(10001)'''], env, 'seed-highcard')
    run(client + ['--query', '''INSERT INTO analytics.experiment_exposures
      SELECT 'mp4_highcard', 'bound_exp', concat('v',leftPad(toString(number),5,'0')),
      toDate('2026-07-01'), uniqCombinedState(toString(number)) FROM numbers(10001) GROUP BY number'''], env, 'seed-exposures')


def privacy(name, token, sentinel):
    output = (ROOT / f'{name}.log').read_text()
    assert sentinel not in output, 'query sentinel leaked into complete output'
    assert all(secret not in output for secret in TOKENS), 'credential leaked into output'
    records = []
    for line in output.splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    trace = '4bf92f3577b34da6a3ce929d0e0e4736'
    spans = [row for row in records if row.get('kind') == 'span' and row.get('trace_id') == trace
             and row.get('name', '').startswith('GET')]
    accesses = [row for row in records if row.get('trace_id') == trace and 'method' in row]
    assert len(spans) == len(accesses) == 1, (name, 'expected one HTTP span and access record')
    assert spans[0]['span_id'] == accesses[0]['span_id'], 'uncorrelated trace records'
    assert all(key in spans[0] for key in ('attributes', 'events', 'status')), 'incomplete span snapshot'
    attributes = spans[0]['attributes']
    assert '/metrics/revenue' in attributes, 'missing actual production route'
    if name in ('server-legacy', 'server-http-dup'):
        assert '("http.target",AttributeValue (TextAttribute "/metrics/revenue"))' in attributes, 'legacy target is not path-only'
    if name in ('server-http', 'server-http-dup'):
        assert '"url.path"' in attributes, 'stable semantic mode was not enabled'
        assert '"url.query"' not in attributes or '("url.query",AttributeValue (TextAttribute ""))' in attributes, 'stable query captured values'
    assert not any(row.get('path') in ('/health', '/ready', '/health/live', '/health/ready')
                   for row in records if 'method' in row), 'probe access record emitted'
    print(f'{name}: complete span/access privacy and correlation passed', flush=True)


def main():
    print(f'Private acceptance evidence: {ROOT}', flush=True)
    sdk_path = os.environ.get('KANSOKU_SDK_PROJECT')
    if os.environ.get('KANSOKU_REQUIRE_SDK') == '1' and not sdk_path:
        raise RuntimeError('Required SDK acceptance needs KANSOKU_SDK_PROJECT')
    sdk = Path(sdk_path).resolve() if sdk_path else None
    if sdk and not (sdk / 'test/live/traits.test.ts').is_file():
        raise RuntimeError('Configured SDK lacks required governed trait acceptance')
    if sdk and not (sdk / 'scripts/beacon-browser.ts').is_file():
        raise RuntimeError('Configured SDK lacks required beacon browser acceptance')
    consumer_keys=('KANSOKU_GROWTHBOOK_SOURCE','KANSOKU_GRAFANA_HOME','KANSOKU_GRAFANA_PLUGINS')
    consumers={key:os.environ[key] for key in consumer_keys if key in os.environ}
    if os.environ.get('KANSOKU_REQUIRE_CONSUMERS')=='1' and len(consumers)!=len(consumer_keys):
        raise RuntimeError('Required consumer gate needs pinned GrowthBook source, Grafana home and plugin paths')
    env = clean_environment()
    builds = json.loads(run(['nix', 'build', '.#kansoku-server', '.#kansoku-client', '--no-link', '--json'], env, 'nix-build', timeout=1200))
    server_output = next(item['outputs']['out'] for item in builds if 'kansoku-server' in item['drvPath'])
    # Execute resolved outputs directly; never inspect the store directory.
    server = server_output + '/bin/kansoku-server'
    admin = server_output + '/bin/kansoku-admin'
    migrate = server_output + '/bin/kansoku-migrate'
    native_migrate = server_output + '/bin/kansoku-ch-migrate'
    proof_build = json.loads(run(['nix','build','.#kansoku-ch-migrate-upgrade-proof','--no-link','--json'],env,'nix-migration-proof-build',timeout=1200))
    upgrade_migrate = proof_build[0]['outputs']['out'] + '/bin/kansoku-ch-migrate-upgrade-proof'
    migration_cases = verify_clickhouse_migrations(ROOT / 'clickhouse-migrations',native_migrate,upgrade_migrate,migrate,admin,server)
    (SAFE / 'clickhouse-migrations.log').write_text(f'{migration_cases} cases, 0 failures, 0 skipped\n')
    env.update(KANSOKU_CH_MIGRATION_BINARY=native_migrate,KANSOKU_PG_MIGRATION_BINARY=migrate)
    env.update(NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost')
    pg = ROOT / 'postgres'
    run(['initdb', '-D', str(pg), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8'], env, 'postgres-init')
    pgport = free_port()
    # Unix socket path lengths are limited on macOS; own a short fresh socket directory.
    with tempfile.TemporaryDirectory(prefix='ks-pg-') as socket_dir:
        env.update(PGHOST=socket_dir, PGPORT=str(pgport), PGUSER='postgres', PGDATABASE='postgres',
                   PG_CONNECTION_STRING=f'host={socket_dir} port={pgport} user=postgres dbname=postgres')
        with child(['postgres', '-D', str(pg), '-k', socket_dir, '-p', str(pgport), '-h', '127.0.0.1'], env, 'postgres') as postgres:
            wait_for(postgres, lambda: subprocess.run(['pg_isready'], env=env, capture_output=True).returncode == 0, 'PostgreSQL')
            actual_data = run(['psql', '-Atc', 'SHOW data_directory'], env, 'postgres-ownership').strip()
            assert actual_data == str(pg), 'refusing migrations against an unowned PostgreSQL listener'
            env['KANSOKU_OWNED_POSTGRES_ROOT'] = str(pg)
            run([migrate, 'up'], env, 'postgres-migrations')
            # The shared native launcher uses the now-sanitized environment as its base.
            saved = dict(os.environ)
            os.environ.clear()
            os.environ.update(env)
            try:
                with isolated_clickhouse(directory=ROOT / 'clickhouse') as native_env:
                    env = native_env
                    apply_migrations(env)
                    env['KANSOKU_QUERY_LIMIT_FIXTURES'] = '1'
                    hspec([binary('kansoku-core:test:kansoku-core-test')], env=env, log=ROOT / 'core-tests.log', timeout=300)
                    probes([binary('kansoku-core:test:kansoku-probe-test')], env=env, log=ROOT / 'probe-tests.log')
                    run(['python3', 'scripts/native-query-pool.py'], env, 'native-recovery', timeout=120)
                    run(['python3', 'scripts/query-limits.py'], env, 'native-limits', timeout=300)
                    run(['python3', 'scripts/replay-safety.py'], env, 'native-replay', timeout=240)
                    run(['python3', 'scripts/identity_acceptance.py'], env, 'native-identity', timeout=240)
                    seed(env)
                    env.update(KANSOKU_QUEUE_NAME='acceptance_events', KANSOKU_WRITER_MAX_LATENCY_MS='100',
                               KANSOKU_QUEUE_POLL_INTERVAL_SEC='1', KANSOKU_INGEST_MAX_BODY_BYTES='4096',
                               KANSOKU_CORS_ORIGINS='https://allowed.example', KANSOKU_INGEST_QUARANTINE='true', OTEL_TRACES_EXPORTER='console',
                               OTEL_METRICS_EXPORTER='none', OTEL_BSP_SCHEDULE_DELAY='100', OTEL_TRACES_SAMPLER='always_on')
                    credentials = {}
                    for name, kind, account in [('service_token', 'service', 'mp4_metrics'), ('write_token', 'write', 'mp4_metrics'),
                                                 ('highcard_token', 'service', 'mp4_highcard'), ('write_ingest_token', 'write', 'mp4_ingest'),
                                                 ('service_ingest_token', 'service', 'mp4_ingest'), ('other_token', 'service', 'mp4_other'),
                                                 ('json_write', 'write', 'mp4_json'), ('json_other_write', 'write', 'mp4_json_other'), ('client_token', 'write', 'mp4_client'), ('enrichment_write', 'write', 'mp4_enrichment'), ('enrichment_service', 'service', 'mp4_enrichment')]:
                        result = subprocess.run([server, 'issue-key', '--kind', kind, '--account', account,
                                                 '--description', 'disposable acceptance'], env=env, capture_output=True, text=True, check=True, timeout=15)
                        token = result.stdout.splitlines()[-2]
                        assert token and ' ' not in token, 'invalid issue-key output'
                        TOKENS.append(token)
                        credentials[name] = token
                    (ROOT / 'secrets.env').write_text(''.join(f'{key}={value}\n' for key, value in credentials.items()))
                    (ROOT / 'oversized.json').write_text(' ' * 10000)
                    run(['hurlfmt', '--check'] + [str(SUITE / file) for file in
                        ['health.hurl', 'openapi.hurl', 'schemas.hurl', 'metrics.hurl', 'ingest.hurl', 'perimeter/perimeter.hurl', 'perimeter/metrics-disabled.hurl']], env, 'hurl-format')
                    geo = dict(env,
                        KANSOKU_INGEST_GEOIP_DB=str(REPO / 'kansoku-core/test/fixtures/geoip/GeoIP2-Country-Test.mmdb'),
                        KANSOKU_INGEST_TRUSTED_PROXY_CIDRS='127.0.0.1/32')
                    for label, database in [('missing', str(ROOT / 'absent.mmdb')),
                                            ('corrupt', str(REPO / 'kansoku-core/test/fixtures/geoip/LICENSE-MIT')),
                                            ('unsupported', str(REPO / 'kansoku-core/test/fixtures/geoip/GeoIP2-ISP-Test.mmdb'))]:
                        invalid = subprocess.run([server], env=dict(geo, KANSOKU_INGEST_GEOIP_DB=database), capture_output=True, text=True, timeout=15)
                        (ROOT / ('geo-startup-' + label + '.log')).write_text(invalid.stdout + invalid.stderr)
                        assert invalid.returncode != 0 and 'GeoIP database could not be opened' in invalid.stderr, 'configured invalid GeoIP did not fail clearly'
                    bad = subprocess.run([server], env=dict(env, KANSOKU_SERVER_PORT='not-a-number'), capture_output=True, text=True, timeout=10)
                    (ROOT / 'invalid-startup.log').write_text(bad.stdout + bad.stderr)
                    assert bad.returncode != 0 and 'configuration error' in bad.stderr, 'invalid startup accepted'
                    for mode in ('', 'http', 'http/dup'):
                        name = 'server-' + (mode.replace('/', '-') or 'legacy')
                        port = free_port()
                        base = f'http://127.0.0.1:{port}'
                        settings = dict(geo, KANSOKU_SERVER_PORT=str(port), OTEL_SEMCONV_STABILITY_OPT_IN=mode)
                        sentinel = 'private_query_' + uuid.uuid4().hex
                        with child([server], settings, name) as process:
                            wait_for(process, lambda: request(base, '/health/ready')['status'] == 'ok', name)
                            variables = [f'base_url={base}', f'event_id=acceptance_{uuid.uuid4().hex}', 'oversized_file=oversized.json']
                            if not mode:
                                hurl(['health.hurl', 'openapi.hurl', 'schemas.hurl', 'metrics.hurl'], env, 'hurl-safe', variables)
                                hurl(['ingest.hurl', 'perimeter/perimeter.hurl'], env, 'hurl-stateful', variables)
                                verify_ingest(base, credentials['client_token'], env)
                                verify_json_storage(base, credentials['json_write'], credentials['json_other_write'], env)
                                live = dict(settings, KANSOKU_SERVER_URL=base, KANSOKU_API_KEY=credentials['client_token'])
                                hspec([binary('kansoku-client:test:kansoku-client-test')], env=live, log=ROOT / 'client-tests.log')
                            verify_enrichment(base, credentials['enrichment_write'], credentials['enrichment_service'])
                            verify_activity(base, credentials['enrichment_write'], credentials['enrichment_service'])
                            verify_funnels(base, credentials['enrichment_write'], credentials['enrichment_service'])
                            verify_traits(base, credentials['enrichment_write'], credentials['enrichment_service'])
                            verify_cohorts(base, credentials['enrichment_write'], credentials['enrichment_service'], credentials['other_token'])
                            if not mode:
                                verify_fixture_isolation(base, credentials['enrichment_write'], credentials['enrichment_service'], credentials['other_token'], env=env)
                            if sdk:
                                # mori://shinzui/kansoku-ts (test/live/traits.test.ts; artifact-level URI pending).
                                sdk_env = dict(settings, KANSOKU_TEST_NO_DOM='1', KANSOKU_REQUIRE_LIVE='1',
                                               KANSOKU_LIVE_BASE_URL=base,
                                               KANSOKU_LIVE_WRITE_KEY=credentials['enrichment_write'],
                                               KANSOKU_LIVE_SERVICE_TOKEN=credentials['enrichment_service'])
                                output = run(['bun', 'test', 'test/live/traits.test.ts'], sdk_env,
                                             'sdk-traits-' + name, timeout=90, cwd=sdk)
                                evidence = (ROOT / ('sdk-traits-' + name + '.log')).read_text()
                                if not re.search(r'\b1 pass\b', evidence) or not re.search(r'\b0 fail\b', evidence) or re.search(r'\b[1-9]\d* skip\b', evidence):
                                    raise RuntimeError('SDK trait acceptance needs one passing, non-skipped live test')
                            for path in ('/health', '/ready', '/health/live', '/health/ready'):
                                urllib.request.urlopen(base + path, timeout=3).close()
                            population_filter = urllib.parse.urlencode({'filter': json.dumps(dict(dimension='event_name', op='neq', value=sentinel))})
                            answer = request(base, '/metrics/revenue?from=2026-07-01&to=2026-07-12&groupBy=prop:plan&' + population_filter,
                                             credentials['service_token'], {'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01', 'X-Private': sentinel})
                            assert sum(point['value'] for point in answer['points']) == 7, 'production query parameters lost'
                            assert answer['points'][0]['group'] == {'prop:plan': 'pro'}, 'production grouping parameter lost'
                        privacy(name, credentials['service_token'], sentinel)
                        output = (ROOT / (name + '.log')).read_text(errors='replace')
                        assert all(address not in output for address in ADDRESSES), 'request country address leaked into logs/spans'
                    if sdk:
                        verify_sdk_protocol(server,admin,env,ROOT / 'sdk-protocol',sdk,TOKENS)
                        verify_identity_browser(server,admin,env,ROOT / 'identity-browser',sdk,TOKENS)
                        (SAFE / 'identity-summary.log').write_text('Required SDK live: 9 cases; Chromium identity/handoff/bots: 8 cases; 0 skipped, passed.\n')
                        verify_beacon_browser(server, admin, env, ROOT / 'beacon-browser', sdk, TOKENS)
                        (SAFE / 'beacon-summary.log').write_text('Required Chromium beacon acceptance: 6 cases, 0 skipped, passed.\n')
                    reader_env=dict(env,**consumers,KANSOKU_READER_SERVER=server,KANSOKU_READER_ADMIN=admin,KANSOKU_READER_MIGRATE=migrate)
                    run(['python3','scripts/reader_acceptance.py'],reader_env,'reader-consumers',timeout=600)
                    (SAFE / 'reader-summary.log').write_text('Required constrained reader SQL/HTTP parity and supplied real consumers passed.\n')
                    port = free_port()
                    disabled = dict(env, KANSOKU_SERVER_PORT=str(port), KANSOKU_INTERNAL_METRICS_ENABLED='false')
                    with child([server], disabled, 'server-metrics-disabled') as process:
                        base = f'http://127.0.0.1:{port}'
                        wait_for(process, lambda: request(base, '/health/ready')['status'] == 'ok', 'metrics-disabled')
                        hurl(['perimeter/metrics-disabled.hurl'], env, 'hurl-metrics-disabled', [f'base_url={base}'])
                        verify_country_disabled(base, credentials['enrichment_write'], credentials['enrichment_service'])
                    families = verify_admin(server, admin, env, ROOT / 'admin', TOKENS)
                    assert families == 7, 'required packaged administrative scenario families missing'
                    (ROOT / 'admin-summary.log').write_text('Required packaged kansoku-admin: 7 non-skipped scenario families passed.\n')
            finally:
                os.environ.clear()
                os.environ.update(saved)
    print('Acceptance passed: required native/live tests, Hurl, packaged administration/startup and three telemetry modes.', flush=True)


try:
    main()
finally:
    for process in reversed(CHILDREN):
        stop(process)
    # Raw files remain mode 600 inside a mode 700 directory. CI uploads only this copy.
    for path in ROOT.glob('*.log'):
        output = path.read_text(errors='replace')
        for token in TOKENS:
            output = output.replace(token, '[REDACTED]')
        output = re.sub(r'private_query_[0-9a-f]+', '[REDACTED_QUERY]', output)
        (SAFE / path.name).write_text(output)
    print(f'Sanitized evidence: {SAFE}', flush=True)
