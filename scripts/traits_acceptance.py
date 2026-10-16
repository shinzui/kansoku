"""Ordinary public producer/reporting proof of governed current traits."""
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

from enrichment_acceptance import event, eventually, send


def report(base, token, endpoint, **parameters):
    params = dict(from_='2026-07-01', to='2026-07-03')
    params.update(parameters)
    params['from'] = params.pop('from_')
    request = urllib.request.Request(base + '/metrics/' + endpoint + '?' + urllib.parse.urlencode(params, doseq=True),
        headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)['points']


def verify_traits(base, write_key, service_token):
    prefix = 'traits_' + uuid.uuid4().hex
    pro = prefix + '_pro'
    person = prefix + '_alice'
    cookie = prefix + '_cookie'
    rows = []
    def sample(eid, name, timestamp, user=person, properties=None, version=None, session=None, anonymous=cookie):
        value = event(prefix + eid, session or prefix, name=name, timestamp=timestamp)
        value.update(sourceService=prefix, anonymousId=anonymous, properties=properties or {})
        if user is None:
            value.pop('userId', None)
        else:
            value['userId'] = user
        if version is not None:
            value['schemaVersion'] = version
        if name == 'page_view':
            value['properties'] = {'url': 'https://shop.example/entry'}
        return value
    rows.extend([
        sample('old', 'page_view', '2026-06-30T00:00:00Z', session=prefix + '_old'),
        sample('page', 'page_view', '2026-07-01T00:00:00Z', user=None),
        sample('exposure-a', 'experiment_viewed', '2026-07-01T00:00:00Z', user=None, properties={'experiment': prefix, 'variant': 'a'}),
        sample('exposure-b', 'experiment_viewed', '2026-07-01T00:00:00.500Z', properties={'experiment': prefix, 'variant': 'b'}),
        sample('start', 'signup_started', '2026-07-01T00:00:01Z'),
        sample('end', 'signup_completed', '2026-07-01T00:00:02Z'),
        sample('payment', 'payment_completed', '2026-07-01T00:00:03Z', properties={'amount': 10}),
        sample('feature', 'feature_used', '2026-07-01T00:00:04Z', properties={'feature': prefix}),
        sample('exposure-repeat', 'experiment_viewed', '2026-07-01T00:00:05Z', properties={'experiment': prefix, 'variant': 'a'}),
        sample('once', 'identify_once', '2026-07-01T00:00:06Z', version=1, properties={'plan': prefix + '_initial', 'initial_plan': 'starter'}),
        sample('set', 'identify', '2026-07-02T00:00:00Z', version=2, properties={'plan': pro, 'company_size': 10, 'country': 'US'}),
        sample('legacy', 'identify', '2026-07-03T00:00:00Z', version=1, properties={'plan': 'legacy-must-not-win'}),
        sample('bob-once', 'identify_once', '2026-07-02T00:00:00Z', user=prefix + '_bob', anonymous=prefix + '_bob-cookie', session=prefix + '_bob', version=1, properties={'plan': prefix + '_free', 'company_size': 2}),
        sample('bob-page', 'page_view', '2026-07-01T00:00:00Z', user=prefix + '_bob', anonymous=prefix + '_bob-cookie', session=prefix + '_bob'),
        sample('anon-page', 'page_view', '2026-07-01T00:00:00Z', user=None, anonymous=person, session=prefix + '_anon'),
    ])
    for start in range(0, len(rows), 3):
        send(base, write_key, rows[start:start + 3])
    for start in range(0, len(rows), 3):
        send(base, write_key, rows[start:start + 3])
    population = json.dumps(dict(dimension='user:plan', op='eq', value=pro))
    def query(endpoint, **parameters):
        return report(base, service_token, endpoint, filter=[population], **parameters)
    def total(endpoint, **parameters):
        return sum(point['value'] for point in query(endpoint, **parameters))
    source_filter = json.dumps(dict(dimension='source_service', op='eq', value=prefix))
    eventually(lambda: total('page-views') == 1 and total('conversion') == 1 and
               sum(point['value'] for point in report(base, service_token, 'page-views', filter=[source_filter])) == 3)
    assert total('users') == 1
    assert total('users', window='rolling7') == 2
    assert total('revenue') == 10
    assert total('feature-adoption') == 1
    assert total('sessions') == 1
    assert total('acquisition', measure='sessions') == 1
    assert total('acquisition', measure='users') == 1
    assert [point['value'] for point in query('retention', days='1', mode='on', cohort='window')] == [1, 0]
    assert query('retention', days='1', mode='on', cohort='lifetime') == []
    sticky = query('stickiness')
    assert sum(point['value'] for point in sticky if point['group']['measure'] == 'daily_active') == 1
    life = query('lifecycle')
    assert sum(point['value'] for point in life if point['group']['status'] == 'returning') == 1
    grouped = query('page-views', groupBy='country_code,user:country')
    assert grouped[0]['group'] == {'country_code': 'GB', 'user:country': 'US'}, grouped
    for mode in ('sequential', 'strict'):
        assert [point['value'] for point in query('funnel', steps='signup_started,signup_completed', mode=mode)] == [1, 1]
        assert [point['value'] for point in query('experiments/funnel', experiment=prefix, steps='signup_started,signup_completed', mode=mode, groupBy='user:plan')] == [1, 1, 1, 1]
    exposures = query('experiments', experiment=prefix, groupBy='user:plan')
    assert [point['value'] for point in exposures] == [1, 1], exposures
    # Canonical stitching differs deliberately from the default raw-identity sketch.
    raw = report(base, service_token, 'experiments', experiment=prefix)
    assert {point['group']['variant']: point['value'] for point in raw} == {'a': 2, 'b': 1}, raw
    diagnostics = query('experiments', experiment=prefix, measure='diagnostics', groupBy='user:plan')
    assert len(diagnostics) == 6
    assert sum(point['value'] for point in diagnostics if point['group']['measure'] == 'variant_share') == 1
    assert [point['value'] for point in query('experiments/conversion', experiment=prefix, event='signup_completed', groupBy='user:plan')] == [1] * 6
    # Exact decimal validation occurs before native numeric conversion or queueing.
    invalid = sample('invalid', 'identify', '2026-07-04T00:00:00Z', version=2, properties={'plan': 'invalid-must-not-win', 'company_size': 'RAW_NUMBER'})
    data = json.dumps([invalid]).replace('"RAW_NUMBER"', '1.0000000000000000000001').encode()
    request = urllib.request.Request(base + '/v1/batch', data=data, headers={
        'Authorization': 'Bearer ' + write_key, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=5) as response:
        rejected = json.load(response)
        assert response.status == 202 and rejected['accepted'] == 0 and len(rejected['rejected']) == 1, rejected
    assert total('page-views') == 1
    print('EP-40 public workflow: explicit trait versions, immutable replay, stitched/unrelated subjects, every metric population, numeric/current traits, exact experiments and decimal rejection passed.', flush=True)
