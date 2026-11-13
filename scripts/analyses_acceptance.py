#!/usr/bin/env python3
"""Saved analysis contracts on fresh owned stores and the real HTTP executable."""
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
import json
import urllib.error
import urllib.parse
import urllib.request
from cohorts_acceptance import main


def verifier(base, token):
    def api(path='/analyses', body=None, method='GET', credential=token,
            expected=200, **params):
        url = base + path + ('?' + urllib.parse.urlencode(params) if params else '')
        headers = {'Content-Type': 'application/json'}
        if credential:
            headers['Authorization'] = 'Bearer ' + credential
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            response = urllib.request.urlopen(request, timeout=40)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            value = json.load(response, parse_float=Decimal)
            assert response.status == expected, (method, path, response.status, expected, value)
            if expected >= 400 and 'status' in value:
                assert response.headers.get_content_type() == 'application/problem+json'
                assert value['status'] == expected and not value['retryable']
            elif expected >= 400:
                assert expected == 400 and response.headers.get_content_type() == 'application/json'
            return value
    return api


def envelope(**overrides):
    return dict(dict(name='  Shared 日本語 😀  ', description=None, kind='trends',
                     documentVersion=999999999999999999999999,
                     document={'nested': [None, True, False, 1.25, {'zero': '\0', '雪': '😀'}],
                               'unknownMetric': 'never-executed'}), **overrides)


def parallel(action):
    from threading import Barrier
    gate = Barrier(2)
    def run(_):
        gate.wait(timeout=10)
        return action()
    with ThreadPoolExecutor(max_workers=2) as executor:
        return list(executor.map(run, range(2)))


def verify_analyses(base, write_key, token, other_token, **_):
    api = verifier(base, token)
    owned = {}  # Only IDs created here, with the latest successful revision.
    foreign = {}
    def create(body=None, credential=token):
        value = api(body=body or envelope(), method='POST', credential=credential)
        (owned if credential == token else foreign)[value['id']] = value['revision']
        return value
    def replace(value, body=None, **options):
        result = api('/analyses/' + value['id'], body or dict(envelope(), revision=value['revision']), 'PUT', **options)
        if 'id' in result:
            owned[result['id']] = result['revision']
        return result
    def delete(value):
        assert api('/analyses/' + value['id'], method='DELETE', revision=owned[value['id']]) is True
        owned.pop(value['id'])
    try:
        saved = create()
        path = '/analyses/' + saved['id']
        assert saved['document'] == envelope()['document'] and saved['revision'] == 1
        assert saved['name'] == envelope()['name'].strip() and saved['description'] is None
        assert api(path) == saved
        other = create(credential=other_token)
        for method, route, body in [('POST', '/analyses', envelope()), ('GET', '/analyses', None),
                                    ('GET', path, None), ('PUT', path, dict(envelope(), revision=1)),
                                    ('DELETE', path + '?revision=1', None)]:
            api(route, body, method, credential=write_key, expected=403)
            api(route, body, method, credential=None, expected=401)
        for method in ('GET', 'PUT', 'DELETE'):
            options = dict(revision=1) if method == 'DELETE' else {}
            body = dict(envelope(), revision=1) if method == 'PUT' else None
            assert api(path, body, method, credential=other_token, expected=404, **options)['code'] == 'analysis_not_found'
        foreign_page = api(credential=other_token)
        assert saved['id'] not in [e['node']['id'] for e in foreign_page['edges']]
        assert other['id'] not in [e['node']['id'] for e in api(after=foreign_page['edges'][0]['cursor'])['edges']]
        assert other['id'] not in [e['node']['id'] for e in api()['edges']]

        # Character bounds, all kinds, absent description, and exact compact byte bounds.
        for kind in ('trends', 'funnel', 'retention'):
            for length in (1, 120):
                body = envelope(kind=kind, name='😀' * length, description='雪' * 500)
                value = create(body)
                assert value['kind'] == kind and value['description'] == body['description']
                delete(value)
        body = envelope(); body.pop('description')
        value = create(body); assert value['description'] is None; delete(value)
        document = {'x': '😀' * 8190}
        assert len(json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode()) == 32768
        value = create(envelope(document=document)); delete(value)
        # Numeric content outside PostgreSQL JSONB range remains an opaque JSON value.
        # Send exponent notation directly to avoid Python float overflow.
        raw = json.dumps(envelope()).replace('"never-executed"', '1e200000').encode()
        request = urllib.request.Request(base + '/analyses', data=raw, method='POST',
                                        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=40) as response:
            value = json.load(response, parse_float=Decimal)
        owned[value['id']] = value['revision']
        assert api('/analyses/' + value['id'])['document'] == value['document']
        delete(value)
        invalid = [('name', ''), ('name', ' '), ('name', '😀' * 121), ('name', '\0'),
                   ('description', '雪' * 501), ('description', '\0'), ('kind', 'unknown'),
                   ('documentVersion', 0), ('documentVersion', -1), ('documentVersion', 1.5),
                   ('documentVersion', '1'), ('document', []), ('document', 'text'), ('document', None),
                   ('document', {'x': document['x'] + 'a'}), ('revision', 0), ('revision', 1.5)]
        for field, bad in invalid:
            body = dict(envelope(), revision=1, **{field: bad}) if field != 'revision' else dict(envelope(), revision=bad)
            problem = replace(saved, body, expected=400)
            assert field in problem['detail'], (field, problem)
            assert api(path) == saved
        for field in ('name', 'kind', 'documentVersion', 'document', 'revision'):
            body = dict(envelope(), revision=1); body.pop(field)
            assert field in replace(saved, body, expected=400)['detail']
        for revision in (None, '', '0', '-1', '1.5', '9223372036854775808'):
            assert 'revision' in api(path, method='DELETE', expected=400,
                                     **({} if revision is None else {'revision': revision}))['detail']

        current = replace(saved)
        assert current['revision'] == 2 and current['createdAt'] == saved['createdAt']
        assert current['updatedAt'] > saved['updatedAt']
        assert replace(saved, expected=409)['code'] == 'analysis_revision_conflict'
        assert api(path, method='DELETE', revision=1, expected=409)['code'] == 'analysis_revision_conflict'
        # Independent HTTP requests each open a separate store connection.
        def concurrent_replace():
            request = urllib.request.Request(base + path, data=json.dumps(dict(envelope(), revision=2)).encode(), method='PUT',
                                            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            try: response = urllib.request.urlopen(request, timeout=40)
            except urllib.error.HTTPError as error: response = error
            with response: return response.status, json.load(response)
        results = parallel(concurrent_replace)
        assert sorted(status for status, _ in results) == [200, 409]
        owned[saved['id']] = 3
        delete(current)
        api(path, method='DELETE', revision=3, expected=404)

        values = [create(envelope(kind=kind)) for kind in ('trends', 'funnel', 'retention', 'funnel')]
        # Scope assertions to our IDs; other acceptance scenarios may have saved rows.
        def walk(backward=False, kind=None):
            params = {'last' if backward else 'first': 1}
            if kind: params['kind'] = kind
            result = []
            for _ in range(1100):
                page = api(**params)
                edges = page['edges']
                if not edges:
                    assert page['pageInfo']['startCursor'] is None and page['pageInfo']['endCursor'] is None
                    return result
                assert len(edges) == 1
                assert page['pageInfo']['startCursor'] == edges[0]['cursor'] == page['pageInfo']['endCursor']
                result = [edges[0]['node']] + result if backward else result + [edges[0]['node']]
                params['before' if backward else 'after'] = edges[0]['cursor']
            raise AssertionError('pagination failed to terminate')
        for kind in (None, 'funnel'):
            forward, backward = walk(kind=kind), walk(True, kind)
            assert forward == backward
            ids = [row['id'] for row in forward]
            assert len(ids) == len(set(ids))
            assert [r['updatedAt'] for r in forward] == sorted((r['updatedAt'] for r in forward), reverse=True)
            for value in values:
                assert (value['id'] in ids) == (kind is None or value['kind'] == kind)
        old_page = api(first=1)
        edge = old_page['edges'][0]
        assert edge['node']['id'] in owned
        delete(edge['node'])
        api(first=1, after=edge['cursor'])
        updated = replace(values[0], dict(envelope(kind='retention'), revision=1))
        assert api(first=1)['edges'][0]['node'] == updated
        assert api(first=0)['edges'] == []
        for params in ({'first': -1}, {'first': 101}, {'first': 1, 'last': 1}, {'after': 'garbage'}):
            api(expected=400, **params)
        assert 'kind' in api(expected=400, kind='unknown')['detail']
        contract = json.load(urllib.request.urlopen(base + '/openapi.json', timeout=10))
        assert '409' in contract['paths']['/analyses/{id}']['put']['responses']
        errors = contract['paths']['/analyses']['get']['responses']['400']['content']
        assert errors['application/problem+json']['schema']['$ref'].endswith('/ProblemDetails')
        assert errors['application/json']['schema']['$ref'].endswith('/RelayPageError')
        if 'env' in _:
            from pathlib import Path
            from test_support import binary, hspec
            client_env = dict(_['env'], KANSOKU_REQUIRED_INTEGRATION='1', KANSOKU_SERVER_URL=base,
                              KANSOKU_API_KEY=write_key, KANSOKU_ANALYSES_SERVICE_TOKEN=token)
            hspec([binary('kansoku-client:test:kansoku-client-test'), '--match=live integration saved analysis'],
                  env=client_env, log=Path(client_env['KANSOKU_OWNED_POSTGRES_ROOT']).parent / 'analyses-client.log')
        print('Saved analyses: roundtrip, isolation, field bounds, concurrent revisions, bidirectional pages and served OpenAPI passed.', flush=True)
    finally:
        for credential, rows in ((token, owned), (other_token, foreign)):
            for ident, revision in rows.items():
                api('/analyses/' + ident, method='DELETE', credential=credential, revision=revision)


def verify_quota(base, write_key, token, other_token, **_):
    api = verifier(base, token)
    owned, foreign = {}, {}
    def create(credential=token, expected=200):
        value = api(body=envelope(), method='POST', credential=credential, expected=expected)
        if 'id' in value: (owned if credential == token else foreign)[value['id']] = value['revision']
        return value
    try:
        first = create()
        def attempt():
            request = urllib.request.Request(base + '/analyses', data=json.dumps(envelope()).encode(), method='POST',
                                            headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            try: response = urllib.request.urlopen(request, timeout=40)
            except urllib.error.HTTPError as error: response = error
            with response: return response.status, json.load(response)
        results = parallel(attempt)
        assert sorted(status for status, _ in results) == [200, 409]
        for status, value in results:
            if status == 200: owned[value['id']] = value['revision']
            else: assert value['code'] == 'analysis_limit_reached' and not value['retryable']
        assert len(api()['edges']) == 2
        assert create(expected=409)['code'] == 'analysis_limit_reached'
        create(other_token); create(other_token)
        assert create(other_token, 409)['code'] == 'analysis_limit_reached'
        api('/analyses/' + first['id'], method='DELETE', revision=1); owned.pop(first['id'])
        create()
        print('Saved analyses: quota=2, concurrent final slot, separate account allowance and deletion recovery passed.', flush=True)
    finally:
        for credential, rows in ((token, owned), (other_token, foreign)):
            for ident, revision in rows.items():
                api('/analyses/' + ident, method='DELETE', credential=credential, revision=revision)


if __name__ == '__main__':
    import sys
    if '--quota-only' not in sys.argv:
        main(verify_analyses, pass_environment=True, server_environment={'KANSOKU_INGEST_MAX_BODY_BYTES': '4096'})
    main(verify_quota, server_environment={'KANSOKU_ANALYSES_MAX_PER_ACCOUNT': '2'})
