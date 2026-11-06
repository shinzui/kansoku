#!/usr/bin/env python3
"""Custom metric and OR-filter public roundtrips on owned stores."""
import json
import math
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
from acceptance_resources import OwnedResources
from enrichment_acceptance import event, eventually, send
from cohorts_acceptance import main


def verify_custom_metrics(base, write_key, token, other_token, after_membership=None, env=None, **_):
    prefix = 'custom_' + uuid.uuid4().hex

    def api(path, body=None, method='GET', credential=token, expected=200, **params):
        url = base + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else '')
        request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method,
                                        headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        value = json.load(response)
        assert response.code in (expected if isinstance(expected, tuple) else (expected,)), (path, response.code, value)
        return value

    with OwnedResources(api, token, after_membership) as api:
        rows = []
        for user, amounts in [('A', [2, 4]), ('B', [6])]:
            for i, amount in enumerate(amounts):
                row = event(prefix + user + str(i), prefix + user, name='payment_completed', timestamp='2026-07-01T00:00:01Z')
                row.update(userId=prefix + user, sourceService=prefix, properties={'amount': amount, 'plan': 'pro' if user == 'A' else 'enterprise'})
                rows.append(row)
            row = event(prefix + user + 'feature', prefix + user, name='feature_used', timestamp='2026-07-01T00:00:02Z')
            row.update(userId=prefix + user, sourceService=prefix, properties={'feature': prefix})
            rows.append(row)
        send(base, write_key, rows)
        send(base, write_key, rows)  # Replay cannot change sums or counts.
        foreign = dict(rows[0], eventId=prefix+'foreign', properties={'amount': 1000, 'plan': 'pro'})
        send(base, other_token, [foreign])
        selection = 'source_service:eq:' + prefix
        dates = {'from': '2026-07-01', 'to': '2026-07-02'}

        def metric(**params):
            return api('/metrics/custom', **dict(dates, filter=selection, **params))

        def total(**params):
            return sum(p['value'] for p in metric(**params)['points'])

        eventually(lambda: total(events='payment_completed', aggregation='count') == 3)
        assert total(events='payment_completed,feature_used', aggregation='unique_count') == 2
        assert total(events='payment_completed,feature_used', aggregation='count') == 5
        assert total(events='payment_completed', aggregation='sum', property='amount') == 12
        assert total(events='payment_completed', aggregation='average', property='amount') == 4
        assert total(events='payment_completed', aggregation='sum', property='amount', timeGrain='none') == 12
        assert total(events='payment_completed', aggregation='average', property='amount', timeGrain='none') == 4
        ratio = metric(events='payment_completed', aggregation='ratio', denominatorEvents='feature_used')
        assert len(ratio['points']) == 1 and ratio['points'][0]['bucket'] is None and ratio['points'][0]['value'] == 1
        assert total(events='payment_completed', aggregation='count', denominatorEvents='feature_used', denominatorAggregation='count') == 1.5
        assert total(events='payment_completed', aggregation='sum', property='amount', denominatorEvents='feature_used', denominatorAggregation='count') == 6
        alternative = 'prop:plan:eq:pro|prop:plan:eq:enterprise'
        def filtered(filters):
            return api('/metrics/custom', **dates, events='payment_completed', aggregation='count', filter=[selection] + filters)['points']
        assert sum(p['value'] for p in filtered([alternative])) == sum(sum(p['value'] for p in filtered(['prop:plan:eq:'+plan])) for plan in ['pro','enterprise']) == 3
        assert sum(p['value'] for p in filtered([alternative, 'prop:amount:gt:3'])) == 2

        # Early native/public proof of exact inclusive interpolation and decoding.
        percentile_prefix = prefix + '_percentile'
        percentile_rows = []
        for index, amount in enumerate([10, 20, 30, 40]):
            row = event(percentile_prefix+str(index), percentile_prefix+str(index), name='payment_completed', timestamp='2026-07-01T00:00:01Z')
            row.update(userId=percentile_prefix+str(index), sourceService=percentile_prefix, properties={'amount':amount, 'plan':'pro'})
            percentile_rows.append(row)
        send(base, write_key, percentile_rows)
        def percentile_points(**params):
            options = dict(dates, events='payment_completed', aggregation='percentile', property='amount',
                           quantile=0.75, filter='source_service:eq:'+percentile_prefix)
            options.update(params)
            return api('/metrics/custom', **options)['points']
        eventually(lambda: percentile_points() == [{'bucket':'2026-07-01', 'group':{}, 'value':32.5}])

        definition = dict(name=prefix, description='payments', eventNames=['payment_completed'], aggregation='sum',
                          aggregationProperty='amount', filters=[selection, alternative], groupBy=['prop:plan'], timeGrain='day')
        saved = api('/metric-definitions', definition, 'POST')
        ident = saved['id']
        assert api('/metric-definitions/'+ident)['definition'] == definition
        adhoc = api('/metrics/custom', **dates, events='payment_completed', aggregation='sum', property='amount', groupBy='prop:plan', filter=[selection, alternative])
        assert metric(metric=prefix)['points'] == adhoc['points']
        assert len(metric(metric=prefix, groupBy='source')['points']) == 1
        assert api('/metric-definitions/'+ident, credential=other_token, expected=404)['code'] == 'metric_not_found'
        assert api('/metrics/custom', credential=other_token, expected=404, metric=prefix, **dates)['code'] == 'metric_not_found'
        assert api('/metric-definitions/'+ident, definition, 'PUT', credential=other_token, expected=404)['code'] == 'metric_not_found'
        assert api('/metric-definitions/'+ident, method='DELETE', credential=other_token, expected=404)['code'] == 'metric_not_found'
        assert api('/metric-definitions', definition, 'POST', expected=400)['code'] == 'invalid_metric'
        api('/metric-definitions', definition, 'POST', credential=other_token)
        updated = dict(definition, aggregation='average')
        api('/metric-definitions/'+ident, updated, 'PUT')
        assert sum(p['value'] for p in metric(metric=prefix, groupBy='source')['points']) == 4

        # Independent expected maps: quantiles are never combined across buckets.
        samples_prefix = prefix + '_samples'
        sample_rows = []
        populations = {('2026-07-01','pro'):[10,20,30,40], ('2026-07-01','enterprise'):[-10,0,0,10],
                       ('2026-07-02','pro'):[100], ('2026-07-02','enterprise'):[5,5]}
        for (day, plan), amounts in populations.items():
            for index, amount in enumerate(amounts):
                row = event(samples_prefix+day+plan+str(index), samples_prefix+day+plan+str(index),
                            name='subscription_started', timestamp=day+'T00:00:01Z')
                row.update(sourceService=samples_prefix, properties={'amount':amount, 'plan':plan})
                sample_rows.append(row)
        for index, properties in enumerate([{'plan':'unset'}, {'plan':'pro'}]):
            row = event(samples_prefix+'unset'+str(index), samples_prefix+'unset'+str(index),
                        name='subscription_started', timestamp='2026-07-01T00:00:01Z')
            row.update(sourceService=samples_prefix, properties=properties)
            sample_rows.append(row)
        sample_dates = {'from':'2026-07-01', 'to':'2026-07-03'}
        sample_filters = ['source_service:eq:'+samples_prefix, 'prop:amount:set']
        def sample_metric(aggregation='percentile', **params):
            options = dict(sample_dates, events='subscription_started', aggregation=aggregation, groupBy='prop:plan',
                           filter=sample_filters, timeGrain='day')
            if aggregation == 'percentile':
                options.update(property='amount', quantile=0.75)
            options.update(params)
            return api('/metrics/custom', **options)['points']
        def point_map(points):
            return {(p['bucket'],p['group'].get('prop:plan')):p['value'] for p in points}
        def assert_values(points, expected):
            actual = point_map(points)
            assert actual.keys() == expected.keys(), (actual,expected)
            assert all(math.isclose(actual[key], value, rel_tol=0, abs_tol=1e-9) for key,value in expected.items()), (actual,expected)
        expected_daily = {
            0.5:{('2026-07-01','pro'):25, ('2026-07-01','enterprise'):0, ('2026-07-02','pro'):100, ('2026-07-02','enterprise'):5},
            0.75:{('2026-07-01','pro'):32.5, ('2026-07-01','enterprise'):2.5, ('2026-07-02','pro'):100, ('2026-07-02','enterprise'):5},
            0.95:{('2026-07-01','pro'):38.5, ('2026-07-01','enterprise'):8.5, ('2026-07-02','pro'):100, ('2026-07-02','enterprise'):5}}
        expected_whole = {0.5:{'pro':30,'enterprise':2.5}, 0.75:{'pro':40,'enterprise':5}, 0.95:{'pro':88,'enterprise':8.75}}
        expected_counts = {key:len(values) for key,values in populations.items()}
        for delivery in (sample_rows, list(reversed(sample_rows))):
            for start in range(0, len(delivery), 3):
                send(base, write_key, delivery[start:start+3])
        send(base, other_token, [dict(sample_rows[0], eventId=samples_prefix+'foreign', properties={'amount':10000,'plan':'pro'})])
        eventually(lambda: point_map(sample_metric('count')) == expected_counts)
        for quantile, expected in expected_daily.items():
            points = sample_metric(quantile=quantile)
            assert_values(points, expected)
            assert point_map(sample_metric('count')) == expected_counts
            assert point_map(points).keys() == expected_counts.keys()
            for grain,bucket in [('week','2026-06-29'), ('month','2026-07-01'), ('none',None)]:
                points = sample_metric(quantile=quantile, timeGrain=grain)
                assert_values(points, {(bucket,plan):value for plan,value in expected_whole[quantile].items()})
                assert point_map(sample_metric('count', timeGrain=grain)) == {(bucket,'pro'):5,(bucket,'enterprise'):6}
            assert_values(sample_metric(quantile=quantile, timeGrain='hour'),
                          {(day+' 00:00:00',plan):value for (day,plan),value in expected.items()})
        # Replay invariance after the first result, independently of background merges.
        send(base, write_key, list(reversed(sample_rows)))
        assert_values(sample_metric(), expected_daily[0.75])
        assert point_map(sample_metric('count')) == expected_counts
        assert_values(sample_metric(filter=sample_filters+['prop:plan:eq:enterprise']),
                      {key:value for key,value in expected_daily[0.75].items() if key[1]=='enterprise'})
        for extra in [dict(filter=sample_filters+['prop:plan:eq:absent']),
                      dict(filter=sample_filters+['prop:plan:eq:unset']), dict(**{'from':'2026-07-03','to':'2026-07-04'})]:
            for aggregation in ('percentile','count'):
                assert sample_metric(aggregation, **extra) == []
                assert sample_metric(aggregation, timeGrain='none', **extra) == []
        # Exclusion is intrinsic to percentile as well as the explicit pairing filter.
        assert_values(sample_metric(filter=sample_filters[:1]), expected_daily[0.75])

        for bad in (None, '0', '1', '-0.1', '1.1'):
            args = dict(dates, events='payment_completed', aggregation='percentile', property='amount')
            if bad is not None:
                args['quantile'] = bad
            assert api('/metrics/custom', expected=400, **args)['code'] == 'invalid_metric'
        for kind in ('count','unique_count','sum','average'):
            assert api('/metrics/custom', **dates, events='payment_completed', aggregation=kind, quantile=0.75, expected=400)['code'] == 'invalid_metric'

        # Saved percentile CRUD uses the same population and immutable quantile.
        percentile_def = dict(definition, name=percentile_prefix, aggregation='percentile', quantile=0.75,
                              filters=['source_service:eq:'+percentile_prefix, 'prop:amount:set'])
        percentile_saved = api('/metric-definitions', percentile_def, 'POST')
        percentile_id = percentile_saved['id']
        assert percentile_saved['definition'] == percentile_def
        assert api('/metric-definitions/'+percentile_id)['definition'] == percentile_def
        percentile_adhoc = percentile_points(groupBy='prop:plan')
        assert api('/metrics/custom', **dates, metric=percentile_prefix)['points'] == percentile_adhoc
        assert api('/metrics/custom', **dates, metric=percentile_prefix, groupBy='source', timeGrain='none')['points'] == percentile_points(groupBy='source', timeGrain='none')
        assert api('/metrics/custom', **dates, metric=percentile_prefix, quantile=0.95, expected=400)['code'] == 'invalid_metric'
        for method in ('GET', 'PUT', 'DELETE'):
            assert api('/metric-definitions/'+percentile_id, percentile_def if method == 'PUT' else None,
                       method, credential=other_token, expected=404)['code'] == 'metric_not_found'
        assert api('/metrics/custom', **dates, metric=percentile_prefix, credential=other_token, expected=404)['code'] == 'metric_not_found'
        for changes in [dict(quantile=None), dict(quantile=0), dict(quantile=1), dict(quantile=-0.5), dict(quantile=1.5),
                        dict(aggregation='sum'), dict(aggregationProperty='plan')]:
            invalid = dict(percentile_def, **changes)
            assert api('/metric-definitions', invalid, 'POST', expected=400)['code'] == 'invalid_metric'
            assert api('/metric-definitions/'+percentile_id, invalid, 'PUT', expected=400)['code'] == 'invalid_metric'
        scalar = dict(percentile_def, groupBy=[], timeGrain=None)
        count_component = dict(scalar, aggregation='count', aggregationProperty=None)
        count_component.pop('quantile')
        for numerator, denominator in [(scalar,count_component), (count_component,scalar)]:
            invalid_ratio = dict(name=prefix+'invalid_ratio', description=None, numerator=numerator, denominator=denominator)
            assert api('/metric-definitions', invalid_ratio, 'POST', expected=400)['code'] == 'invalid_metric'
        updated_percentile = dict(percentile_def, quantile=0.95)
        assert api('/metric-definitions/'+percentile_id, updated_percentile, 'PUT')['definition'] == updated_percentile
        actual = api('/metrics/custom', **dates, metric=percentile_prefix)['points']
        assert actual == percentile_points(quantile=0.95, groupBy='prop:plan')
        assert math.isclose(actual[0]['value'], 38.5, abs_tol=1e-9)
        if env is not None:
            # Corrupt only the explicitly owned row to prove loaded-state validation.
            uuid.UUID(percentile_id)
            subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                            "UPDATE kansoku.metric_definitions SET definition=jsonb_set(definition,'{quantile}','1'::jsonb) WHERE id='"+percentile_id+"'::uuid"],
                           env=env, check=True, capture_output=True, text=True, timeout=10)
            assert api('/metrics/custom', **dates, metric=percentile_prefix, expected=400)['code'] == 'invalid_metric'
            api('/metric-definitions/'+percentile_id, updated_percentile, 'PUT')
        api('/metric-definitions/'+percentile_id, method='DELETE')
        assert api('/metrics/custom', **dates, metric=percentile_prefix, expected=404)['code'] == 'metric_not_found'

        # Whole-range mode counts returning subjects once across a month boundary.
        whole_prefix = prefix + '_range'
        period = {'from': '2026-06-30', 'to': '2026-07-30'}
        range_rows = []
        for day, count in [('2026-06-30', 1), ('2026-07-01', 3)]:
            for i in range(count):
                row = event(whole_prefix+day+str(i), whole_prefix+day+str(i),
                            timestamp=day+'T00:00:00Z')
                row.update(userId=whole_prefix, sourceService=whole_prefix)
                range_rows.append(row)
        send(base, write_key, range_rows)
        send(base, write_key, list(reversed(range_rows)))
        send(base, other_token, [dict(range_rows[0], eventId=whole_prefix+'foreign')])
        def ranged(route, **params):
            return api('/metrics/'+route, **period, filter='source_service:eq:'+whole_prefix, **params)['points']
        eventually(lambda: sum(p['value'] for p in ranged('events')) == 4)
        for route, params, expected in [
                ('users', {'window':'calendar'}, 1),
                ('custom', {'events':'page_view','aggregation':'unique_count'}, 1),
                ('acquisition', {'measure':'users'}, 1),
                ('events', {}, 4), ('page-views', {}, 4),
                ('sessions', {'measure':'count'}, 4),
                ('sessions', {'measure':'bounce_rate'}, 1),
                ('sessions', {'measure':'average_duration_seconds'}, 0),
                ('acquisition', {'measure':'sessions'}, 4)]:
            points = ranged(route, timeGrain='none', **params)
            assert len(points) == 1 and points[0]['bucket'] is None and points[0]['value'] == expected, (route, points)
            legacy = ranged(route, **params)
            assert all(p['bucket'] is not None for p in legacy), (route, legacy)
            if route in ('users', 'custom', 'acquisition'):
                assert len(legacy) == 2, (route, legacy)
        # Independent sets define expected per-route identities across thirty days.
        from datetime import date, timedelta
        matrix = whole_prefix + '_matrix'
        matrix_rows, expected_sets = [], {}
        for offset in range(30):
            day = date(2026, 6, 30) + timedelta(days=offset)
            subject = matrix + str(offset % 2)
            route = '/a' if offset % 3 else '/b'
            row = event(matrix+str(offset), matrix+'session'+str(offset), timestamp=day.isoformat()+'T00:00:00Z')
            row.update(userId=subject, anonymousId=matrix+'cookie'+str(offset % 2), sourceService=matrix,
                       url='https://shop.example'+route, properties={'url':'https://shop.example'+route})
            if offset < 2:
                row['userId'] = None  # Later evidence resolves these two cookies.
            matrix_rows.append(row)
            expected_sets.setdefault(route, set()).add(subject)
        for index in range(2):
            profile = event(matrix+'identify'+str(index), matrix+'profile'+str(index), name='identify', timestamp='2026-07-29T00:00:00Z')
            profile.update(userId=matrix+str(index), anonymousId=matrix+'cookie'+str(index), sourceService=matrix,
                           schemaVersion=2, properties={'plan':'pro' if index == 0 else ''})
            matrix_rows.append(profile)
        for delivery in (matrix_rows, list(reversed(matrix_rows))):
            for offset in range(0, len(delivery), 3):
                send(base, write_key, delivery[offset:offset+3])
        def matrix_query(route, **params):
            return api('/metrics/'+route, **period, filter=['source_service:eq:'+matrix, 'entry_page:set' if route == 'acquisition' else 'event_name:eq:page_view'], timeGrain='none', **params)['points']
        eventually(lambda: sum(p['value'] for p in matrix_query('events')) == 30)
        eventually(lambda: sum(p['value'] for p in matrix_query('users')) == 2)
        for route, params, dimension in [('users', {}, 'route'), ('custom', {'events':'page_view','aggregation':'unique_count'}, 'route'),
                                          ('acquisition', {'measure':'users'}, 'entry_page')]:
            points = matrix_query(route, groupBy=dimension, **params)
            actual = {p['group'][dimension]: p['value'] for p in points}
            assert actual == {key:len(subjects) for key, subjects in expected_sets.items()}, (route, points)
            assert all(p['bucket'] is None for p in points)
            assert sum(actual.values()) == 4  # Distinct group counts intentionally overlap.
        for route, params in [('users', {}), ('custom', {'events':'page_view','aggregation':'unique_count'}), ('acquisition', {'measure':'users'})]:
            points = matrix_query(route, groupBy='user:plan', **params)
            assert {p['group']['user:plan']:p['value'] for p in points} == {'pro':1, '':1}, (route, points)
        for route, params in [('events', {}), ('page-views', {}), ('users', {}), ('custom', {'events':'page_view','aggregation':'count'}), ('acquisition', {})]:
            points = api('/metrics/'+route, **period, filter='source_service:eq:'+matrix+'missing', timeGrain='none', **params)['points']
            assert points == [], (route, points)
        for measure in ('count', 'bounce_rate', 'average_duration_seconds'):
            points = api('/metrics/sessions', **period, filter='source_service:eq:'+matrix+'missing', timeGrain='none', measure=measure)['points']
            assert points == [{'bucket':None, 'group':{}, 'value':0}], points

        # Boundaries and retained-session selection use the full session start.
        assert sum(p['value'] for p in api('/metrics/events', **period, timeGrain='none',
                   filter=['source_service:eq:'+matrix, 'event_name:eq:page_view'])['points']) == 30
        tail = api('/metrics/users', **{'from':'2026-07-29','to':'2026-07-30'},
                   timeGrain='none', filter='source_service:eq:'+matrix)['points']
        assert len(tail) == 1 and tail[0]['value'] == 1, tail
        excluded = api('/metrics/events', **{'from':'2026-06-29','to':'2026-06-30'},
                       timeGrain='none', filter='source_service:eq:'+matrix)['points']
        assert excluded == [], excluded
        for dimension in ('channel,country_code', 'route,device_class'):
            points = matrix_query('users', groupBy=dimension)
            assert len(points) == (1 if dimension == 'channel,country_code' else 2), points
            assert all(p['bucket'] is None and p['value'] == 2 for p in points), points
        api('/metrics/custom', **period, events='page_view', aggregation='count', includeBots='true', timeGrain='none', expected=400)

        numeric_rows = []
        for index, amount in enumerate((2, 4, 10, None)):
            row = event(matrix+'number'+str(index), matrix+'number'+str(index), name='subscription_started',
                        timestamp=('2026-06-30' if index < 2 else '2026-07-01')+'T00:00:00Z')
            row.update(sourceService=matrix+'numeric', properties={'plan':'pro'})
            if amount is not None:
                row['properties']['amount'] = amount
            numeric_rows.append(row)
        send(base, write_key, numeric_rows)
        def numeric(aggregation):
            return api('/metrics/custom', **period, events='subscription_started', aggregation=aggregation,
                       property='amount', filter='source_service:eq:'+matrix+'numeric', timeGrain='none')['points']
        eventually(lambda: numeric('sum') == [{'bucket':None, 'group':{}, 'value':16}])
        assert numeric('average') == [{'bucket':None, 'group':{}, 'value':16/3}]

        for value in ('day', 'none', None):
            saved_range = dict(definition, name=whole_prefix+str(value), eventNames=['page_view'], aggregation='unique_count',
                               aggregationProperty=None, filters=['source_service:eq:'+whole_prefix], groupBy=[], timeGrain=value)
            post_body = {key:value for key,value in saved_range.items() if key != 'timeGrain'} if value is None else saved_range
            record = api('/metric-definitions', post_body, 'POST')
            assert api('/metric-definitions/'+record['id'])['definition'] == saved_range
            points = api('/metrics/custom', **period, metric=saved_range['name'], timeGrain='none')['points']
            assert len(points) == 1 and points[0]['value'] == 1 and points[0]['bucket'] is None
            points = api('/metrics/custom', **period, metric=saved_range['name'], timeGrain='day')['points']
            assert len(points) == 2 and sum(p['value'] for p in points) == 2
            saved_range['timeGrain'] = 'none'
            api('/metric-definitions/'+record['id'], saved_range, 'PUT')
            assert api('/metrics/custom', **period, metric=saved_range['name'])['points'][0]['bucket'] is None
        for route in ('feature-adoption', 'revenue', 'conversion', 'stickiness', 'lifecycle', 'retention', 'experiments'):
            api('/metrics/'+route, **period, timeGrain='none', expected=400)
        api('/metrics/users', **period, window='rolling7', timeGrain='none', expected=400)
        api('/metrics/custom', **period, events='page_view', aggregation='ratio', denominatorEvents='page_view', timeGrain='none', expected=400)

        def component(aggregation='count', filters=None):
            return dict(definition, name='component', aggregation=aggregation, aggregationProperty=None,
                        filters=filters or [], groupBy=[], timeGrain=None)
        rate = dict(name=prefix+'rate', description=None, numerator=component(filters=['prop:plan:eq:pro']), denominator=component())
        api('/metric-definitions', rate, 'POST')
        assert total(metric=rate['name']) == 2/3
        cohort = api('/cohorts', dict(name=prefix,kind='static'), 'POST')
        api('/cohorts/'+cohort['id']+'/members',dict(userIds=[prefix+'A']),'PUT')
        cohort_def = dict(definition,name=prefix+'cohort',filters=[selection,'cohort:eq:'+cohort['id']])
        api('/metric-definitions',cohort_def,'POST')
        assert total(metric=cohort_def['name']) == 6
        assert total(metric=cohort_def['name'], timeGrain='none') == 6
        # Cohort OR terms must be discovered and loaded on either side.
        rate['numerator']['filters'] = ['cohort:eq:'+cohort['id']+'|prop:plan:eq:enterprise']
        rate['name'] += '_cohort'
        api('/metric-definitions',rate,'POST')
        assert total(metric=rate['name']) == 1
        # Saved trait filters must select the resolved source even for a count metric.
        trait = event(prefix+'trait',prefix+'A',name='identify',timestamp='2026-07-01T00:00:03Z')
        trait.update(userId=prefix+'A',sourceService=prefix,schemaVersion=2,properties={'plan':'pro'})
        send(base,write_key,[trait])
        trait_def = dict(definition,name=prefix+'trait',filters=[selection,'user:plan:eq:pro'])
        api('/metric-definitions',trait_def,'POST')
        eventually(lambda: total(metric=trait_def['name']) == 6)

        for extra_filters, grouping in [(['cohort:eq:'+cohort['id']], 'prop:plan'),
                                         ([], 'cohort:'+cohort['id']), (['user:plan:eq:pro'], 'source')]:
            selected_percentile = dict(definition, name=prefix+'p75_selected', aggregation='percentile', quantile=0.75,
                                       filters=[selection, 'prop:amount:set']+extra_filters, groupBy=[grouping])
            record = api('/metric-definitions', selected_percentile, 'POST')
            expected = api('/metrics/custom', **dates, events='payment_completed', aggregation='percentile', property='amount',
                           quantile=0.75, filter=selected_percentile['filters'], groupBy=grouping)['points']
            assert api('/metrics/custom', **dates, metric=selected_percentile['name'])['points'] == expected
            assert expected
            counts = api('/metrics/custom', **dates, events='payment_completed', aggregation='count',
                         filter=selected_percentile['filters'], groupBy=grouping)['points']
            assert [(p['bucket'],p['group']) for p in counts] == [(p['bucket'],p['group']) for p in expected]
            assert sum(p['value'] for p in counts) == (3 if not extra_filters else 2)
            api('/metric-definitions/'+record['id'], method='DELETE')

        # Walk UUID keysets both ways in canonical order, without skips or duplicates.
        first = api('/metric-definitions',first=2)
        nodes = list(first['edges'])
        page = first
        while page['pageInfo']['hasNextPage']:
            page = api('/metric-definitions',first=2,after=page['pageInfo']['endCursor'])
            nodes.extend(page['edges'])
        expected_names = {prefix, rate['name'], prefix+'rate', cohort_def['name'], trait_def['name']} | {whole_prefix+str(value) for value in ('day', 'none', None)}
        assert len(nodes) == len(expected_names) and len({e['node']['id'] for e in nodes}) == len(expected_names)
        assert {e['node']['definition']['name'] for e in nodes} == expected_names
        backwards = api('/metric-definitions',last=2)
        reverse_nodes = list(backwards['edges'])
        while backwards['pageInfo']['hasPreviousPage']:
            backwards = api('/metric-definitions',last=2,before=backwards['pageInfo']['startCursor'])
            reverse_nodes = backwards['edges'] + reverse_nodes
        assert reverse_nodes == nodes
        api('/metric-definitions',first=1,after='invalid',expected=400)
        for args in [dict(events='payment_completed',aggregation='sum',property='plan'),
                     dict(events='payment_completed',aggregation='ratio'),
                     dict(metric=prefix,events='payment_completed')]:
            assert api('/metrics/custom',expected=400,**dates,**args)['code']=='invalid_metric'
        assert api('/metrics/custom',expected=400,**dates,events='payment_completed',aggregation='count',filter='|'.join(['source:eq:web']*9))['code']=='invalid_filter'
        assert api('/metrics/custom',expected=400,**dates,events='payment_completed',aggregation='count',filter='source:eq:a|b')['code']=='invalid_filter'
        assert api('/metrics/custom',expected=400,events='payment_completed',aggregation='count',**{'from':'2026-07-02','to':'2026-07-01'})['code']=='invalid_date_range'
        assert api('/metrics/custom',expected=400,**dates,metric=prefix,filter=[selection]*7)['code']=='invalid_filter'
        assert api('/metrics/custom',expected=400,**dates,events='payment_completed',aggregation='ratio',denominatorEvents='feature_used',timeGrain='day')['code']=='invalid_metric'
        assert api('/metric-definitions',dict(definition,name=prefix+'invalid',aggregationProperty='plan'),'POST',expected=400)['code']=='invalid_metric'
        api('/metric-definitions/'+ident,method='DELETE')
        assert api('/metrics/custom',metric=prefix,expected=404,**dates)['code']=='metric_not_found'
        print('Custom metrics: exact p50/p75/p95, numeric sample counts, replay, OR groups, saved CRUD/defaults/validation, cohorts/traits, bidirectional pages and account isolation passed.',flush=True)


if __name__ == '__main__':
    from isolated_clickhouse import isolated_clickhouse, apply_migrations
    from test_support import binary, hspec
    with isolated_clickhouse(block_size=2) as native:
        apply_migrations(native)
        hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Metrics filters native'], env=native)
    main(verify=verify_custom_metrics, pass_environment=True)
