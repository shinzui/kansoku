#!/usr/bin/env python3
"""Organization producer/reporting proof with owned databases and server."""
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cohorts_acceptance import main
from enrichment_acceptance import event, eventually, send
from traits_acceptance import report


def verify_organizations(base, write_key, token, other_token, **_):
    prefix = 'org_' + uuid.uuid4().hex
    org_a, org_b = prefix + 'A', prefix + 'B'
    rows = []

    def row(key, name, user, organization, stamp, properties=None, version=None, anonymous=None):
        value = event(prefix + key, prefix + user, name=name, timestamp=stamp)
        value.update(userId=prefix + user, anonymousId=anonymous or prefix + user + '_cookie',
                     sourceService=prefix, properties=properties or {})
        if organization:
            value['organizationId'] = organization
        if version:
            value['schemaVersion'] = version
        rows.append(value)
        return value

    for user, organization in [('alice', org_a), ('bob', org_a), ('carol', org_b)]:
        row(user + 'start', 'signup_started', user, organization, '2026-07-01T00:00:00Z')
    for user in ['alice', 'bob']:
        row(user + 'end', 'signup_completed', user, org_a, '2026-07-01T00:00:01Z')
    row('return', 'feature_used', 'bob', org_a, '2026-07-02T00:00:00Z', {'feature': prefix})
    row('enterprise', 'group', 'alice', org_a, '2026-07-01T00:00:02Z', {'plan': 'enterprise'}, 2)
    row('pro', 'group', 'alice', org_a, '2026-07-02T00:00:02Z', {'plan': 'pro', 'seats': 10}, 2)
    row('payment', 'payment_completed', 'alice', org_a, '2026-07-01T00:00:03Z', {'amount': 7})
    row('page', 'page_view', 'alice', None, '2026-07-01T00:00:04Z', {'url': 'https://example.com'})
    row('anon-page', 'page_view', 'none', None, '2026-07-01T00:00:05Z', {'url': 'https://example.com'})['userId'] = None
    # Members jointly reach a funnel step neither person can reach alone.
    row('joint-start', 'workspace_created', 'alice', org_a, '2026-07-01T00:00:06Z')
    row('joint-end', 'document_created', 'bob', org_a, '2026-07-01T00:00:07Z')
    for batch in [rows, list(reversed(rows))]:
        for start in range(0, len(batch), 3):
            send(base, write_key, batch[start:start + 3])

    selection = 'source_service:eq:' + prefix

    def query(endpoint, credential=token, **params):
        return report(base, credential, endpoint, filter=[selection], **params)

    def values(endpoint, **params):
        return [p['value'] for p in query(endpoint, **params)]

    eventually(lambda: values('organizations') == [2, 1] and values('revenue', groupBy='org:plan') == [7])
    assert values('users', aggregate='organizations') == [2, 1]
    assert values('users') == [4, 1]
    assert values('users', aggregate='organizations', attribution='user_organization') == [2, 1]
    assert values('funnel', steps='signup_started,signup_completed', aggregate='organizations') == [2, 1]
    assert values('funnel', steps='signup_started,signup_completed') == [3, 2]
    assert values('funnel', steps='workspace_created,document_created', aggregate='organizations') == [1, 1]
    assert values('funnel', steps='workspace_created,document_created') == [1, 0]
    assert values('retention', days='1', aggregate='organizations') == [2, 1]
    assert values('conversion', aggregate='organizations') == [0.5]
    assert values('feature-adoption', aggregate='organizations') == [1]
    revenue = query('revenue', groupBy='org:plan,org:seats')
    assert revenue[0]['group'] == {'org:plan': 'pro', 'org:seats': '10'}, revenue
    page_filter = [selection, 'event_name:eq:page_view']
    assert report(base, token, 'organizations', filter=page_filter) == []
    assert [p['value'] for p in report(base, token, 'organizations', filter=page_filter, attribution='user_organization')] == [1]
    assert [p['value'] for p in report(base, token, 'organizations', filter=[selection, 'organization:eq:' + org_a])] == [1, 1]
    assert query('organizations', credential=other_token) == []

    for endpoint, params, code in [
        ('users', {'attribution': 'user_organization'}, 'invalid_organization_options'),
        ('funnel', {'steps': 'signup_started,signup_completed', 'attribution': 'invalid'}, 'malformed_request'),
        ('organizations', {'aggregate': 'users'}, 'invalid_organization_options'),
        ('experiments', {'aggregate': 'organizations'}, 'unsupported_query_parameter'),
        ('organizations', {'groupBy': 'org:unknown'}, 'invalid_group_by'),
    ]:
        url = base + '/metrics/' + endpoint + '?' + urllib.parse.urlencode(dict(params, **{'from': '2026-07-01', 'to': '2026-07-03'}))
        try:
            urllib.request.urlopen(urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token}), timeout=5)
            raise AssertionError('invalid organization request succeeded')
        except urllib.error.HTTPError as error:
            value = json.load(error)
            assert error.code == 400 and value['code'] == code, value
    print('Organizations: replay, member funnels, retention, traits, attribution, defaults, validation and account isolation passed.', flush=True)


if __name__ == '__main__':
    from isolated_clickhouse import isolated_clickhouse, apply_migrations
    from test_support import binary, hspec
    with isolated_clickhouse(block_size=2) as native:
        apply_migrations(native)
        hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Organization'], env=native)
    main(verify=verify_organizations)
