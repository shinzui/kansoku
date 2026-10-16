"""Public ordinary-producer acceptance for deterministic funnels and diagnostics."""
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

from enrichment_acceptance import event, eventually, send


def query(base, token, endpoint, **parameters):
    params = dict(from_='2026-07-01', to='2026-07-02')
    params.update(parameters)
    params['from'] = params.pop('from_')
    request = urllib.request.Request(base + '/metrics/' + endpoint + '?' + urllib.parse.urlencode(params, doseq=True),
        headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)['points']


def verify_funnels(base, write_key, service_token):
    prefix = 'funnel_' + uuid.uuid4().hex
    first, last = prefix + '_a', prefix + '_b'
    rows = []
    for eid, name, stamp, properties in [
            ('exp-a', 'experiment_viewed', '00:00:00', {'experiment': prefix, 'variant': 'a'}),
            ('exp-b', 'experiment_viewed', '00:00:00.500', {'experiment': prefix, 'variant': 'b'}),
            ('start', first, '00:00:01', {}),
            ('interrupt', 'page_view', '00:00:01.250', {'url': 'https://example.com/interrupt'}),
            ('later', first, '00:00:02', {}),
            ('end', last, '00:00:02.750', {}),
            ('repeat', 'experiment_viewed', '00:00:03', {'experiment': prefix, 'variant': 'b'})]:
        value = event(prefix + eid, prefix, name=name, timestamp='2026-07-01T' + stamp + 'Z')
        value.update(userId=prefix, sourceService=prefix, properties=properties)
        rows.append(value)
    for body in (rows, list(reversed(rows))):
        for start in range(0, len(body), 3):
            send(base, write_key, body[start:start + 3])
    def report(endpoint, **parameters):
        return query(base, service_token, endpoint, **parameters)
    def ready():
        counts = report('funnel', steps=first + ',' + last, window=10)
        return (len(counts) == 2 and counts[1]['value'] == 1 and
                len(report('experiments', experiment=prefix, measure='diagnostics')) == 6)
    eventually(ready)
    for endpoint in ('funnel', 'experiments/funnel'):
        for mode in ('sequential', 'strict'):
            for measure in ('count', 'time_to_convert'):
                for excluded in (False, True):
                    for grouped in (False, True):
                        params = dict(steps=first + ',' + last, window=10, mode=mode, measure=measure)
                        if endpoint.startswith('experiments/'):
                            params['experiment'] = prefix
                        if excluded:
                            params['exclude'] = ['page_view', 'page_view']
                        if grouped:
                            params['groupBy'] = 'source_service,country_code'
                        points = report(endpoint, **params)
                        assert len(points) == (4 if endpoint.startswith('experiments/') else 2), points
                        if grouped:
                            assert all(point['group']['source_service'] == prefix for point in points), points
                        if measure == 'count':
                            assert all(point['value'] == 1 for point in points), points
                        else:
                            expected = .75 if mode == 'strict' or excluded else 1.75
                            assert all(point['value'] == expected for point in points), points
                            assert {point['group']['measure'] for point in points} == {'p50_seconds', 'p90_seconds'}
        # First-touch property validation and malformed/unsupported controls are HTTP failures.
        for parameters, code in [
                (dict(mode='strict', filter=json.dumps(dict(dimension='source', op='eq', value='web'))), 'invalid_filter'),
                (dict(exclude=[first]), 'invalid_funnel_exclusion'),
                (dict(exclude=['bad name']), 'invalid_funnel_exclusion')]:
            params = dict(steps=first + ',' + last, **parameters)
            if endpoint.startswith('experiments/'):
                params['experiment'] = prefix
            try:
                report(endpoint, **params)
            except urllib.error.HTTPError as failure:
                assert failure.code == 400 and json.load(failure)['code'] == code
            else:
                raise AssertionError('invalid funnel controls were accepted')
    # EP-43: public controls use the same exposure-gated, replay-safe timelines.
    extra = []
    for eid, name, stamp, properties in [
            ('second-start', first, '00:00:04', {}),
            ('second-end', last, '00:00:05', {}),
            ('attribution', 'subscription_started', '00:00:06', {'plan': 'pro', 'billing_period': 'monthly'})]:
        value = event(prefix + eid, prefix, name=name, timestamp='2026-07-01T' + stamp + 'Z')
        value.update(userId=prefix, sourceService=prefix, properties=properties)
        extra.append(value)
    send(base, write_key, extra)
    eventually(lambda: report('funnel', steps=first + ',' + last, counting='totals')[-1]['value'] == 2)
    for endpoint in ('funnel', 'experiments/funnel'):
        common = dict(steps=first + ',' + last, window=10)
        if endpoint.startswith('experiments/'):
            common['experiment'] = prefix
        totals = report(endpoint, **common, counting='totals')
        assert all(point['value'] == 2 for point in totals), totals
        assert {point['group']['measure'] for point in totals} == {'count', 'entries'}, totals
        for point in totals:
            if point['group']['measure'] == 'entries':
                assert point['bucket'] is None and point['group']['index'] is None and point['group']['step'] is None, point
        reverse_steps = dict(common, steps=last + ',' + first)
        any_order = report(endpoint, **reverse_steps, mode='any_order')
        assert all(point['value'] == 1 for point in any_order), any_order
        for attribution, expected in [('first_touch', 'other'), ('last_touch', 'pro'), ('step:3', 'pro')]:
            points = report(endpoint, **dict(common, steps=first + ',' + last + ',subscription_started'), groupBy='prop:plan', attribution=attribution)
            assert all(point['group']['prop:plan'] == expected for point in points), points
        for parameters in [dict(counting='bad'), dict(attribution='step:0'), dict(attribution='step:3'), dict(mode='bad')]:
            try:
                report(endpoint, **common, **parameters)
            except urllib.error.HTTPError as failure:
                assert failure.code == 400, failure
            else:
                raise AssertionError('invalid extension control accepted')
    diagnostic = report('experiments', experiment=prefix, measure='diagnostics')
    values = {(point['group']['measure'], point['group']['variant']): point['value'] for point in diagnostic}
    assert values == {('exposed_users', None): 1, ('multiple_exposure', None): 1,
                      ('assigned_users', 'a'): 1, ('assigned_users', 'b'): 0,
                      ('variant_share', 'a'): 1, ('variant_share', 'b'): 0}, values
    # Fixed signup contract: completion-only/before-start users cannot inflate conversion.
    signup = []
    for suffix, name, user, stamp in [
            ('s1', 'signup_started', 'one', '00:01:00'), ('c1', 'signup_completed', 'one', '00:01:01'),
            ('co', 'signup_completed', 'only', '00:01:01'), ('cb', 'signup_completed', 'before', '00:01:00'),
            ('sb', 'signup_started', 'before', '00:01:01'), ('sa', 'signup_started', 'alone', '00:01:00')]:
        value = event(prefix + suffix, prefix + user, name=name, timestamp='2026-07-01T' + stamp + 'Z')
        value.update(userId=prefix + user, sourceService=prefix, properties={})
        signup.append(value)
    for start in range(0, len(signup), 3):
        send(base, write_key, signup[start:start + 3])
    population = json.dumps(dict(dimension='source_service', op='eq', value=prefix))
    eventually(lambda: report('conversion', filter=[population]) == [dict(bucket=None, group={}, value=1/3)])
    print('EP-36/43 public workflow: both routes/all mode/measure/exclusion/group combinations, replay, timing, validation, exact diagnostics and ordered signup conversion passed.', flush=True)
