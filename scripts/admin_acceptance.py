"""Required administrative CLI proof; main owns fresh databases for source iteration."""
from datetime import datetime, timedelta, timezone
from contextlib import contextmanager, ExitStack
import signal
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from isolated_clickhouse import isolated_clickhouse, apply_migrations, free_port
from isolated_postgres import isolated_postgres
from test_support import binary



@contextmanager
def owned_process(command, env, root, name, *, stop_timeout=10, **kwargs):
    process = subprocess.Popen(command, env=env, **kwargs)
    with (Path(root) / 'processes.jsonl').open('a') as inventory:
        inventory.write(json.dumps(dict(pid=process.pid, name=name)) + '\n')
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=stop_timeout)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def verify_admin(server, admin, env, root, tokens=None):
    root = Path(root)
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    env = dict(env, KANSOKU_QUEUE_NAME='admin_' + uuid.uuid4().hex)
    queue = env.get('KANSOKU_QUEUE_NAME', 'kansoku_events')
    sequence = 0

    def execute(command, *, expected=0, settings=None, input=None):
        nonlocal sequence
        sequence += 1
        result = subprocess.run(command, input=input, env=settings or env, capture_output=True,
                                text=True, timeout=120)
        (root / f'command-{sequence}.private').write_text(result.stdout + result.stderr)
        assert result.returncode == expected, f'administrative command {sequence} failed; private evidence retained'
        return result.stdout.strip()

    def cli(*args, expected=0, settings=None):
        return execute([admin, *args], expected=expected, settings=settings)

    def pg(sql):
        return execute(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1'], input=sql)

    def ch(sql):
        return execute(['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'],
                        '--multiquery'], input=sql)

    def literal(value):
        return "'" + value.replace("'", "''") + "'"

    def eventually(check, label, seconds=30):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if check():
                return
            time.sleep(.2)
        raise AssertionError('administrative eventual check failed: ' + label)

    def issue(kind, account):
        lines = cli('issue-key', '--kind', kind, '--account', account, '--description', 'owned admin acceptance').splitlines()
        token = lines[-2]
        if tokens is not None:
            tokens.append(token)
        return token

    account, other, user = 'admin-a', 'admin-b', "利用者'quoted"
    write, service, other_write = issue('write', account), issue('service', account), issue('write', other)
    listed = json.loads(cli('list-keys', '--account', account))
    assert len(listed) == 2 and all('token_hash' not in row for row in listed)
    assert not any(token in json.dumps(listed) for token in (write, service, other_write))
    revoke = issue('write', 'admin-revoke')
    revoke_id = json.loads(cli('list-keys', '--account', 'admin-revoke'))[0]['id']
    assert json.loads(cli('revoke-key', '--id', revoke_id))['preview']
    assert json.loads(cli('list-keys', '--account', 'admin-revoke'))[0]['revoked_at'] is None

    pg('SELECT pgmq.create(' + literal(queue) + ');')
    qtable = 'pgmq.' + '"q_' + queue.lower().replace('"', '""') + '"'
    atable = 'pgmq.' + '"a_' + queue.lower().replace('"', '""') + '"'

    def event(key, name='page_view', *, subject=user, account_id=account,
              cookie='admin-cookie', session='admin-session', stamp='2026-07-01T12:00:00Z', props=None, version=1):
        result = dict(eventId='admin-' + key, eventName=name, schemaVersion=version, source='web',
                      sourceService='admin-web', occurredAt=stamp, receivedAt=stamp, accountId=account_id,
                      anonymousId=cookie, sessionId=session, properties=props or {}, context={})
        if subject is not None:
            result['userId'] = subject
        if name == 'page_view':
            result['url'] = 'https://admin.test/' + key
            result['properties'].update(url=result['url'], path='/' + key)
        return result

    def archive(row):
        return pg('SELECT pgmq.archive(' + literal(queue) + ',pgmq.send(' + literal(queue) + ','
                  + literal(json.dumps(row, ensure_ascii=False)) + '::jsonb,0));')

    originals = [event(str(i), ['page_view', 'payment_completed', 'signup_completed'][i % 3],
                       props={'amount': 2} if i % 3 == 1 else {}) for i in range(12)]
    originals.append(event('other-account', account_id=other, subject='other-user', cookie='other-cookie', session='other-session'))
    for row in originals:
        archive(row)
    assert json.loads(cli('replay-archive', '--limit', '100'))['matching'] == 13
    assert pg('SELECT count(*) FROM ' + qtable + ';') == '0'
    pg("CREATE FUNCTION kansoku.admin_test_replay_failure() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'owned replay rollback'; END $$; CREATE TRIGGER admin_test_replay_failure BEFORE INSERT ON kansoku.archive_replays FOR EACH ROW EXECUTE FUNCTION kansoku.admin_test_replay_failure();")
    cli('replay-archive', '--limit', '100', '--confirm', expected=1)
    assert pg('SELECT count(*) FROM ' + qtable + ';') == '0'
    assert pg('SELECT count(*) FROM kansoku.archive_replays;') == '0'
    pg('DROP TRIGGER admin_test_replay_failure ON kansoku.archive_replays; DROP FUNCTION kansoku.admin_test_replay_failure();')
    with ExitStack() as children:
        processes = [children.enter_context(owned_process([admin, 'replay-archive', '--limit', '7', '--confirm'], env, root, f'replay-{index}',
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)) for index in range(2)]
        results = [process.communicate(timeout=30) for process in processes]
        assert all(process.returncode == 0 for process in processes)
        assert sum(json.loads(stdout)['replayed'] for stdout, _ in results) == 13
        assert pg('SELECT count(*) FROM kansoku.archive_replays;') == '13'
        assert pg('SELECT count(*) FROM ' + qtable + ';') == '13'
    archive(originals[0])
    occupied = root / 'occupied.json'
    occupied.write_text('existing operator file')
    cli('replay-archive', '--confirm', '--out', str(occupied), expected=1)
    assert occupied.read_text() == 'existing operator file'
    assert pg('SELECT count(*) FROM kansoku.archive_replays;') == '14'
    receipt = root / 'replay.json'
    assert json.loads(cli('replay-archive', '--confirm', '--out', str(receipt)))['replayed'] == 0
    assert stat.S_IMODE(receipt.stat().st_mode) == 0o600
    print('Admin credentials and replay: redacted metadata, preview, rollback, concurrent claims and committed-before-output recovery passed.', flush=True)

    port = free_port()
    base = f'http://127.0.0.1:{port}'
    settings = dict(env, KANSOKU_SERVER_PORT=str(port), KANSOKU_WRITER_MAX_LATENCY_MS='100',
                    KANSOKU_QUEUE_POLL_INTERVAL_SEC='1', KANSOKU_INGEST_QUARANTINE='true',
                    KANSOKU_CORS_ORIGINS='https://admin.test',
                    OTEL_TRACES_EXPORTER='none', OTEL_METRICS_EXPORTER='none')

    def request(path, token=None, body=None, expected=200):
        headers = {'Content-Type': 'application/json', 'Origin': 'https://admin.test'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                status, answer, response_headers = response.status, json.load(response), response.headers
        except urllib.error.HTTPError as error:
            status, answer, response_headers = error.code, json.load(error), error.headers
        assert status == expected, 'unexpected administrative HTTP status'
        if path in ('/v1/events', '/v1/batch'):
            assert response_headers.get('Access-Control-Allow-Origin') == 'https://admin.test', 'administrative response lost ingest CORS'
        return answer

    def metric(name, **params):
        query = dict(from_='2026-07-01', to='2026-07-02')
        query = {'from' if key == 'from_' else key: value for key, value in query.items()}
        query.update(params)
        return request('/metrics/' + name + '?' + urllib.parse.urlencode(query), service)['points']

    def total(name, **params):
        return sum(point['value'] for point in metric(name, **params))

    with (root / 'server.private').open('w') as output:
        with owned_process([server], settings, root, 'server', stop_timeout=40, stdout=output, stderr=output) as process:
            def ready():
                try:
                    return request('/health/ready')['status'] == 'ok'
                except (OSError, AssertionError):
                    return False
            eventually(ready, 'server readiness')
            eventually(lambda: total('page-views') == 4 and total('revenue') == 8, 'initial archive facts')
            baseline = (total('events'), total('page-views'), total('revenue'), total('sessions'))
            for row in originals:
                archive(row)
            assert json.loads(cli('replay-archive', '--confirm'))['replayed'] == 13
            eventually(lambda: pg('SELECT count(*) FROM ' + qtable + ';') == '0', 'duplicate replay drain')
            assert baseline == (total('events'), total('page-views'), total('revenue'), total('sessions'))
            cli('revoke-key', '--id', revoke_id, '--confirm')
            cli('revoke-key', '--id', revoke_id, '--confirm')
            request('/v1/events', revoke, originals[0], expected=401)
            print('Admin replay/revocation: real writer drain preserves events, revenue, page views and whole sessions; revocation is immediate and idempotent.', flush=True)
            # Lifecycle and retention scenarios follow the same running packaged boundary.
            _verify_lifecycle(admin, cli, pg, ch, request, metric, total, event, archive, eventually,
                              env, root, qtable, atable, account, other, user, write, service, other_write, originals)
    print('Required administrative acceptance: 7 non-skipped scenario families passed.', flush=True)
    return 7


def _verify_lifecycle(admin, cli, pg, ch, request, metric, total, event, archive, eventually,
                      env, root, qtable, atable, account, other, user, write, service, other_write, originals):
    def literal(value):
        return "'" + value.replace("'", "''") + "'"

    def post(row, key=write):
        return request('/v1/batch', key, [row], expected=202)

    account_sql, user_sql = literal(account), literal(user)
    anonymous = event('pre-login', subject=None, stamp='2026-07-01T11:00:00Z')
    profile = event('profile', 'identify', stamp='2026-07-01T13:00:00Z', version=2,
                    props={'plan': 'admin-governed', 'company_size': 10})
    post(anonymous)
    post(profile)
    selection = json.dumps(dict(dimension='user:plan', op='eq', value='admin-governed'))
    eventually(lambda: total('page-views', filter=selection) == 5, 'governed stitched population')
    invalid = event('invalid-profile', 'identify', version=2,
                    props={'company_size': -1, 'role': 'private-admin-marker'})
    assert post(invalid)['accepted'] == 0
    eventually(lambda: len(json.loads(cli('list-rejections', '--account', account))) == 1, 'quarantine capture')
    metadata = json.loads(cli('list-rejections', '--account', account))
    assert 'payload' not in metadata[0] and 'private-admin-marker' not in json.dumps(metadata)
    assert 'private-admin-marker' in cli('list-rejections', '--account', account, '--include-payload')
    cli('list-rejections', '--limit', '0', expected=1)
    # A future cutoff demonstrates manual purge preview without touching Alice's diagnostic.
    post(event('other-invalid', 'identify', subject='other-user', account_id=other, version=2,
               props={'company_size': -1}), other_write)
    eventually(lambda: len(json.loads(cli('list-rejections', '--account', other))) == 1, 'other quarantine')
    future = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    assert json.loads(cli('purge-rejections', '--account', other, '--before', future))['preview']
    assert len(json.loads(cli('list-rejections', '--account', other))) == 1
    assert json.loads(cli('purge-rejections', '--account', other, '--before', future, '--confirm'))['purged'] == 1
    rejected_reuse = event('reused-rejection', 'identify', version=2, props={'company_size': -1})
    assert post(rejected_reuse)['accepted'] == 0
    valid_reuse = event('reused-rejection', subject='another-user', cookie='another-cookie', session='another-session')
    assert post(valid_reuse)['accepted'] == 1
    eventually(lambda: ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-reused-rejection' AND user_id='another-user'") == '1', 'valid use of previously rejected ID')
    print('Admin quarantine: bounded redacted inspection, explicit payload access and confirmed account-scoped purge passed.', flush=True)

    # Leave unreplayed archive copies for the erasure command to scrub.
    for row in originals[:-1]:
        archive(row)
    before = total('events'), total('revenue')
    preview_path = root / 'preview-must-not-exist.json'
    assert json.loads(cli('erase-user', '--account', account, '--user', user, '--out', str(preview_path)))['preview']
    assert not preview_path.exists()
    assert pg('SELECT count(*) FROM kansoku.maintenance_jobs;') == '0'
    assert pg('SELECT count(*) FROM kansoku.event_dispositions;') == '0'
    other_before = ch("SELECT toJSONString(tuple(count(),sum(cityHash64(tuple(event_id,event_name,anonymous_id,user_id,session_id,identifiers,properties))))) FROM analytics.events_canonical WHERE account_id=" + literal(other))
    # Persist the fence, then fail exclusive output creation before mutations.
    occupied = root / 'occupied.json'
    with ExitStack() as children:
        blocker = children.enter_context(owned_process(['psql', '-XAt', '-v', 'ON_ERROR_STOP=1'],
                                   dict(env, PGAPPNAME='admin-admitted-read'), root, 'admitted-read', stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        blocker.stdin.write('BEGIN; SELECT pg_advisory_xact_lock_shared(726401,1);\n')
        blocker.stdin.flush()
        eventually(lambda: pg("SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING(pid) WHERE a.application_name='admin-admitted-read' AND l.locktype='advisory' AND l.classid=726401 AND l.objid=1 AND l.granted;") == '1', 'admitted read lock')
        erase = children.enter_context(owned_process([admin, 'erase-user', '--account', account, '--user', user,
                                  '--out', str(occupied), '--confirm'], env, root, 'erase-waiting',
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        eventually(lambda: pg('SELECT count(*) FROM kansoku.maintenance_fence WHERE active_job IS NOT NULL;') == '1', 'persisted fence before exclusive lock')
        assert json.loads(cli('list-jobs', '--limit', '1'))[0]['stage'] == 'created'
        request('/metrics/events?from=2026-07-01&to=2026-07-02', service, expected=503)
        assert ch('SELECT count() FROM analytics.user_traits WHERE account_id=' + account_sql + ' AND user_id=' + user_sql) != '0'
        blocker.stdin.write('COMMIT;\n')
        blocker.stdin.close()
        blocker.wait(timeout=10)
        erase_stdout, erase_stderr = erase.communicate(timeout=30)
        (root / 'admitted-read-erase.private').write_text(erase_stdout + erase_stderr)
        assert blocker.returncode == 0 and erase.returncode == 1
    job = json.loads(cli('list-jobs', '--limit', '1'))[0]
    assert job['stage'] == 'discovered'
    status = json.loads(cli('job-status', '--id', job['id']))
    assert status['fenced'] is True
    request('/metrics/events?from=2026-07-01&to=2026-07-02', service, expected=503)
    request('/v1/events', write, event('fenced-ingest'), expected=503)
    request('/v1/schemas')
    # The adapter may retain this exact pre-scrub envelope while fenced. Its next
    # insert must re-read dispositions, rather than reuse stale identity fields.
    held = event('held-batch', 'identify', version=2, props={'plan': 'must-not-return'})
    pg('SELECT pgmq.send(' + literal(env.get('KANSOKU_QUEUE_NAME', 'kansoku_events')) + ',' + literal(json.dumps(held, ensure_ascii=False)) + '::jsonb,0);')
    eventually(lambda: pg("SELECT count(*) FROM " + qtable + " WHERE message->>'eventId'='admin-held-batch' AND read_ct>0;") == '1', 'fenced retained writer batch')
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-held-batch'") == '0'
    definition = ch('SHOW CREATE TABLE analytics.mv_page_views_by_route FORMAT TSVRaw')
    ch('DROP TABLE analytics.mv_page_views_by_route')
    first_snapshot = root / 'erase-failed.json'
    cli('resume-job', '--id', job['id'], '--out', str(first_snapshot), '--confirm', expected=1)
    assert json.loads(cli('job-status', '--id', job['id']))['stage'] == 'raw-mutated'
    assert stat.S_IMODE(first_snapshot.stat().st_mode) == 0o600
    assert user not in first_snapshot.read_text() and 'admin-cookie' not in first_snapshot.read_text()
    request('/metrics/events?from=2026-07-01&to=2026-07-02', service, expected=503)
    ch(definition)
    completed = json.loads(cli('resume-job', '--id', job['id'], '--out', str(root / 'erase-complete.json'), '--confirm'))
    assert completed['stage'] == 'complete'
    assert json.loads(cli('resume-job', '--id', job['id'], '--confirm'))['stage'] == 'complete'
    eventually(lambda: pg('SELECT count(*) FROM ' + qtable + ';') == '0', 'rewritten retained batch drain')
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-held-batch' AND anonymous_id='' AND session_id='' AND identifiers='{}' AND properties='{}'") == '1'
    assert ch('SELECT count() FROM analytics.user_traits WHERE account_id=' + account_sql + ' AND user_id=' + user_sql) == '0'
    assert ch('SELECT count() FROM analytics.identity_signals FINAL WHERE account_id=' + account_sql + ' AND user_id=' + user_sql) == '0'
    assert total('revenue') == before[1]
    assert json.loads(cli('list-rejections', '--account', account)) == []
    assert pg("SELECT count(*) FROM kansoku.event_dispositions WHERE event_id='admin-reused-rejection';") == '0'
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-reused-rejection' AND user_id='another-user'") == '1'
    assert json.loads(cli('replay-archive', '--confirm'))['replayed'] == 12
    eventually(lambda: pg('SELECT count(*) FROM ' + qtable + ';') == '0', 'sanitized archive drain')
    assert ch('SELECT count() FROM analytics.user_traits WHERE account_id=' + account_sql + ' AND user_id=' + user_sql) == '0'
    assert total('revenue') == before[1]
    # Legacy source identities with no accepted-events row are still reserved.
    reserved = post(originals[0])
    assert reserved['accepted'] == 0 and len(reserved['rejected']) == 1
    assert other_before == ch("SELECT toJSONString(tuple(count(),sum(cityHash64(tuple(event_id,event_name,anonymous_id,user_id,session_id,identifiers,properties))))) FROM analytics.events_canonical WHERE account_id=" + literal(other))
    print('Admin unlinking: persisted fence, refused traffic, retained writer payload, failed rebuild/resume, redacted 0600 receipt, archive replay and legacy-ID reservation passed.', flush=True)

    deleted_user = 'explicit-delete'
    deletion_rows = [event('delete-profile', 'identify', subject=deleted_user, cookie='delete-cookie', session='delete-session', version=2, props={'plan': 'delete-plan'}),
                     event('delete-page', subject=deleted_user, cookie='delete-cookie', session='delete-session')]
    for row in deletion_rows:
        post(row)
    eventually(lambda: ch("SELECT count() FROM analytics.events_canonical WHERE account_id=" + account_sql + " AND user_id='explicit-delete'") == '2', 'explicit deletion facts')
    for row in deletion_rows:
        archive(row)
    ledger_before = int(pg('SELECT count(*) FROM kansoku.accepted_events;'))
    assert json.loads(cli('erase-user', '--account', account, '--user', deleted_user, '--delete-events', '--out', str(root / 'delete.json'), '--confirm'))['stage'] == 'complete'
    assert post(deletion_rows[0])['accepted'] == 1  # Logical retry, never re-publication.
    assert json.loads(cli('replay-archive', '--confirm'))['replayed'] == 0
    assert ch("SELECT count() FROM analytics.events_canonical WHERE account_id=" + account_sql + " AND user_id='explicit-delete'") == '0'
    assert int(pg('SELECT count(*) FROM kansoku.accepted_events;')) == ledger_before
    assert other_before == ch("SELECT toJSONString(tuple(count(),sum(cityHash64(tuple(event_id,event_name,anonymous_id,user_id,session_id,identifiers,properties))))) FROM analytics.events_canonical WHERE account_id=" + literal(other))
    print('Admin explicit deletion: account isolation, both trait states, archive inputs and permanent logical retries passed.', flush=True)

    old_day = (datetime.now(timezone.utc).date() - timedelta(days=181)).isoformat()
    fingerprint = event('old-fingerprint', subject='fingerprint-user', cookie='fp-cookie', session='fp-session', stamp=old_day + 'T12:00:00Z')
    fingerprint['identifiers'] = {'fingerprint': 'expired-fingerprint', 'device': 'retained-device'}
    assert post(fingerprint)['accepted'] == 1
    eventually(lambda: ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-old-fingerprint'") == '1', 'old fingerprint source')
    archive(fingerprint)
    bad_fingerprint = event('old-fingerprint-rejection', 'identify', subject='fingerprint-user', stamp=old_day + 'T12:00:00Z', version=2, props={'company_size': -1})
    bad_fingerprint['identifiers'] = fingerprint['identifiers']
    # Unknown producer fields must not impersonate the private queue wrapper.
    bad_fingerprint['event'] = {'userId': 'decoy', 'occurredAt': '2099-01-01T00:00:00Z'}
    bad_fingerprint['queueVersion'] = 2
    assert post(bad_fingerprint)['accepted'] == 0
    assert json.loads(cli('apply-retention', '--out', str(root / 'fingerprint-policy.json'), '--confirm', settings=dict(env, KANSOKU_EVENTS_RETENTION_DAYS='0')))['stage'] == 'complete'
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-old-fingerprint' AND NOT JSONHas(identifiers,'fingerprint') AND JSONExtractString(identifiers,'device')='retained-device'") == '1'
    assert ch("SELECT count() FROM analytics.events_raw WHERE event_id='admin-old-fingerprint' AND position(identity_context_key,'expired-fingerprint')>0") == '0'
    assert pg("SELECT count(*) FROM " + atable + " WHERE message->>'eventId'='admin-old-fingerprint' AND NOT ((message->'identifiers') ? 'fingerprint') AND message#>>'{identifiers,device}'='retained-device';") == '1'
    assert pg("SELECT count(*) FROM kansoku.ingest_rejections WHERE payload->>'eventId'='admin-old-fingerprint-rejection' AND NOT ((payload->'identifiers') ? 'fingerprint') AND payload#>>'{identifiers,device}'='retained-device';") == '1'
    fingerprint_late = {**fingerprint, 'eventId': 'admin-old-fingerprint-late'}
    assert post(fingerprint_late)['accepted'] == 1
    eventually(lambda: ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-old-fingerprint-late' AND NOT JSONHas(identifiers,'fingerprint') AND JSONExtractString(identifiers,'device')='retained-device'") == '1', 'persisted fingerprint writer policy')
    print('Admin fingerprint policy: unlimited event retention still scrubs expired raw/context keys, archive/quarantine envelopes and later old writer inputs while preserving device evidence.', flush=True)

    yesterday = datetime.now(timezone.utc).date() - timedelta(days=1)
    day, end = yesterday.isoformat(), (yesterday + timedelta(days=1)).isoformat()
    old = event('retention-old', subject='retention-user', cookie='retention-cookie', session='retention-session')
    fresh = event('retention-fresh', subject='retention-user', cookie='retention-cookie', session='retention-session', stamp=day + 'T12:00:00Z')
    trait = event('retention-trait', 'identify', subject='retention-user', cookie='retention-cookie', session='retention-session', stamp=day + 'T12:00:01Z', version=2, props={'plan': 'retained-plan'})
    for row in (old, fresh, trait):
        post(row)
    eventually(lambda: total('page-views', **{'from': day, 'to': end}) == 1, 'fresh retention fact')
    ch("CREATE TABLE analytics.admin_retention_replay ENGINE=Memory AS SELECT * FROM analytics.events_raw WHERE event_id='admin-retention-old'")
    archive(old)
    configured = dict(env, KANSOKU_EVENTS_RETENTION_DAYS='30')
    preview = json.loads(cli('apply-retention', settings=configured))
    assert preview['preview'] and preview['days'] == 30
    assert pg('SELECT days FROM kansoku.retention_policy;') == '0'
    accepted_before_retention = int(pg('SELECT count(*) FROM kansoku.accepted_events;'))
    assert json.loads(cli('apply-retention', '--out', str(root / 'retention.json'), '--confirm', settings=configured))['stage'] == 'complete'
    assert int(pg('SELECT count(*) FROM kansoku.accepted_events;')) == accepted_before_retention
    assert ch("SELECT count() FROM analytics.events_raw WHERE occurred_at<now()-INTERVAL 30 DAY") == '0'
    assert ch('SELECT uniqExactMerge(views) FROM analytics.page_views_by_route WHERE account_id=' + account_sql) == '1'
    assert total('page-views', **{'from': day, 'to': end}) == 1
    assert total('page-views', **{'from': day, 'to': end, 'groupBy': 'route'}) == 1
    retained_filter = json.dumps(dict(dimension='user:plan', op='eq', value='retained-plan'))
    assert total('page-views', **{'from': day, 'to': end, 'filter': retained_filter}) == 1
    assert total('sessions', **{'from': day, 'to': end}) == 1
    assert pg('SELECT count(*) FROM ' + atable + ';') == '0'
    # Native old-block replay is also fenced out of every derived aggregate.
    ch('INSERT INTO analytics.events_raw SELECT * FROM analytics.admin_retention_replay')
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-retention-old'") == '0'
    assert ch('SELECT uniqExactMerge(views) FROM analytics.page_views_by_route WHERE account_id=' + account_sql) == '1'
    assert total('page-views', **{'from': day, 'to': end, 'filter': retained_filter}) == 1
    # A newly enqueued expired envelope is discarded under the persisted policy.
    pg('SELECT pgmq.send(' + literal(env.get('KANSOKU_QUEUE_NAME', 'kansoku_events')) + ',' + literal(json.dumps(old)) + '::jsonb,0);')
    eventually(lambda: pg('SELECT count(*) FROM ' + qtable + ';') == '0', 'expired writer payload')
    assert ch("SELECT count() FROM analytics.events_canonical WHERE event_id='admin-retention-old'") == '0'
    archive(old)
    assert json.loads(cli('replay-archive', '--confirm'))['replayed'] == 0
    assert json.loads(cli('purge-archive', '--before', future))['preview']
    assert pg('SELECT count(*) FROM ' + atable + ';') == '1'
    assert json.loads(cli('purge-archive', '--before', future, '--limit', '1', '--confirm'))['purged'] == 1
    assert json.loads(cli('apply-retention', '--out', str(root / 'retention-reapply.json'), '--confirm', settings=configured))['stage'] == 'complete'
    ch('DROP TABLE analytics.admin_retention_replay')
    assert json.loads(cli('apply-retention', '--out', str(root / 'unlimited.json'), '--confirm', settings=dict(env, KANSOKU_EVENTS_RETENTION_DAYS='0')))['stage'] == 'complete'
    assert total('page-views', **{'from': day, 'to': end}) == 1
    assert ch("SELECT count() FROM analytics.events_raw WHERE event_id='admin-retention-old'") == '0'
    print('Admin retention: preview, canonical/rollup/filtered agreement, retained crossing sessions, expired replay inputs, indefinite ledger and unlimited-policy irreversibility passed.', flush=True)


def main():
    os.umask(0o077)
    def interrupted(signum, frame):
        raise RuntimeError("owned administrative acceptance interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    root = Path(tempfile.mkdtemp(prefix='admin-smoke-', dir='.dev/acceptance')).resolve()
    print('Private administrative evidence: ' + str(root), flush=True)
    with isolated_postgres(root / 'postgres') as pg_env:
        subprocess.run([binary('kansoku-server:exe:kansoku-migrate'), 'up'], env=pg_env, check=True, capture_output=True, text=True)
        saved = dict(os.environ)
        os.environ.clear()
        os.environ.update(pg_env)
        try:
            with isolated_clickhouse(directory=root / 'clickhouse') as env:
                apply_migrations(env)
                env['KANSOKU_QUEUE_NAME'] = 'admin_events'
                verify_admin(binary('kansoku-server:exe:kansoku-server'), binary('kansoku-server:exe:kansoku-admin'), env, root / 'commands')
        finally:
            os.environ.clear()
            os.environ.update(saved)
    print('Required administrative acceptance passed.', flush=True)


if __name__ == '__main__':
    main()
