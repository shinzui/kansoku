"""IR-8 public site-health contracts and independently expected report points."""
import json
import math
import urllib.error
import urllib.parse
import urllib.request
import uuid

from enrichment_acceptance import event, eventually, send


def verify_site_health(base, write_key, token, other_token):
    prefix = 'health_' + uuid.uuid4().hex
    dates = {'from': '2026-07-01', 'to': '2026-07-03', 'timeGrain': 'day'}

    def api(path, body=None, credential=token, expected=200, **params):
        url = base + path + ('?' + urllib.parse.urlencode(params, doseq=True) if params else '')
        request = urllib.request.Request(
            url, data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': 'Bearer ' + credential, 'Content-Type': 'application/json'})
        try:
            response = urllib.request.urlopen(request, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            value = json.load(response)
            assert response.code == expected, (path, response.code, value)
            return value

    def row(suffix, name, props, route='/checkout', day='2026-07-01', user='A', source=prefix, session=None):
        result = event(prefix + suffix, session or prefix + suffix, name=name, timestamp=day+'T12:00:00Z')
        result.update(sourceService=source, userId=prefix+user, properties=props,
                      schemaVersion=1, url='https://shop.example'+route)
        return result

    def deliver(credential, rows):
        # The packaged acceptance server deliberately caps request bodies at 4 KiB.
        for offset in range(0, len(rows), 3):
            send(base, credential, rows[offset:offset+3])

    def points(endpoint, source=prefix, filters=(), **params):
        options = dict(dates, filter=['source_service:eq:'+source, *filters])
        options.update(params)
        return api('/metrics/'+endpoint, **options)['points']

    def indexed(values):
        result = {}
        for point in values:
            key = (point['bucket'], tuple(sorted(point['group'].items())))
            assert key not in result, values
            result[key] = point['value']
        return result

    def key(day, **groups):
        return (day, tuple(sorted(groups.items())))

    def matches(actual, expected):
        actual = indexed(actual)
        return actual.keys() == expected.keys() and all(
            math.isclose(actual[k], v, rel_tol=0, abs_tol=1e-9) for k, v in expected.items())

    # Check the served publication as well as the generated-artifact golden test.
    catalog = api('/v1/schemas')
    assert catalog['catalogVersion'] == 5
    errors = catalog['events']['client_error']['versions']
    assert [schema['version'] for schema in errors] == [1]
    properties = {p['name']: p for p in errors[0]['properties']}
    for name, bound in [('message', 256), ('type', 128)]:
        assert properties[name]['type'] == 'string' and properties[name]['required']
        assert properties[name]['minLength'] == 1 and properties[name]['maxLength'] == bound
    assert properties['handled']['type'] == 'bool' and properties['handled']['required']
    assert 'do not send stack traces or personal data' in errors[0]['note']
    vitals = catalog['events']['web_vital']['versions']
    assert [schema['version'] for schema in vitals] == [1]
    properties = {p['name']: p for p in vitals[0]['properties']}
    assert properties['metric']['pattern'] == '^(LCP|INP|CLS|FCP|TTFB)$' and properties['metric']['required']
    assert properties['value']['minimum'] == 0 and properties['value']['type'] == 'number' and properties['value']['required']

    # First prove declaration, extraction, native percentile, and result decoding together.
    probe_source = prefix+'_probe'
    probe = row('probe', 'web_vital', {'metric': 'LCP', 'value': 10}, source=probe_source)
    api('/v1/events', probe, credential=write_key, expected=202)
    expected_probe = {key('2026-07-01', **{'prop:metric': 'LCP', 'route': '/checkout'}): 10}
    eventually(lambda: matches(points('custom', source=probe_source, events='web_vital',
        aggregation='percentile', property='value', quantile=.75, groupBy='prop:metric,route'), expected_probe))
    invalid = row('invalid', 'web_vital', {'metric': 'FID', 'value': 1}, source=prefix+'_rejected')
    assert api('/v1/events', invalid, credential=write_key, expected=400)['code'] == 'validation_failed'
    sibling = row('sibling', 'web_vital', {'metric': 'CLS', 'value': 0}, source=prefix+'_rejected')
    ack = api('/v1/batch', [sibling, invalid], credential=write_key, expected=202)
    assert ack['accepted'] == 1 and [rejection['index'] for rejection in ack['rejected']] == [1], ack
    assert ack['rejected'][0]['eventId'] == invalid['eventId']

    message = 'Cannot read property'
    rejection = 'Promise rejected'
    rows = []
    for index, (route, user, label, category, handled) in enumerate([
        ('/checkout', 'A', message, 'TypeError', False),
        ('/checkout', 'A', message, 'TypeError', True),
        ('/checkout', 'B', rejection, 'UnhandledRejection', False),
        ('/pricing', 'A', message, 'TypeError', False),
    ]):
        rows.append(row('error'+str(index), 'client_error', {'message': label, 'type': category, 'handled': handled}, route, user=user))
    rows.append(row('activity', 'feature_used', {'feature': 'checkout'}))
    metrics = ['LCP', 'INP', 'CLS', 'FCP', 'TTFB']
    percentile_expected, count_expected = {}, {}
    for route, multiplier in [('/checkout', 1), ('/pricing', 10)]:
        for day, samples in [('2026-07-01', [10, 20, 30, 40]), ('2026-07-02', [50])]:
            for index, sample in enumerate(samples):
                view = day+route+str(index)
                session = prefix+view
                rows.append(row(view+'page', 'page_view', {'url': 'https://shop.example'+route}, route, day, session=session))
                for metric in metrics:
                    # Day two is a singleton 50ms / .05 CLS on each page.
                    value = sample * (multiplier if day == '2026-07-01' else 1) / (1000 if metric == 'CLS' else 1)
                    rows.append(row(view+metric, 'web_vital', {'metric': metric, 'value': value}, route, day, session=session))
            for metric in metrics:
                group = key(day, **{'prop:metric': metric, 'route': route})
                percentile_expected[group] = (32.5*multiplier if day == '2026-07-01' else 50) / (1000 if metric == 'CLS' else 1)
                count_expected[group] = len(samples)
    deliver(write_key, rows)
    error_filter = ['event_name:eq:client_error']
    vital_options = dict(events='web_vital', groupBy='prop:metric,route', filters=['prop:value:set'])
    eventually(lambda: matches(points('events', timeGrain='none'), {key(None): len(rows)}))
    eventually(lambda: matches(points('custom', aggregation='count', **vital_options), count_expected))

    def verify_reports():
        assert matches(points('events', filters=error_filter, timeGrain='none'), {key(None): 4})
        assert matches(points('events', filters=error_filter, groupBy='route'), {
            key('2026-07-01', route='/checkout'): 3, key('2026-07-01', route='/pricing'): 1})
        assert matches(points('events', filters=error_filter, groupBy='prop:message'), {
            key('2026-07-01', **{'prop:message': message}): 3, key('2026-07-01', **{'prop:message': rejection}): 1})
        assert matches(points('events', filters=error_filter, groupBy='route,prop:message'), {
            key('2026-07-01', **{'route': '/checkout', 'prop:message': message}): 2,
            key('2026-07-01', **{'route': '/checkout', 'prop:message': rejection}): 1,
            key('2026-07-01', **{'route': '/pricing', 'prop:message': message}): 1})
        assert matches(points('users', filters=error_filter, includeBots='true', timeGrain='none'), {key(None): 2})
        assert matches(points('users', filters=error_filter, includeBots='true'), {key('2026-07-01'): 2})
        assert matches(points('users', filters=error_filter, includeBots='true', groupBy='route'), {
            key('2026-07-01', route='/checkout'): 2, key('2026-07-01', route='/pricing'): 1})
        assert matches(points('events', filters=error_filter+['prop:handled:eq:false']), {key('2026-07-01'): 3})
        assert matches(points('events', filters=error_filter+['prop:message:eq:'+message]), {key('2026-07-01'): 3})
        assert matches(points('custom', aggregation='count', **vital_options), count_expected)
        assert matches(points('custom', aggregation='percentile', property='value', quantile=.75, **vital_options), percentile_expected)
        lcp_options = dict(vital_options, filters=['prop:value:set', 'prop:metric:eq:LCP'])
        assert matches(points('custom', aggregation='percentile', property='value', quantile=.75, **lcp_options),
                       {k: v for k, v in percentile_expected.items() if dict(k[1])['prop:metric'] == 'LCP'})

    verify_reports()
    deliver(write_key, rows)
    foreign = [dict(item, eventId=item['eventId']+'_foreign', userId=prefix+'foreign',
                    properties=(dict(item['properties'], value=1e9) if item['eventName'] == 'web_vital' else item['properties']))
               for item in rows if item['eventName'] in ('web_vital', 'client_error')]
    deliver(other_token, foreign)
    # Wait for foreign ingestion too, so account-isolation assertions cannot pass early.
    eventually(lambda: sum(point['value'] for point in api('/metrics/events', credential=other_token,
        **dates, filter='source_service:eq:'+prefix)['points']) == len(foreign))
    verify_reports()
    print('Site health: published v1 contracts, single/batch rejection, error/affected-user reports, per-page vital p75/sample counts, replay and account isolation passed.', flush=True)
