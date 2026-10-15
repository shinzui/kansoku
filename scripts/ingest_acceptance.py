"""EP-29 native HTTP/queue/writer timestamp and quarantine proof.

Imported only by the owned executable acceptance harness.
"""
from datetime import datetime, timedelta, timezone
import json
import subprocess
import time
import urllib.error
import urllib.request
import uuid


def verify_ingest(base, token, env):
    prefix = 'ep29_' + uuid.uuid4().hex
    now = datetime.now(timezone.utc)

    def iso(value):
        return value.isoformat(timespec='milliseconds').replace('+00:00', 'Z')

    def event(suffix, **changes):
        return dict(eventId=prefix + suffix, eventName='ep29_custom', source='web',
                    occurredAt=iso(now), receivedAt='1900-01-01T00:00:00Z',
                    properties={}, context={}, **changes)

    def post(path, body, status=202):
        req = urllib.request.Request(base + path, data=json.dumps(body).encode(),
                                     headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(req, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == status, f'{path}: expected {status}, received {response.status}'
            return json.load(response)

    def changed(suffix, **fields):
        value = event(suffix)
        value.update(fields)
        return value

    def psql(query):
        return subprocess.check_output(['psql', '-Atc', query], env=env, text=True).strip()

    events = [changed('_equal', occurredAt=iso(now + timedelta(seconds=90)), sentAt=iso(now + timedelta(seconds=90))),
              changed('_elapsed', occurredAt=iso(now + timedelta(seconds=90)), sentAt=iso(now + timedelta(seconds=100))),
              changed('_past', occurredAt='2026-07-01T12:00:00.123Z', sentAt=iso(now)),
              changed('_clamped', occurredAt=iso(now + timedelta(seconds=90))),
              changed('_lower', occurredAt='1970-01-01T00:00:00.000Z'),
              changed('_upper', occurredAt='2099-12-31T23:59:59.999Z', sentAt='2099-12-31T23:59:59.999Z')]
    assert post('/v1/batch', events)['accepted'] == len(events)
    post('/v1/events', changed('_ancient', occurredAt='1969-12-31T23:59:59Z'), 400)
    post('/v1/events', changed('_extreme', occurredAt='9999-01-01T00:00:00Z'), 400)
    post('/v1/events', changed('_underflow', occurredAt=iso(now + timedelta(seconds=90)), sentAt='9999-01-01T00:00:00Z'), 400)
    bad = changed('_bad', eventName='page_leave', properties={'durationMs': -1}, unknownDiagnostic='original')
    post('/v1/events', bad, 400)
    ack = post('/v1/batch', [bad, bad])
    assert ack['accepted'] == 0 and len(ack['rejected']) == 2
    stored = json.loads(psql("SELECT payload::text FROM kansoku.ingest_rejections WHERE payload->>'eventId' = '" + bad['eventId'] + "' LIMIT 1"))
    assert stored == bad, 'quarantine did not preserve the exact original object'
    assert token not in psql('SELECT payload::text FROM kansoku.ingest_rejections'), 'credential leaked into quarantine'
    query = f"""SELECT event_id, toUnixTimestamp64Milli(occurred_at) AS occurred,
      toUnixTimestamp64Milli(received_at) AS received FROM analytics.events_raw FINAL
      WHERE startsWith(event_id, '{prefix}') FORMAT JSONEachRow"""
    command = ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'], '--query', query]
    deadline = time.monotonic() + 15
    while True:
        rows = [json.loads(line) for line in subprocess.check_output(command, env=env, text=True).splitlines()]
        if len(rows) == len(events):
            break
        assert time.monotonic() < deadline, 'normalized events did not reach ClickHouse'
        time.sleep(.1)
    values = {row['event_id'][len(prefix):]: (int(row['occurred']), int(row['received'])) for row in rows}
    assert values['_equal'][0] == values['_equal'][1]
    assert values['_elapsed'][0] == values['_elapsed'][1] - 10000
    assert values['_clamped'][0] == values['_clamped'][1]
    assert values['_past'][0] == 1782907200123
    assert values['_lower'][0] == 0
    # The upper bound is exercised through the native driver separately from
    # skew correction, which necessarily moves future times to server time.
    upper = 4102444799999
    boundary = ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'],
                '--query', f"SELECT toUnixTimestamp64Milli(toDateTime64('2099-12-31 23:59:59.999',3,'UTC'))"]
    assert int(subprocess.check_output(boundary, env=env)) == upper
    print('EP-29 native ingest: timestamp milliseconds, boundaries, rejections and original quarantine passed.', flush=True)
