"""Public producer/reporting workflow and address-privacy proof for EP-33."""
import json
import time
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


def query(base, token, **parameters):
    params = dict(from_='2026-07-01', to='2026-07-03')
    params.update(parameters)
    params['from'] = params.pop('from_')
    path = '/metrics/acquisition?' + urllib.parse.urlencode(params, doseq=True)
    request = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=5) as response:
        result = json.load(response)
        assert result['metric'] == 'acquisition'
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
    print('EP-33 public workflow: existing event JSON, retries, first-touch/device/country, bots and exact users passed.', flush=True)


def verify_country_disabled(base, write_key, service_token):
    prefix = 'no_geo_' + uuid.uuid4().hex
    value = event(prefix, prefix)
    value['sourceService'] = 'geo-default-off'
    send(base, write_key, [value])
    population = json.dumps(dict(dimension='source_service', op='eq', value='geo-default-off'))
    expected = [{'bucket': '2026-07-01', 'group': {'country_code': None}, 'value': 1}]
    eventually(lambda: query(base, service_token, groupBy='country_code', filter=population) == expected)
    print('EP-33 packaged default: geography off, spoofed body/header country ignored, normal ingest/reporting passed.', flush=True)
