#!/usr/bin/env python3
"""Compose saved-resource scenarios repeatedly, including their failure paths."""
import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

from acceptance_resources import OwnedResources
from cohorts_acceptance import verify_cohorts, main as owned_stack
from custom_metrics_acceptance import verify_custom_metrics


def verify_fixture_isolation(base, write_key, token, other_token, *, env, **_):
    def api(path, body=None, method='GET', credential=token, expected=200, **params):
        request = urllib.request.Request(base + path + ('?' + urllib.parse.urlencode(params) if params else ''),
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            value = json.load(response)
            assert response.status in (expected if isinstance(expected, tuple) else (expected,)), (path, response.status)
            return value

    def ids(path, credential):
        result = []
        cursor = None
        while True:
            page = api(path, credential=credential, first=100, **({'after': cursor} if cursor else {}))
            result += [edge['node']['id'] for edge in page['edges']]
            if not page['pageInfo']['hasNextPage']:
                return sorted(result)
            cursor = page['pageInfo']['endCursor']

    def baseline():
        return [ids(path, credential) for credential in (token, other_token) for path in ('/cohorts', '/metric-definitions')]

    before = baseline()
    assert before == [[], [], [], []], 'strict fixture scenarios need otherwise empty saved-resource accounts'
    for _ in range(2):
        for verify in (verify_custom_metrics, verify_cohorts):
            verify(base, write_key, token, other_token)
            assert baseline() == before, 'scenario leaked saved resources'

    class InjectedFailure(Exception):
        pass

    for verify in (verify_custom_metrics, verify_cohorts):
        uploaded = []
        failure = InjectedFailure('injected after registered membership upload')

        def fail_after_upload(path):
            uploaded.append(path.split('/')[2])
            raise failure

        try:
            verify(base, write_key, token, other_token, after_membership=fail_after_upload)
        except InjectedFailure as error:
            assert error is failure, 'cleanup replaced the primary scenario failure'
        else:
            raise AssertionError('failure injection did not execute')
        assert uploaded and baseline() == before, 'failure cleanup leaked resources'
        # Definition absence alone hides historical members. Prove the last
        # explicit replacement cleared every active membership before deletion.
        for ident in uploaded:
            uuid.UUID(ident)
            sql = f"SELECT count() FROM (SELECT user_id,argMax(present,version) AS active FROM analytics.cohort_members WHERE cohort_id='{ident}' GROUP BY user_id HAVING active=1)"
            assert subprocess.check_output(['clickhouse-client', '--host', '127.0.0.1', '--port',
                env['CLICKHOUSE_TCP_PORT'], '--query', sql], env=env, text=True, timeout=10).strip() == '0'

    # A separately created sentinel must survive helper finalization. Keep it
    # outside the scenarios whose exact list walks intentionally assume emptiness.
    sentinel = api('/cohorts', dict(name='unrelated_' + uuid.uuid4().hex, kind='static'), 'POST')['id']
    owned = []
    attempted = []
    failure = InjectedFailure('primary failure plus failed cleanup')

    def failing_cleanup(path, body=None, method='GET', **kwargs):
        if method == 'DELETE':
            attempted.append(path)
            if path == owned[0]:
                raise RuntimeError('injected cleanup failure')
        return api(path, body, method, **kwargs)

    try:
        try:
            with OwnedResources(failing_cleanup, token) as request:
                for _ in range(2):
                    item = request('/cohorts', dict(name='owned_' + uuid.uuid4().hex, kind='static'), 'POST')
                    owned.append('/cohorts/' + item['id'])
                raise failure
        except InjectedFailure as error:
            assert error is failure and any('cleanup failed' in note for note in error.__notes__)
        assert attempted == owned, 'cleanup did not attempt remaining owned resources'
        assert api('/cohorts/' + sentinel)['id'] == sentinel
        assert ids('/cohorts', token) == sorted([sentinel, owned[0].split('/')[2]])
    finally:
        # The intentionally failed delete remains owned by this verifier.
        for path in owned[:1] + ['/cohorts/' + sentinel]:
            api(path + '/members', dict(userIds=[]), 'PUT')
            api(path, method='DELETE')
    assert baseline() == before
    print('Fixture isolation: two shared-store repetitions, both injected membership failures, explicit membership clearing, unrelated sentinel and continued cleanup after failure passed.', flush=True)


if __name__ == '__main__':
    owned_stack(verify_fixture_isolation, pass_environment=True)
