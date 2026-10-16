"""Adversarial SQL/HTTP parity with the real constrained reader and consumer adapter."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from admin_acceptance import owned_process
from isolated_clickhouse import isolated_clickhouse, apply_migrations, free_port
from isolated_postgres import isolated_postgres
from test_support import binary, execute

REPO = Path(__file__).resolve().parent.parent


def verify_reader(server, admin, env, root, growthbook=None, tokens=None):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    sequence = 0
    def operator(sql):
        nonlocal sequence
        sequence += 1
        result = execute(['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'], '--multiquery'], env=env, input=sql, timeout=90)
        (root / f'operator-{sequence}.private').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, f'owned SQL operator command {sequence} failed'
        return result.stdout.strip()
    def cli(*args, settings=None):
        result = execute([admin, *args], env=settings or env, timeout=120)
        (root / 'admin.private').write_text(result.stdout + result.stderr)
        result.check_returncode()
        return result.stdout.strip()
    account, foreign, source = ['reader-' + uuid.uuid4().hex for _ in range(3)]
    reader, password = 'reader_' + uuid.uuid4().hex, uuid.uuid4().hex
    operator((REPO / 'db/clickhouse/reader-role.sql').read_text())
    operator(f"CREATE USER {reader} IDENTIFIED WITH sha256_password BY '{password}' DEFAULT ROLE kansoku_reader")
    for kind in ('write', 'service'):
        token = cli('issue-key', '--kind', kind, '--account', account).splitlines()[-2]
        if tokens is not None:
            tokens.append(token)
        if kind == 'service':
            service = token
    day = datetime.now(timezone.utc).date() - timedelta(days=2)
    start = datetime.combine(day, datetime.min.time(), timezone.utc) + timedelta(hours=12)
    parameters = dict(account=account, from_time=str(day) + ' 00:00:00', to_time=str(day + timedelta(days=1)) + ' 00:00:00',
        source_service=source, first_step='signup_started', second_step='signup_completed', window_seconds=86400, experiment='reader-demo')
    rows = []
    def event(event_id, name, *, user='', anon='', session='', properties=None, seconds=0, bot=False, age=0, tenant=None):
        occurred = start + timedelta(seconds=seconds, days=-age)
        row = dict(event_id=event_id, event_name=name, source='web', source_service=source,
            occurred_at=occurred.strftime('%Y-%m-%d %H:%M:%S.000'), received_at=occurred.strftime('%Y-%m-%d %H:%M:%S.000'),
            account_id=tenant or account, user_id=user, anonymous_id=anon, session_id=session,
            properties=json.dumps(properties or {}, ensure_ascii=False), context='{}', identifiers='{}',
            url='https://reader.example.test/' + name, is_bot=bot)
        rows.append(row)
        return row
    event('reader-page-a', 'page_view', anon='cookie-a', session='a', properties={'url':'https://reader.example.test/'})
    event('reader-identify-a', 'identify', user='reader-user', anon='cookie-a', session='a', seconds=1)
    event('reader-start-a', 'signup_started', anon='cookie-a', session='a', seconds=2)
    event('reader-end-a', 'signup_completed', user='reader-user', session='a', seconds=3)
    payment = event('reader-pay-a', 'payment_completed', anon='cookie-a', session='a', properties={'amount':3,'plan':'pro'}, seconds=4)
    event('reader-pay-null', 'payment_completed', user='reader-user', properties={'amount':2}, seconds=5)
    event('reader-pay-empty', 'payment_completed', user='reader-user', properties={'amount':4,'plan':''}, seconds=6)
    event('reader-pay-invalid', 'payment_completed', user='reader-user', properties={'amount':'999','plan':42}, seconds=6)
    event('reader-page-b', 'page_view', anon='cookie-b', session='b', properties={'url':'https://reader.example.test/'}, seconds=7)
    event('reader-profile-only', 'identify', user='profile-only', anon='profile-only', seconds=8)
    event('reader-bot-page', 'page_view', user='reader-bot', session='bot', properties={'url':'https://reader.example.test/'}, seconds=9, bot=True)
    event('reader-bot-start', 'signup_started', user='reader-bot', session='bot', seconds=10, bot=True)
    event('reader-bot-end', 'signup_completed', user='reader-bot', session='bot', seconds=11, bot=True)
    event('reader-bot-pay', 'payment_completed', user='reader-bot', properties={'amount':7,'plan':'free'}, seconds=12, bot=True)
    for number, variation in enumerate(('control','control','variant_b')):
        event('reader-exposure-' + str(number), 'experiment_viewed', anon='cookie-a', session='a', properties={'experiment':'reader-demo','variant':variation}, seconds=13 if number < 2 else 14)
    for cookie in ('old-d', 'old-e'):
        event('reader-old-' + cookie, 'identify', user='old-user', anon=cookie, age=40)
        event('reader-recent-' + cookie, 'page_view', anon=cookie, session=cookie, properties={'url':'https://reader.example.test/'}, seconds=15)
    event('reader-pay-a', 'payment_completed', user='foreign-user', properties={'amount':999,'plan':'foreign'}, tenant=foreign)
    operator('SYSTEM STOP MERGES analytics.events_raw')
    operator('INSERT INTO analytics.events_raw FORMAT JSONEachRow\n' + '\n'.join(json.dumps(row, ensure_ascii=False) for row in rows))

    operator('INSERT INTO analytics.events_raw FORMAT JSONEachRow\n' + json.dumps(payment))

    def reader_query(sql, params=None, expected_error=None):
        query = urllib.parse.urlencode({'wait_end_of_query':'1', **{'param_' + key:str(value) for key,value in (params or {}).items()}})
        request = urllib.request.Request(f"http://127.0.0.1:{env['CLICKHOUSE_HTTP_PORT']}/?{query}", data=sql.encode(),
            headers={'X-ClickHouse-User':reader, 'X-ClickHouse-Key':password})
        try:
            body = urllib.request.urlopen(request, timeout=40).read().decode()
        except urllib.error.HTTPError as error:
            body = error.read().decode()
            (root / 'reader-error.private').write_text(body)
            assert expected_error is not None and re.search(r'Code: (' + '|'.join(map(str, expected_error)) + r')\b', body), 'unexpected reader SQL rejection'
            return None
        assert expected_error is None, 'reader accepted a prohibited query: ' + sql
        return [json.loads(line) for line in body.splitlines() if line]
    def recipe(name):
        return (REPO / ('db/clickhouse/recipes/' + name + '.sql')).read_text().strip()
    def run_recipe(name):
        # GrowthBook assignment recipe has its own SETTINGS clause, which must
        # remain after FORMAT; using JSON output through the HTTP format parameter
        # avoids rewriting that executable query.
        sql = recipe(name)
        if '\nSETTINGS ' in sql:
            sql = sql.replace('\nSETTINGS ', '\nFORMAT JSONEachRow\nSETTINGS ')
        else:
            sql += '\nFORMAT JSONEachRow'
        return reader_query(sql, parameters)
    operator_count = int(operator(f"SELECT count() FROM analytics.events_raw WHERE account_id='{account}' AND event_id='reader-pay-a'"))
    assert operator_count == 2, 'physical duplicate fixture did not remain unmerged'
    assert reader_query("SELECT count() AS value FROM analytics.events_resolved WHERE account_id={account:String} FORMAT JSONEachRow", parameters)
    for sql in ('SELECT count() FROM analytics.events_raw', 'SELECT count() FROM analytics.identity_signals', 'INSERT INTO analytics.events_raw (event_id) VALUES (\'prohibited\')', 'CREATE TABLE analytics.prohibited (x UInt8) ENGINE=Memory'):
        reader_query(sql, expected_error=[497,164])
    for sql in ('SELECT 1 SETTINGS readonly=0', 'SELECT 1 SETTINGS max_execution_time=0', 'SELECT 1 SETTINGS max_execution_time=31', 'SELECT 1 SETTINGS max_memory_usage=0', 'SELECT 1 SETTINGS max_memory_usage=1073741824'):
        reader_query(sql, expected_error=[164,452])
    effective=reader_query("SELECT getSetting('readonly') AS ro,getSetting('max_execution_time') AS seconds,getSetting('max_memory_usage') AS bytes FORMAT JSONEachRow SETTINGS profile='default'")
    assert effective == [dict(ro=2,seconds=30,bytes=536870912)], 'profile selection bypassed reader bounds'
    reader_query('SELECT number AS value FROM numbers(1000000) FORMAT JSONEachRow', expected_error=[396,158])
    date = reader_query("SELECT toDateTime64('2026-07-01 12:00:00.123',3,'UTC') AS timestamp FORMAT JSONEachRow")
    assert date == [{'timestamp':'2026-07-01T12:00:00.123Z'}]
    print('Reader SQL: exact grants, excluded storage/writes, fixed readonly and finite query/result limits passed.', flush=True)

    port = free_port()
    settings = dict(env, KANSOKU_SERVER_PORT=str(port), KANSOKU_QUEUE_NAME='reader_' + uuid.uuid4().hex)
    base = f'http://127.0.0.1:{port}'
    def metric(name, extra=None):
        query = urllib.parse.urlencode({'from':str(day), 'to':str(day + timedelta(days=1)),
            'filter':json.dumps(dict(dimension='source_service',op='eq',value=source)), **(extra or {})})
        request = urllib.request.Request(base + '/metrics/' + name + '?' + query, headers={'Authorization':'Bearer ' + service})
        return json.load(urllib.request.urlopen(request, timeout=40))
    def parity():
        users = run_recipe('daily-users')
        actual = metric('users', dict(timeGrain='day'))
        assert [row['value'] for row in users] == [point['value'] for point in actual['points']]
        revenue = run_recipe('revenue-by-plan')
        actual = metric('revenue', dict(timeGrain='day', groupBy='prop:plan'))
        (root / 'revenue-parity.private').write_text(json.dumps(dict(sql=revenue,http=actual)))
        assert {row['plan']:row['value'] for row in revenue} == {point['group']['prop:plan']:point['value'] for point in actual['points']}
        funnel = run_recipe('two-step-funnel')
        actual = metric('funnel', dict(steps='signup_started,signup_completed', window='86400'))
        assert [row['value'] for row in funnel] == [point['value'] for point in actual['points']]
        assert sum(row['value'] for row in revenue) == 16
        assert [row['value'] for row in funnel] == [2,2]
        return users
    with (root / 'server.private').open('w') as log:
        with owned_process([server], settings, root, 'reader-http-server', stdout=log, stderr=log) as process:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert process.poll() is None, 'owned reader HTTP server exited'
                try:
                    if urllib.request.urlopen(base + '/health/ready', timeout=2).status == 200:
                        break
                except OSError:
                    pass
                time.sleep(.1)
            else:
                raise RuntimeError('owned reader server readiness timed out')
            before = parity()
            assert before[0]['value'] == 3
            assignments, facts = run_recipe('growthbook-assignments'), run_recipe('growthbook-payment-facts')
            assert len(assignments) == 3 and len(facts) == 4
            assert assignments[0] == assignments[1], 'distinct repeated exposures were collapsed'
            assert {row['variation_id'] for row in assignments} == {'0','1'}
            assert all(row['user_id'] == 'user:reader-user' for row in assignments)
            if growthbook:
                def literal(value):
                    if isinstance(value, int):
                        return str(value)
                    return "'" + str(value).replace('\\','\\\\').replace("'","\\'") + "'"
                def render(name):
                    return re.sub(r'\{([a-z_]+):[^}]+\}', lambda match:literal(parameters[match[1]]), recipe(name))
                request = dict(connection=dict(url='http://127.0.0.1',port=int(env['CLICKHOUSE_HTTP_PORT']),username=reader,password=password,database='analytics',maxExecutionTime=30),
                    assignments=render('growthbook-assignments'), facts=render('growthbook-payment-facts'), expected=dict(assignments=assignments,facts=facts))
                input_file = root / 'growthbook-input.private'
                input_file.write_text(json.dumps(request))
                runner = Path(growthbook) / 'packages/back-end/kansoku-consumer.ts'
                runner.write_text((REPO / 'scripts/growthbook-consumer.ts').read_text())
                consumer_env = dict(settings, KANSOKU_GROWTHBOOK_SOURCE=str(Path(growthbook).resolve()), KANSOKU_CONSUMER_INPUT=str(input_file),
                    DISABLE_PYTHON_MONITOR='true', GB_STATS_ENGINE_MIN_POOL_SIZE='0', TZ='America/Los_Angeles', NODE_PATH=str(Path(growthbook) / 'packages'), TS_NODE_PROJECT=str(Path(growthbook) / 'packages/back-end/tsconfig.json'))
                result = execute(['nix','shell','--inputs-from',str(REPO),'nixpkgs#nodejs_24','-c','node','--require',str(Path(growthbook) / 'packages/back-end/node_modules/ts-node/register/transpile-only.js'),str(runner)], env=consumer_env, cwd=Path(growthbook) / 'packages/back-end', timeout=90)
                (root / 'growthbook.private').write_text(result.stdout + result.stderr)
                result.check_returncode()
                report = json.loads(result.stdout.strip().splitlines()[-1])
                assert report['cases'] == 4 and report['skipped'] == 0 and report['result'] == 'passed'
                print('GrowthBook 5.1.0: actual connection, query-editor assignment/fact validation and reader denial passed (4 cases, 0 skipped).', flush=True)
            if env.get('KANSOKU_GRAFANA_HOME'):
                from grafana_consumer import verify_grafana
                def sql_literal(value):
                    return str(value) if isinstance(value,int) else "'" + str(value).replace('\\','\\\\').replace("'","\\'") + "'"
                sql = re.sub(r'\{([a-z_]+):[^}]+\}', lambda match:sql_literal(parameters[match[1]]), recipe('daily-users'))
                verify_grafana(settings,root / 'grafana',env['KANSOKU_GRAFANA_HOME'],env['KANSOKU_GRAFANA_PLUGINS'],dict(port=int(env['CLICKHOUSE_HTTP_PORT']),username=reader,password=password),sql,before)
            operator('SYSTEM START MERGES analytics.events_raw')
            receipt = root / 'retention-receipt.private'
            cli('apply-retention','--confirm','--out',str(receipt),settings=dict(env,KANSOKU_EVENTS_RETENTION_DAYS='30'))
            after = parity()
            assert after[0]['value'] == 4, 'retention did not remove expired identity evidence'
            assert int(operator(f"SELECT count() FROM analytics.events_raw WHERE account_id='{account}' AND event_id LIKE 'reader-old-%'")) == 0
            print('Reader parity: all three recipes match HTTP on duplicates, stitched/anonymous subjects, bots, nullable/empty groups and applied retention.', flush=True)
    (root / 'summary.log').write_text('Reader SQL/HTTP parity passed; exact grants, limits, canonical populations and applied retention verified.\n')


def main():
    os.umask(0o077)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(RuntimeError('reader proof interrupted')))
    root = Path(tempfile.mkdtemp(prefix='reader-smoke-', dir='.dev/acceptance')).resolve()
    print('Private reader evidence: ' + str(root), flush=True)
    growthbook = os.environ.get('KANSOKU_GROWTHBOOK_SOURCE')
    consumers = {key:os.environ[key] for key in ('KANSOKU_GRAFANA_HOME','KANSOKU_GRAFANA_PLUGINS') if key in os.environ}
    executables={name:os.environ.get('KANSOKU_READER_' + name.upper()) or binary('kansoku-server:exe:kansoku-' + name) for name in ('server','admin','migrate')}
    with isolated_postgres(root / 'postgres') as pg_env:
        subprocess.run([executables['migrate'],'up'],env=pg_env,check=True,capture_output=True)
        saved = dict(os.environ)
        os.environ.clear(); os.environ.update(pg_env)
        try:
            with isolated_clickhouse(directory=root / 'clickhouse', access_management=True) as env:
                apply_migrations(env)
                env.update(consumers)
                verify_reader(executables['server'],executables['admin'],env,root / 'reader',growthbook)
        finally:
            os.environ.clear(); os.environ.update(saved)


if __name__ == '__main__':
    main()
