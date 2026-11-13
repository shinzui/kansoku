"""Ordinary producer/reporting acceptance for closed-day activity metrics."""
from datetime import datetime, timedelta, timezone
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

from enrichment_acceptance import event, eventually, send


def report(base, token, endpoint, source, **parameters):
    params = dict(from_='2026-07-01', to='2026-07-10')
    params.update(parameters)
    params['from'] = params.pop('from_')
    filters = params.pop('filter', [])
    if isinstance(filters, str):
        filters = [filters]
    params['filter'] = [json.dumps(dict(dimension='source_service', op='eq', value=source))] + filters
    request = urllib.request.Request(base + '/metrics/' + endpoint + '?' + urllib.parse.urlencode(params, doseq=True),
        headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=5) as response:
        result = json.load(response)
        assert result['metric'] == ('active_users' if endpoint == 'users' else endpoint)
        return result['points']


def retention_values(points):
    return {(point['group']['cohort'], point['group']['offset']): point['value'] for point in points}


def verify_activity(base, write_key, service_token):
    prefix = 'activity_' + uuid.uuid4().hex
    samples = [('one-start', 'one', '2026-07-01T00:00:00Z'),
               ('one-return', 'one', '2026-07-05T00:00:00Z'),
               ('two-start', 'two', '2026-07-01T00:00:00Z'),
               ('old', 'old', '2026-06-30T00:00:00Z'),
               ('old-window', 'old', '2026-07-01T00:00:00Z'),
               ('old-return', 'old', '2026-07-02T00:00:00Z'),
               ('recent-start', 'recent', '2026-07-08T00:00:00Z'),
               ('recent-return', 'recent', '2026-07-09T00:00:00Z')]
    body = []
    for eid, user, timestamp in samples:
        value = event(prefix + eid, prefix + user, timestamp=timestamp)
        value.update(sourceService=prefix, userId=prefix + user)
        body.append(value)
    profile = event(prefix + 'profile', prefix + 'profile', name='identify', timestamp='2026-07-01T00:00:00Z')
    profile.update(sourceService=prefix, userId=prefix + 'profile', properties={})
    body.append(profile)
    for start in range(0, len(body), 3):
        send(base, write_key, body[start:start + 3])
    def query(endpoint, **parameters):
        return report(base, service_token, endpoint, prefix, **parameters)
    expected = {('2026-07-01', '0'): 2, ('2026-07-01', '1'): 1,
                ('2026-07-01', '7'): 0, ('2026-07-08', '0'): 1}
    eventually(lambda: retention_values(query('retention', days='1,7', mode='on_or_after', cohort='lifetime')) == expected)
    exact = retention_values(query('retention', days='1,7', mode='on', cohort='window'))
    assert exact == {('2026-07-01', '0'): 3, ('2026-07-01', '1'): 1,
                     ('2026-07-01', '7'): 0, ('2026-07-08', '0'): 1, ('2026-07-08', '1'): 1}, exact
    whole = query('users', window='calendar', timeGrain='none')
    assert len(whole) == 1 and whole[0]['bucket'] is None and whole[0]['value'] == 4, whole
    rolling = {point['bucket']: point['value'] for point in query('users', window='rolling7')}
    assert rolling['2026-07-07'] == 3 and rolling['2026-07-09'] == 2, rolling
    sticky = query('stickiness', from_='2026-07-09')
    assert {point['group']['measure']: point['value'] for point in sticky} == {
        'daily_active': 1, 'rolling30_active': 4, 'ratio': .25}, sticky
    life = {(point['bucket'], point['group']['status']): point['value']
            for point in query('lifecycle', from_='2026-07-02', to='2026-07-04')}
    assert life == {('2026-07-02', 'new'): 0, ('2026-07-02', 'returning'): 1,
                    ('2026-07-02', 'resurrecting'): 0, ('2026-07-02', 'dormant'): 2,
                    ('2026-07-03', 'new'): 0, ('2026-07-03', 'returning'): 0,
                    ('2026-07-03', 'resurrecting'): 0, ('2026-07-03', 'dormant'): 1}, life
    # The public observation policy applies consistently, before storage execution.
    today = datetime.now(timezone.utc).date()
    for endpoint in ('users', 'stickiness', 'lifecycle', 'retention'):
        try:
            query(endpoint, from_=today.isoformat(), to=(today + timedelta(days=1)).isoformat())
        except urllib.error.HTTPError as failure:
            assert failure.code == 400
            assert json.load(failure)['code'] == 'unclosed_observation_window'
        else:
            raise AssertionError(endpoint + ' accepted an unclosed observation day')
    verify_calendar_retention(base, write_key, service_token)
    print('EP-35 public workflow: exact rolling/stickiness, mature and cumulative retained-history retention, lifecycle and closed-day validation passed.', flush=True)


def verify_calendar_retention(base, write_key, service_token, *, typed_client=False):
    prefix = 'calendar_' + uuid.uuid4().hex
    samples = [('signup_completed', user, '2026-07-' + day + 'T00:00:00Z')
               for user, day in [('A', '06'), ('B', '06'), ('C', '12'), ('D', '13'),
                                 ('old', '05'), ('old', '07'), ('F', '26')]]
    samples += [('document_created', user, '2026-07-' + day + 'T00:00:00Z')
                for user, day in [('A', '13'), ('A', '15'), ('A', '19'), ('A', '20'),
                                  ('C', '20'), ('D', '20'), ('E', '14'), ('old', '14')]]
    samples += [('signup_completed', 'M', '2024-01-31T23:59:59.999Z'),
                ('signup_completed', 'N', '2024-01-01T00:00:00Z'),
                ('signup_completed', 'P', '2024-02-29T00:00:00Z'),
                ('document_created', 'M', '2024-02-01T00:00:00Z'),
                ('document_created', 'M', '2024-02-29T23:59:59.999Z'),
                ('signup_completed', 'upper', '2024-03-01T00:00:00Z')]
    rows = []
    for n, (name, user, timestamp) in enumerate(samples):
        row = event(prefix + str(n), prefix + user, name=name, timestamp=timestamp)
        row.update(userId=prefix + user, sourceService=prefix, properties={})
        rows.append(row)
    for start in range(0, len(rows), 3):
        send(base, write_key, rows[start:start + 3])
    def query(**params):
        options = dict(from_='2026-07-06', to='2026-07-27', period='week', days='1,2',
                       startEvent='signup_completed', returnEvent='document_created')
        options.update(params)
        options = {key: value for key, value in options.items() if value is not None}
        points = report(base, service_token, 'retention', prefix, **options)
        assert all(point['bucket'] is None for point in points), points
        return retention_values(points)
    exact = {('2026-07-06', '0'): 4, ('2026-07-06', '1'): 2, ('2026-07-06', '2'): 2,
             ('2026-07-13', '0'): 1, ('2026-07-13', '1'): 1, ('2026-07-20', '0'): 1}
    eventually(lambda: query() == exact)
    assert query(days=None) == exact
    assert query(days=',,2,1,2,,') == exact
    lifetime = dict(exact)
    lifetime.update({('2026-07-06', '0'): 3, ('2026-07-06', '1'): 1})
    assert query(cohort='lifetime') == lifetime
    cumulative = dict(exact)
    cumulative[('2026-07-06', '1')] = 3
    del cumulative[('2026-07-13', '1')]
    assert query(mode='on_or_after') == cumulative
    partial = dict(exact)
    del partial[('2026-07-06', '2')]
    del partial[('2026-07-20', '0')]
    del partial[('2026-07-13', '1')]
    assert query(to='2026-07-26') == partial
    assert query(to='2026-07-26', mode='on_or_after') == {
        ('2026-07-06', '0'): 4, ('2026-07-13', '0'): 1}
    monthly = dict(from_='2024-01-01', to='2024-03-01', period='month', days='1')
    assert query(**monthly) == {('2024-01-01', '0'): 2, ('2024-01-01', '1'): 1,
                               ('2024-02-01', '0'): 1}
    assert query(**dict(monthly, days=None)) == query(**monthly)
    monthly['to'] = '2024-02-29'
    assert query(**monthly) == {('2024-01-01', '0'): 2}
    # Additional return from Japan: a start-only country selector must not remove it.
    jp = event(prefix + 'jp', prefix + 'A', name='document_created', timestamp='2026-07-13T12:00:00Z')
    jp.update(userId=prefix + 'A', sourceService=prefix, properties={})
    send(base, write_key, [jp], address='2001:218::')
    selected = dict(exact)
    selected.update({('2026-07-06', '1'): 1, ('2026-07-06', '2'): 0, ('2026-07-13', '1'): 0})
    eventually(lambda: query(startFilter='country_code:eq:GB', returnFilter='country_code:eq:JP') == selected)
    assert query(startFilter='country_code:eq:GB') == exact
    assert query(startFilter='country_code:eq:JP') == {}
    zeros = dict(exact)
    zeros.update({('2026-07-06', '1'): 0, ('2026-07-06', '2'): 0, ('2026-07-13', '1'): 0})
    assert query(returnEvent='unknown_valid') == zeros
    assert query(startEvent='unknown_valid') == {}
    assert query(startFilter='event_name:eq:page_view') == {}
    assert query(startFilter='event_name:eq:signup_completed|event_name:eq:page_view') == exact
    assert query(filter=['country_code:eq:GB'], returnFilter='country_code:eq:JP') == zeros
    assert query(groupBy='event_name') == zeros
    grouped = report(base, service_token, 'retention', prefix, from_='2026-07-06', to='2026-07-27',
                     period='week', days='1,2', startEvent='signup_completed', returnEvent='document_created',
                     startFilter='country_code:eq:GB', returnFilter='country_code:eq:JP', groupBy='country_code,source_service')
    assert retention_values(grouped) == zeros
    assert all(p['group']['country_code'] == 'GB' and p['group']['source_service'] == prefix for p in grouped)
    legacy = report(base, service_token, 'retention', prefix, days='1,7')
    assert report(base, service_token, 'retention', prefix, days='1,7', period='day') == legacy
    def cohort_api(path, body=None, method='GET'):
        request = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                         method=method, headers={'Authorization': 'Bearer ' + service_token,
                                                                 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=5) as response:
            return json.load(response)
    saved = cohort_api('/cohorts', {'name': prefix, 'kind': 'behavioural', 'conditions': [
        {'did': 'document_created', 'atLeast': 1, 'withinDays': 7,
         'filters': [{'dimension': 'source_service', 'op': 'eq', 'value': prefix}]}]}, 'POST')
    try:
        # Membership is anchored to July 27, including intermediate-period returns;
        # lifetime history must not shift this endpoint or its seven-day lookback.
        member = 'cohort:eq:' + saved['id']
        cohort_expected = {('2026-07-06', '0'): 2, ('2026-07-06', '1'): 1,
                           ('2026-07-06', '2'): 2, ('2026-07-13', '0'): 1, ('2026-07-13', '1'): 1}
        assert query(filter=[member]) == cohort_expected
        assert query(filter=[member + '|source_service:eq:' + prefix + 'absent'], cohort='lifetime') == cohort_expected
    finally:
        cohort_api('/cohorts/' + saved['id'], method='DELETE')
    org_source = prefix + '_org'
    org_rows = []
    for n, (name, user, timestamp) in enumerate([('signup_completed', 'starter', '2026-07-06T00:00:00Z'),
                                                ('document_created', 'returner', '2026-07-13T00:00:00Z')]):
        row = event(org_source + str(n), org_source + user, name=name, timestamp=timestamp)
        row.update(userId=org_source + user, sourceService=org_source,
                   organizationId=org_source, properties={})
        org_rows.append(row)
    send(base, write_key, org_rows)
    def organization(**params):
        return retention_values(report(base, service_token, 'retention', org_source, from_='2026-07-06',
                                        to='2026-07-20', period='week', days='1', startEvent='signup_completed',
                                        returnEvent='document_created', **params))
    eventually(lambda: organization(aggregate='organizations') == {('2026-07-06', '0'): 1, ('2026-07-06', '1'): 1})
    assert organization() == {('2026-07-06', '0'): 1, ('2026-07-06', '1'): 0}
    # Combined eight-list budget succeeds, ninth and decoded-byte overflow fail closed.
    assert query(startFilter=['country_code:eq:GB'] * 3,
                 returnFilter=['event_name:eq:document_created'] * 4) == exact
    def problem(params, code):
        try:
            query(**params)
        except urllib.error.HTTPError as failure:
            assert failure.code == 400
            assert failure.headers.get_content_type() == 'application/problem+json'
            body = json.load(failure)
            assert body['code'] == code, (params, body)
        else:
            raise AssertionError(('accepted invalid retention options', params))
    for params, code in [({'days': '366', 'period': 'day'}, 'invalid_retention_days'),
                         ({'days': '53'}, 'invalid_retention_days'),
                         ({'days': '13', 'period': 'month', 'from_': '2026-07-01'}, 'invalid_retention_days'),
                         ({'from_': '2026-07-07'}, 'invalid_retention_period'),
                         ({'period': 'month'}, 'invalid_retention_period'),
                         ({'days': '1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33'}, 'too_many_retention_days'),
                         ({'days': '9999999999999999999999999999'}, 'invalid_retention_days'),
                         ({'period': ''}, 'malformed_request'),
                         ({'period': 'fortnight'}, 'malformed_request'),
                         ({'startEvent': ''}, 'invalid_retention_event'),
                         ({'returnEvent': 'a,b'}, 'invalid_retention_event'),
                         ({'period': ['week', 'day']}, 'invalid_query_parameter'),
                         ({'startEvent': ['a', 'b']}, 'invalid_query_parameter'),
                         ({'startFilter': 'user:plan:eq:pro'}, 'invalid_retention_filter'),
                         ({'returnFilter': 'country_code:eq:GB|org:plan:eq:pro'}, 'invalid_retention_filter'),
                         ({'returnFilter': 'session:country_code:eq:GB'}, 'invalid_retention_filter'),
                         ({'startFilter': ['country_code:eq:GB'] * 4, 'returnFilter': ['country_code:eq:GB'] * 4}, 'invalid_filter'),
                         ({'startFilter': [' ' * 8200 + '{"dimension":"country_code","op":"eq","value":"GB"}'],
                           'returnFilter': [' ' * 8200 + '{"dimension":"country_code","op":"eq","value":"GB"}']}, 'invalid_filter')]:
        problem(params, code)
    for raw in ('period', 'startEvent', 'returnEvent'):
        request = urllib.request.Request(base + '/metrics/retention?from=2026-07-06&to=2026-07-27&' + raw,
                                         headers={'Authorization': 'Bearer ' + service_token})
        try:
            urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as failure:
            assert failure.code == 400 and json.load(failure)['code'] == 'invalid_query_parameter'
        else:
            raise AssertionError('bare retention scalar was accepted: ' + raw)
    with urllib.request.urlopen(base + '/openapi.json', timeout=5) as response:
        contract = json.load(response)
    operation = contract['paths']['/metrics/retention']['get']
    parameters = {p['name']: p for p in operation['parameters']}
    assert parameters['period']['schema']['enum'] == ['day', 'week', 'month']
    for name in ('startFilter', 'returnFilter'):
        assert parameters[name]['schema']['type'] == 'array'
    for name in ('period', 'startEvent', 'returnEvent'):
        assert parameters[name]['schema']['type'] == 'string'
    for fragment in ('1..52', '1..12', 'invalid_retention_period', 'invalid_retention_filter', 'full maximum horizon', '16384'):
        assert fragment in operation['description'], fragment
    from pathlib import Path
    committed = json.loads(Path('docs/api/openapi.json').read_text())
    assert operation == committed['paths']['/metrics/retention']['get'], 'served retention OpenAPI differs from generated contract'
    if typed_client:
        import os
        from test_support import binary, hspec
        env = dict(os.environ, KANSOKU_REQUIRED_INTEGRATION='1', KANSOKU_SERVER_URL=base,
                   KANSOKU_RETENTION_SERVICE_TOKEN=service_token, KANSOKU_RETENTION_SOURCE=prefix)
        hspec([binary('kansoku-client:test:kansoku-client-test'),
               '--match=live integration retention'], env=env)
    print('EP-70 public retention: weekly/monthly, side selections, grouped populations, bounds, served contract and compatibility passed.', flush=True)
    return prefix
