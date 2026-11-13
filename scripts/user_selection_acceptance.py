#!/usr/bin/env python3
"""Public identified-user selection proof using the existing owned-store harness."""
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid

from acceptance_resources import OwnedResources
from cohorts_acceptance import main
from enrichment_acceptance import event, eventually, send


def verify_user_selection(base, write_key, token, other_token, **_):
    prefix = 'selection_' + uuid.uuid4().hex
    alice, bob = prefix + '_alice', prefix + '_bob'

    def api(path, body=None, method='GET', credential=token, expected=200, **params):
        request = urllib.request.Request(base + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else ''),
            data=None if body is None else json.dumps(body).encode(), method=method,
            headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        result = json.load(response)
        assert response.status in (expected if isinstance(expected, tuple) else (expected,)), (path, response.status, result)
        return result

    def sample(suffix, name, second, user, session, anonymous=None, properties=None):
        row = event(prefix + suffix, prefix + session, name=name, timestamp=f'2026-07-01T12:{second // 60:02}:{second % 60:02}Z')
        row.update(sourceService=prefix, properties=properties or {}, anonymousId=anonymous or prefix + session)
        if user is None:
            row.pop('userId', None)
        else:
            row['userId'] = user
        if name == 'page_view':
            row['url'] = 'https://shop.example/alice?utm_medium=email'
            row['utmMedium'] = 'email'
            row['properties'] = {'url': row['url']}
        if name == 'identify':
            row['schemaVersion'] = 2
        return row

    rows = [sample('a0', 'page_view', 0, None, 'a'),
            sample('a1', 'identify', 10, alice, 'a', properties={'plan': 'pro'}),
            sample('a2', 'page_view', 20, alice, 'a'),
            sample('a3', 'feature_used', 30, alice, 'a', properties={'feature': 'export'}),
            sample('a4', 'payment_completed', 40, alice, 'a', properties={'amount': 2}),
            sample('a5', 'payment_completed', 60, alice, 'a', properties={'amount': 4})]
    for person, session, amount in [(bob, 'b', 10), (None, 'anon', 100)]:
        for index, (name, props) in enumerate([('page_view', {}), ('feature_used', {'feature': 'export'}), ('payment_completed', {'amount': amount})]):
            rows.append(sample(session + str(index), name, index, person, session,
                               anonymous=alice if person is None else None, properties=props))
    for batch in (rows, rows):
        for start in range(0, len(batch), 3):
            send(base, write_key, batch[start:start + 3])
    dates = {'from': '2026-07-01', 'to': '2026-07-02'}
    source = 'source_service:eq:' + prefix
    selected = json.dumps(dict(dimension='user_id', op='eq', value=alice))

    def report(route, filters=None, **params):
        return api('/metrics/' + route, **dates, filter=[source] + (filters if filters is not None else [selected]), **params)['points']

    def total(route, **params):
        return sum(p['value'] for p in report(route, **params))

    eventually(lambda: total('events') == 6 and total('events', filters=[]) == 12)
    assert total('events', filters=['user_id:neq:' + alice]) == 3
    assert total('events', filters=[json.dumps(dict(dimension='user_id', op='in', value=[alice, bob]))]) == 9
    assert {p['group']['event_name']: p['value'] for p in report('events', groupBy='event_name', timeGrain='none')} == {'page_view': 2, 'identify': 1, 'feature_used': 1, 'payment_completed': 2}
    assert total('page-views') == 2
    assert total('users') == 1
    for window in ('rolling7', 'rolling30'):
        assert total('users', window=window) == 1
    assert total('sessions') == 1
    assert total('sessions', measure='average_duration_seconds') == 60
    assert total('sessions', measure='bounce_rate') == 0
    for measure in ('sessions', 'users', 'converted_users', 'conversion_rate'):
        options = {'conversionEvents': 'payment_completed'} if measure in ('converted_users', 'conversion_rate') else {}
        points = report('acquisition', measure=measure, **options)
        assert sum(p['value'] for p in points) == 1, points
        assert points[0]['group']['channel'] == 'email', points
    assert total('revenue') == 6
    assert total('feature-adoption') == 1
    for kind, expected in [('count', 2), ('unique_count', 1), ('sum', 6), ('average', 3), ('percentile', 3)]:
        options = {'property': 'amount'} if kind in ('sum', 'average', 'percentile') else {}
        if kind == 'percentile':
            options['quantile'] = .5
        assert total('custom', events='payment_completed', aggregation=kind, **options) == expected
    assert total('custom', events='payment_completed', aggregation='count', denominatorEvents='page_view', denominatorAggregation='count') == 1
    assert total('events', filters=['user_id:eq:' + prefix + '_absent']) == 0
    assert api('/metrics/events', credential=other_token, **dates, filter=selected)['points'] == []
    assert api('/metrics/events', expected=400, **dates, filter=json.dumps(dict(dimension='user_id', op='in', value=[alice] * 21)))['code'] == 'invalid_metric'
    assert api('/metrics/organizations', expected=400, **dates, filter=[selected, 'cohort:eq:00000000-0000-0000-0000-000000000001'])['code'] == 'invalid_metric'
    assert api('/metrics/events', expected=400, **dates, groupBy='user_id', filter=selected)['code'] == 'invalid_group_by'
    assert total('page-views', filters=[selected, 'user:plan:eq:pro', 'session:channel:eq:email']) == 2
    assert total('custom', events='payment_completed', aggregation='count', filters=[selected, 'prop:amount:gt:2']) == 1
    assert total('events', filters=['user_id:eq:' + alice + '|event_name:eq:page_view']) == 8
    with OwnedResources(api, token) as owned:
        definition = dict(name=prefix, eventNames=['payment_completed'], aggregation='sum', aggregationProperty='amount', filters=[selected], groupBy=[], timeGrain='day')
        owned('/metric-definitions', definition, 'POST')
        assert total('custom', metric=prefix, filters=[]) == 6
        assert total('custom', metric=prefix, filters=['user_id:eq:' + bob]) == 0
        component = dict(definition, aggregation='count', aggregationProperty=None, timeGrain=None)
        ratio = dict(name=prefix + '_ratio', numerator=dict(component, filters=[source, selected]), denominator=dict(component, filters=[source]))
        owned('/metric-definitions', ratio, 'POST')
        assert total('custom', metric=ratio['name'], filters=[]) == .5
        for user, label in [(alice, 'in'), (bob, 'out')]:
            cohort = owned('/cohorts', dict(name=prefix + user, kind='static'), 'POST')['id']
            owned('/cohorts/' + cohort + '/members', dict(userIds=[user]), 'PUT')
            points = report('page-views', groupBy='cohort:' + cohort)
            assert [(p['group']['cohort:' + cohort], p['value']) for p in points] == [(label, 2)], points
    # Select by the start day, while identity evidence and a second user arrive later.
    overnight = [sample('night0', 'page_view', 0, None, 'night'),
                 sample('night1', 'identify', 10, alice, 'night'),
                 sample('night2', 'page_view', 60, bob, 'night', anonymous=prefix + '_night_bob')]
    for row, stamp in zip(overnight, ['2026-06-30T23:59:00Z', '2026-07-01T00:00:10Z', '2026-07-01T00:01:00Z']):
        row['occurredAt'] = stamp
    send(base, write_key, overnight)
    def night(measure, user=selected):
        return sum(p['value'] for p in api('/metrics/sessions', **{'from': '2026-06-30', 'to': '2026-07-01'},
            measure=measure, filter=[source, user])['points'])
    eventually(lambda: night('average_duration_seconds') == 120)
    assert night('count') == 1
    assert night('count', 'user_id:eq:' + bob) == 0
    assert night('bounce_rate') == 0
    for index, ident in enumerate(['user:' + prefix, prefix + "'\\人|opaque"]):
        send(base, write_key, [sample('opaque' + str(index), 'page_view', 0, ident, 'opaque' + str(index))])
        literal = json.dumps(dict(dimension='user_id', op='eq', value=ident))
        eventually(lambda: total('page-views', filters=[literal]) == 1)
    print('Fixture source=' + prefix + ' Alice=' + alice, flush=True)
    schema = api('/openapi.json')
    assert 'user_id' in json.dumps(schema)
    print('Identified-user metric selection: passed (8 routes)', flush=True)


if __name__ == '__main__':
    main(verify=verify_user_selection)
