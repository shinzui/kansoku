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
    print('EP-35 public workflow: exact rolling/stickiness, mature and cumulative retained-history retention, lifecycle and closed-day validation passed.', flush=True)
