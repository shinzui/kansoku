"""Public contained-event selection over complete retained web sessions (IR-14)."""
import json
import math
import urllib.request
import uuid

from enrichment_acceptance import event, eventually, query, send


def verify_session_contains(base, write_key, service_token, other_token):
    prefix = 'session_contains_' + uuid.uuid4().hex
    population = 'source_service:eq:' + prefix
    fixtures = []

    def row(label, session, name, stamp, route, channel=None):
        value = event(prefix + '_' + label, prefix + '_' + session, name=name,
                      timestamp='2026-07-01T' + stamp + 'Z')
        value.update(sourceService=prefix, userId=prefix + '_' + session,
                     url='https://shop.example' + route, schemaVersion=1)
        if channel:
            value['utmMedium'] = channel
        value['properties'] = {
            'page_view': {'url': value['url']},
            'page_leave': {'durationMs': 30000},
            'client_error': {'message': 'fixture failure', 'type': 'TypeError', 'handled': False}
        }[name]
        fixtures.append(value)
        return value

    row('a0', 'a', 'page_view', '12:00:00', '/error', 'email')
    row('a1', 'a', 'page_view', '12:00:20', '/second')
    row('a2', 'a', 'client_error', '12:01:00', '/later', 'cpc')
    row('b0', 'b', 'page_view', '13:00:00', '/quiet', 'email')
    row('b1', 'b', 'page_leave', '13:00:30', '/quiet')
    row('c0', 'c', 'page_view', '14:00:00', '/quiet')
    for source in ('service', 'web'):
        value = row('no_session_' + source, 'unused', 'client_error', '15:00:00', '/ignored')
        value['source'] = source
        del value['sessionId']
    # Stay within the packaged acceptance 4 KiB body cap.
    for value in fixtures:
        send(base, write_key, [value])

    def report(token=service_token, **params):
        extra = params.pop('filter', [])
        if isinstance(extra, str):
            extra = [extra]
        return query(base, token, endpoint='sessions', to='2026-07-02', timeGrain='none',
                     filter=[population] + extra, **params)

    def total(**params):
        result = report(**params)
        assert len(result) == 1 and result[0]['bucket'] is None and result[0]['group'] == {}, result
        return result[0]['value']

    def expect(value, **params):
        actual = total(**params)
        assert math.isclose(actual, value, abs_tol=1e-9), (params, actual, value)

    eventually(lambda: total() == 3 and total(containsEvent='client_error') == 1
               and total(containsEvent='page_leave') == 1)
    for names, count, duration, bounce in [(None, 3, 30, 2/3), ('client_error', 1, 60, 0),
                                           ('client_error,page_leave', 2, 45, .5)]:
        selection = {} if names is None else {'containsEvent': names}
        expect(count, **selection)
        expect(duration, measure='average_duration_seconds', **selection)
        expect(bounce, measure='bounce_rate', **selection)
    expect(1, containsEvent=' client_error , client_error ')
    expect(1, containsEvent=','.join(['client_error'] * 20))
    expect(0, containsEvent='absent_event')
    assert report(containsEvent='absent_event', groupBy='entry_page') == []
    assert report(containsEvent='client_error', groupBy='entry_page,channel') == [
        {'bucket': None, 'group': {'entry_page': '/error', 'channel': 'email'}, 'value': 1}]
    assert report(containsEvent='client_error,page_leave', groupBy='entry_page') == [
        {'bucket': None, 'group': {'entry_page': '/error'}, 'value': 1},
        {'bucket': None, 'group': {'entry_page': '/quiet'}, 'value': 1}]
    expect(2, containsEvent='client_error,page_leave', filter='channel:eq:email')
    expect(0, containsEvent='client_error,page_leave', filter='channel:eq:direct')
    assert report(token=other_token, containsEvent='client_error') == [
        {'bucket': None, 'group': {}, 'value': 0}]
    for value in reversed(fixtures):
        send(base, write_key, [value])
    expect(3)
    expect(1, containsEvent='client_error')
    expect(60, containsEvent='client_error', measure='average_duration_seconds')
    with urllib.request.urlopen(base + '/openapi.json', timeout=5) as response:
        operation = json.load(response)['paths']['/metrics/sessions']['get']
    parameters = [p for p in operation['parameters'] if p['name'] == 'containsEvent']
    assert len(parameters) == 1 and parameters[0]['schema']['type'] == 'string', parameters
    assert not parameters[0].get('required', False), parameters
    for phrase in ('any-of', '1..20', '1..128', 'whole sessions'):
        assert phrase in operation['description'], operation['description']
    print('EP-66 public workflow: 3 visits, 1 error visit (33.33%), any-of=2, whole-session duration/bounce, attribution, no-session errors, account isolation, replay and live OpenAPI passed.', flush=True)
