#!/usr/bin/env python3
"""Reject incompatible JSON before acceptance on fresh, owned stores (EP-46)."""
import json
import os
from pathlib import Path
import subprocess
import urllib.error
import urllib.request
import uuid

from enrichment_acceptance import eventually

CORPUS = Path(__file__).resolve().parent.parent / 'kansoku-core/test/fixtures/json-storage-shapes.json'


def verify_json_storage(base, token, other_token, env):
    prefix = 'json_' + uuid.uuid4().hex
    expected = {}

    def event(suffix, **fields):
        return dict(eventId=prefix + suffix, eventName='json_storage', source='web',
                    occurredAt='2026-07-01T12:00:00Z', receivedAt='1900-01-01T00:00:00Z',
                    properties=fields.get('properties', {}), context=fields.get('context', {}))

    def post(path, body, credential=token, status=202):
        headers = {'Content-Type': 'application/json'}
        if path == '/v1/beacon':
            body = dict(writeKey=credential, batch=body)
            headers['Content-Type'] = 'text/plain;charset=UTF-8'
        else:
            headers['Authorization'] = 'Bearer ' + credential
        request = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            assert response.status == status, (path, response.status)
            return json.load(response)

    def psql(sql):
        return subprocess.check_output(['psql', '-Atc', sql], env=env, text=True, timeout=10).strip()

    def native(sql):
        return subprocess.check_output(['clickhouse-client', '--host', '127.0.0.1', '--port',
                                       env['CLICKHOUSE_TCP_PORT'], '--query', sql], env=env, text=True, timeout=10).strip()

    def count(identifier):
        return int(native("SELECT count() FROM analytics.events_canonical WHERE event_id='" + identifier + "'"))

    def remember(value):
        expected[value['eventId']] = value

    rejected = 0
    for case in json.loads(CORPUS.read_text()):
        for field in ('properties', 'context'):
            suffix = '_' + case['name'] + '_' + field
            if case['compatible']:
                value = event(suffix, **{field: case['value']})
                ack = post('/v1/batch', [value])
                assert ack == dict(accepted=1, rejected=[]), ack
                remember(value)
                continue
            for transport in ('events', 'batch', 'beacon'):
                bad = event(suffix + '_' + transport, **{field: case['value']})
                good = event(suffix + '_' + transport + '_sibling')
                body = bad if transport == 'events' else [bad, good]
                ack = post('/v1/' + transport, body, status=400 if transport == 'events' else 202)
                if transport == 'events':
                    assert ack['code'] == 'validation_failed', ack
                else:
                    assert ack['accepted'] == 1 and len(ack['rejected']) == 1, ack
                    rejection = ack['rejected'][0]
                    assert rejection['index'] == 0 and rejection['eventId'] == bad['eventId'], ack
                    assert field + ' contains incompatible JSON paths' in rejection['errors'][0], ack
                    remember(good)
                identifier = bad['eventId']
                assert psql("SELECT count(*) FROM kansoku.accepted_events WHERE event_id='" + identifier + "'") == '0'
                # Inspect the current private envelope; no rejected message may be
                # published, including messages the writer could otherwise lease.
                queue = env['KANSOKU_QUEUE_NAME']
                assert queue.replace('_', '').isalnum()
                assert psql(f"SELECT count(*) FROM pgmq.q_{queue} WHERE message->'event'->>'eventId'='{identifier}' OR message->>'eventId'='{identifier}'") == '0'
                assert count(identifier) == 0
                # A separate authenticated account must still reach storage after
                # every bad submission. This bounds any shared-writer parking.
                later = event(suffix + '_' + transport + '_other')
                assert post('/v1/batch', [later], other_token) == dict(accepted=1, rejected=[])
                eventually(lambda: count(later['eventId']) == 1)
                remember(later)
                # Rejection created no immutable identity: corrected content under
                # exactly the same ID can be accepted, then retried without copying.
                corrected = event(suffix + '_' + transport)
                assert post('/v1/batch', [corrected]) == dict(accepted=1, rejected=[])
                assert post('/v1/batch', [corrected]) == dict(accepted=1, rejected=[])
                remember(corrected)
                rejected += 1

    eventually(lambda: int(native(f"SELECT count() FROM analytics.events_canonical WHERE startsWith(event_id,'{prefix}')")) == len(expected))
    rows = [json.loads(line) for line in native(f"SELECT event_id,account_id,properties,context,JSONAllPaths(properties_json) AS prop_paths,JSONAllPaths(context_json) AS ctx_paths FROM analytics.events_canonical WHERE startsWith(event_id,'{prefix}') FORMAT JSONEachRow").splitlines()]
    accounts = set()

    def paths(value, prefix=''):
        result = []
        for key, item in value.items():
            path = prefix + key
            if isinstance(item, dict):
                result += paths(item, path + '.')
            elif item is not None:
                result.append(path)
        return sorted(result)

    for row in rows:
        original = expected[row['event_id']]
        accounts.add(row['account_id'])
        for field, path_key in [('properties', 'prop_paths'), ('context', 'ctx_paths')]:
            assert json.loads(row[field]) == original[field], (field, row['event_id'])
            assert sorted(row[path_key]) == paths(original[field]), (row, original)
    assert len(accounts) == 2, accounts
    # Check the actual native dotted subcolumn value, not just retained raw JSON.
    for field in ('properties', 'context'):
        identifier = prefix + '_dotted_' + field
        assert native(f"SELECT toJSONString(getSubcolumn({field}_json,'a.b')) FROM analytics.events_canonical WHERE event_id='{identifier}'") == '1'
    assert int(psql(f"SELECT count(*) FROM kansoku.accepted_events WHERE starts_with(event_id,'{prefix}')")) == len(expected)
    assert int(native(f"SELECT count() FROM analytics.events_raw WHERE startsWith(event_id,'{prefix}')")) == len(expected), 'retry inserted physical duplicates'
    print(f'JSON storage: {rejected} permanent transport rejections; {len(expected)} canonical events; native paths/values, corrected IDs, retries and two-account progress passed.', flush=True)


def main():
    from cohorts_acceptance import main as owned_stack
    from test_support import binary, hspec

    def verify(base, write, service, other_service, *, env, **_):
        # The required Hspec wrapper rejects missing native prerequisites/pending
        # examples. The packaged harness runs this same module in its full suite.
        hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Writer.Batch/native JSON shapes'], env=env)
        server = os.environ.get('KANSOKU_COHORT_SERVER') or binary('kansoku-server:exe:kansoku-server')
        output = subprocess.check_output([server, 'issue-key', '--kind', 'write', '--account', 'json_other',
                                          '--description', 'JSON storage acceptance'], env=env, text=True, timeout=15)
        verify_json_storage(base, write, output.splitlines()[-2], env)

    os.umask(0o077)
    owned_stack(verify, pass_environment=True)


if __name__ == '__main__':
    main()
