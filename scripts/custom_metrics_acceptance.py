#!/usr/bin/env python3
"""Custom metric and OR-filter public roundtrips on owned stores."""
import json
import urllib.error
import urllib.parse
import urllib.request
import uuid
from acceptance_resources import OwnedResources
from enrichment_acceptance import event, eventually, send
from cohorts_acceptance import main


def verify_custom_metrics(base, write_key, token, other_token, after_membership=None, **_):
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
        ratio = metric(events='payment_completed', aggregation='ratio', denominatorEvents='feature_used')
        assert len(ratio['points']) == 1 and ratio['points'][0]['bucket'] is None and ratio['points'][0]['value'] == 1
        assert total(events='payment_completed', aggregation='count', denominatorEvents='feature_used', denominatorAggregation='count') == 1.5
        assert total(events='payment_completed', aggregation='sum', property='amount', denominatorEvents='feature_used', denominatorAggregation='count') == 6
        alternative = 'prop:plan:eq:pro|prop:plan:eq:enterprise'
        def filtered(filters):
            return api('/metrics/custom', **dates, events='payment_completed', aggregation='count', filter=[selection] + filters)['points']
        assert sum(p['value'] for p in filtered([alternative])) == sum(sum(p['value'] for p in filtered(['prop:plan:eq:'+plan])) for plan in ['pro','enterprise']) == 3
        assert sum(p['value'] for p in filtered([alternative, 'prop:amount:gt:3'])) == 2

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

        # Walk UUID keysets both ways in canonical order, without skips or duplicates.
        first = api('/metric-definitions',first=2)
        nodes = list(first['edges'])
        page = first
        while page['pageInfo']['hasNextPage']:
            page = api('/metric-definitions',first=2,after=page['pageInfo']['endCursor'])
            nodes.extend(page['edges'])
        assert len(nodes) == 5 and len({e['node']['id'] for e in nodes}) == 5
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
        print('Custom metrics: all aggregations, replay, OR groups, saved defaults, cohorts/traits, CRUD, bidirectional pages and account isolation passed.',flush=True)


if __name__ == '__main__':
    from isolated_clickhouse import isolated_clickhouse, apply_migrations
    from test_support import binary, hspec
    with isolated_clickhouse(block_size=2) as native:
        apply_migrations(native)
        hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Metrics filters native'], env=native)
    main(verify=verify_custom_metrics)
