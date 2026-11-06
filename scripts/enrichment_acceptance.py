"""Public producer/reporting workflow and address-privacy proof for EP-33."""
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

EDGE = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130.0 Safari/537.36 Edg/130.0'
ADDRESSES = ('81.2.69.160', '2001:218::')


def send(base, token, body, agent=EDGE, address=ADDRESSES[0]):
    request = urllib.request.Request(base + '/v1/batch', data=json.dumps(body).encode(),
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                 'User-Agent': agent, 'X-Forwarded-For': address})
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status == 202
        result = json.load(response)
        assert result['accepted'] == len(body) and result['rejected'] == [], result


def event(identifier, session, name='page_view', timestamp='2026-07-01T23:59:00Z', **fields):
    result = dict(eventId=identifier, eventName=name, source='web', sourceService='enrichment-web',
                occurredAt=timestamp, receivedAt='1900-01-01T00:00:00Z',
                userId='enrichment-person', anonymousId='cookie-' + session, sessionId=session,
                url='https://shop.example/entry', properties={'url': 'https://shop.example/entry'},
                context={'bot': False, 'browserFamily': 'producer-spoof', 'countryCode': 'US'}, **fields)
    if name == 'session_start':
        result['properties']['sessionId'] = session
    return result


def query(base, token, endpoint='acquisition', **parameters):
    params = dict(from_='2026-07-01', to='2026-07-03')
    params.update(parameters)
    params['from'] = params.pop('from_')
    path = '/metrics/' + endpoint + '?' + urllib.parse.urlencode(params, doseq=True)
    request = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=5) as response:
        result = json.load(response)
        assert result['metric'] == endpoint
        return result['points']


def eventually(check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise AssertionError('public enrichment projection did not reach the expected answer in 30 seconds')


def verify_enrichment(base, write_key, service_token):
    prefix = 'enrich_' + uuid.uuid4().hex
    population = json.dumps(dict(dimension='source_service', op='eq', value=prefix))
    def report(**parameters):
        extra = parameters.pop('filter', [])
        if isinstance(extra, str):
            extra = [extra]
        return query(base, service_token, filter=[population] + extra, **parameters)
    first = [event(prefix + '_start', prefix, name='session_start', timestamp='2026-07-01T23:58:00Z'),
             event(prefix + '_first', prefix, utmSource='facebook', utmMedium='cpc')]
    for value in first:
        value['sourceService'] = prefix
    send(base, write_key, first)
    # The first accepted request context wins, even if a delivery retry differs.
    send(base, write_key, first, agent='Mozilla/5.0 Chrome/130.0', address=ADDRESSES[1])
    later = event(prefix + '_later', prefix, timestamp='2026-07-02T00:02:00Z', utmMedium='email')
    later['sourceService'] = prefix
    later['url'] = 'https://other.example/later'
    later['properties']['url'] = later['url']
    send(base, write_key, [later], agent='Mozilla/5.0 Chrome/130.0', address=ADDRESSES[1])
    bot = event(prefix + '_bot', prefix + '_bot')
    bot['userId'] = 'enrichment-bot'
    bot['sourceService'] = prefix
    send(base, write_key, [bot], agent='Googlebot/2.1')
    expected = [{'bucket': '2026-07-01', 'group': {'channel': 'paid_social', 'browser_family': 'edge'}, 'value': 1}]
    eventually(lambda: report(groupBy='channel,browser_family') == expected)
    eventually(lambda: sum(point['value'] for point in report(includeBots='true')) == 2)
    assert sum(point['value'] for point in report(measure='users')) == 1
    assert report(from_='2026-07-02') == [], 'session was truncated/reassigned across midnight'
    assert report(groupBy='country_code') == [
        {'bucket': '2026-07-01', 'group': {'country_code': 'GB'}, 'value': 1}]
    changed_country = json.dumps(dict(dimension='country_code', op='eq', value='JP'))
    assert report(filter=changed_country) == [], 'later country replaced first-touch country'
    # Session count and attribution share one complete retained projection.
    selected = report(endpoint='sessions', groupBy='entry_page,exit_page')
    assert selected == [{'bucket': '2026-07-01', 'group': {'entry_page': '/entry', 'exit_page': '/later'}, 'value': 1}], selected
    assert sum(point['value'] for point in report(endpoint='sessions', measure='average_duration_seconds')) == 240
    assert sum(point['value'] for point in report(endpoint='sessions', measure='bounce_rate')) == 0
    assert sum(point['value'] for point in report(endpoint='sessions', includeBots='true')) == 2
    assert sum(point['value'] for point in report(endpoint='sessions', from_='2026-07-02')) == 0
    bounce = [event(prefix + '_bounce_page', prefix + '_bounce', timestamp='2026-07-02T10:00:00Z'),
              event(prefix + '_bounce_leave', prefix + '_bounce', name='page_leave', timestamp='2026-07-02T10:01:00Z')]
    for value in bounce:
        value['sourceService'] = prefix
        value['url'] = 'https://shop.example/bounce'
        value['properties'] = {'url': value['url']} if value['eventName'] == 'page_view' else {'durationMs': 60000}
    send(base, write_key, bounce)
    bounce_filter = json.dumps(dict(dimension='entry_page', op='eq', value='/bounce'))
    eventually(lambda: sum(point['value'] for point in report(endpoint='sessions', filter=bounce_filter)) == 1)
    assert sum(point['value'] for point in report(endpoint='sessions', filter=bounce_filter, measure='bounce_rate')) == 1
    assert sum(point['value'] for point in report(endpoint='sessions', filter=bounce_filter, measure='average_duration_seconds')) == 60
    send(base, write_key, bounce)
    assert sum(point['value'] for point in report(endpoint='sessions', filter=bounce_filter, measure='bounce_rate')) == 1
    for measure, expected_value in [('count', 2), ('bounce_rate', .5), ('average_duration_seconds', 150)]:
        whole = report(endpoint='sessions', timeGrain='none', measure=measure)
        assert whole == [{'bucket': None, 'group': {}, 'value': expected_value}], whole
    selected = report(timeGrain='none', groupBy='entry_page,exit_page')
    assert len(selected) == 2 and all(point['bucket'] is None for point in selected), selected
    assert report(timeGrain='none', from_='2026-07-02', filter='entry_page:eq:/entry') == []
    print('EP-34 public workflow: cross-midnight counts, entry/exit, bots, positive-duration lifecycle bounce and replay passed.', flush=True)
    verify_acquisition_conversions(base, write_key, service_token)
    verify_ai_channels(base, write_key, service_token)
    print('EP-33 public workflow: existing event JSON, retries, first-touch/device/country, bots and exact users passed.', flush=True)


def verify_ai_channels(base, write_key, service_token):
    prefix = 'ai_channels_' + uuid.uuid4().hex
    population = json.dumps(dict(dimension='source_service', op='eq', value=prefix))
    fixtures = []
    for index, host in enumerate(('chatgpt.com', 'perplexity.ai', 'claude.ai',
                                  'gemini.google.com', 'copilot.microsoft.com',
                                  None, 'www.google.com', 'chatgpt.com')):
        identifier = prefix + '_' + str(index)
        value = event(identifier, identifier)
        value['sourceService'] = prefix
        if host:
            value['referrer'] = 'https://' + host + '/'
        else:
            value['url'] = 'https://shop.example/entry?utm_source=chatgpt.com'
            value['properties']['url'] = value['url']
        if index == 7:
            value['utmMedium'] = 'cpc'
        fixtures.append(value)
    def counts():
        return {point['group']['channel']: point['value']
                for point in query(base, service_token, groupBy='channel', filter=population)}
    expected = {'ai_assistant': 6, 'organic_search': 1, 'paid_search': 1}
    # The packaged perimeter uses a 4 KiB request cap; keep fixtures in small batches.
    for start in range(0, len(fixtures), 2):
        send(base, write_key, fixtures[start:start + 2])
    eventually(lambda: counts() == expected)
    for start in range(0, len(fixtures), 2):
        send(base, write_key, fixtures[start:start + 2])
    assert counts() == expected, 'identical delivery changed AI-channel session counts'
    print('EP-58 AI-channel workflow: six assistant sessions, organic/paid precedence and identical retries passed.', flush=True)


def verify_country_disabled(base, write_key, service_token):
    prefix = 'no_geo_' + uuid.uuid4().hex
    value = event(prefix, prefix)
    value['sourceService'] = 'geo-default-off'
    send(base, write_key, [value])
    population = json.dumps(dict(dimension='source_service', op='eq', value='geo-default-off'))
    expected = [{'bucket': '2026-07-01', 'group': {'country_code': None}, 'value': 1}]
    eventually(lambda: query(base, service_token, groupBy='country_code', filter=population) == expected)
    print('EP-33 packaged default: geography off, spoofed body/header country ignored, normal ingest/reporting passed.', flush=True)


def verify_acquisition_conversions(base, write_key, service_token):
    prefix = 'acq_conversion_' + uuid.uuid4().hex
    population = json.dumps(dict(dimension='source_service', op='eq', value=prefix))
    fixtures = []
    for person, hour, channel in [('a', '09', 'organic_search'), ('b', '10', 'organic_search'), ('c', '11', 'email')]:
        value = event(prefix + '_' + person, prefix + '_' + person,
                      timestamp='2026-07-01T' + hour + ':00:00Z')
        value['sourceService'] = prefix
        value['userId'] = prefix + '_' + person
        value['anonymousId'] = prefix + '_cookie_' + person
        if person == 'a':
            del value['userId']
        if channel == 'organic_search':
            value['referrer'] = 'https://www.google.com/'
        else:
            value['utmMedium'] = 'email'
        fixtures.append(value)
    alias = event(prefix + '_alias', '', name='alias', timestamp='2026-07-01T09:01:00Z')
    alias.update(source='service', sourceService=prefix + '_identity', userId=prefix + '_a',
                 anonymousId=prefix + '_cookie_a',
                 properties={'previousId': prefix + '_cookie_a', 'newId': prefix + '_a'})
    fixtures.append(alias)
    for person, timestamp in [('a', '2026-07-02T08:00:00Z'), ('c', '2026-07-01T12:00:00Z')]:
        value = event(prefix + '_convert_' + person, '', name=('signup_completed' if person == 'a' else 'payment_completed'), timestamp=timestamp)
        value.update(source='service', sourceService=prefix + '_backend', userId=prefix + '_' + person,
                     properties=({} if person == 'a' else {'amount': 1}))
        del value['anonymousId']
        del value['sessionId']
        fixtures.append(value)
    returning = event(prefix + '_return', prefix + '_return', timestamp='2026-07-02T09:00:00Z', utmMedium='email')
    returning.update(sourceService=prefix, userId=prefix + '_a', anonymousId=prefix + '_cookie_a')
    fixtures.append(returning)
    for value in fixtures:
        send(base, write_key, [value])
    def report(measure, **extra):
        return query(base, service_token, filter=population, measure=measure,
                     conversionEvents=' signup_completed , payment_completed , signup_completed ', **extra)
    def expected(organic, bucket='2026-07-01'):
        return [{'bucket': bucket, 'group': {'channel': 'email'}, 'value': 1},
                {'bucket': bucket, 'group': {'channel': 'organic_search'}, 'value': organic}]
    eventually(lambda: report('converted_users') == expected(1))
    assert report('conversion_rate') == expected(.5)
    assert report('converted_users', timeGrain='none') == expected(1, None)
    assert report('conversion_rate', timeGrain='none') == expected(.5, None)
    # Single-name requests and the exact raw list bound run through the real handler.
    assert query(base, service_token, filter=population, measure='converted_users',
                 conversionEvents='signup_completed') == [
                     {'bucket': '2026-07-01', 'group': {'channel': 'email'}, 'value': 0},
                     {'bucket': '2026-07-01', 'group': {'channel': 'organic_search'}, 'value': 1}]
    assert query(base, service_token, filter=population, measure='conversion_rate',
                 conversionEvents=','.join(['signup_completed', 'payment_completed'] * 10)) == expected(.5)
    for value in reversed(fixtures):
        send(base, write_key, [value])
    assert report('converted_users') == expected(1)
    invalid = [
        ('measure=converted_users', 'invalid_conversion_events'),
        ('measure=conversion_rate&conversionEvents=', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=a,,b', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=,a', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=a,', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=bad%27name', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=' + 'a' * 129, 'invalid_conversion_events'),
        ('measure=conversion_rate&conversionEvents=' + ','.join(['a'] * 21), 'invalid_conversion_events'),
        ('measure=sessions&conversionEvents=a', 'invalid_conversion_events'),
        ('measure=users&conversionEvents=a', 'invalid_conversion_events'),
        ('measure=converted_users&conversionEvents=a&conversionEvents=b', 'invalid_query_parameter'),
        ('measure=converted_users&conversionEvents', 'invalid_query_parameter')]
    for controls, code in invalid:
        request = urllib.request.Request(base + '/metrics/acquisition?from=2026-07-01&to=2026-07-03&' + controls,
                                         headers={'Authorization': 'Bearer ' + service_token})
        try:
            urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            result = json.load(error)
            assert error.code == 400 and result['code'] == code, result
        else:
            raise AssertionError('invalid acquisition controls succeeded: ' + controls)
    print('EP-56 public workflow: anonymous alias, backend conversion, first-session counts/rates, whole range and replay passed.', flush=True)
