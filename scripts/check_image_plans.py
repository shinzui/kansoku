"""Offline image contracts shared by exported-image and release validation."""
import json

SELECTORS = {
    'KANSOKU_CH_MIGRATION_CLUSTER': 'fixture',
    'KANSOKU_CH_MIGRATION_REPLICA_IDS': '11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222',
}
PLAN_FIELDS = {'native-direct.json': 'nativePlanSha256',
               'native-replicated.json': 'replicatedNativePlanSha256',
               'postgres.json': 'postgresPlanSha256'}


def validate_plan(name, raw):
    doc = json.loads(raw)
    if name == 'postgres.json':
        if doc.get('ok') is not True:
            raise ValueError('Unsuccessful PostgreSQL plan')
        components = doc['data']['components']
    else:
        if doc.get('status') != 'ok':
            raise ValueError('Unsuccessful plan: ' + name)
        components = doc['result']['components']
    if name.startswith('native-'):
        replicated = name == 'native-replicated.json'
        expected = 'kansoku_replicated' if replicated else 'kansoku'
        if len(components) != 1 or components[0]['name'] != expected:
            raise ValueError('Wrong native history: ' + name)
        migrations = components[0]['migrations']
        if len(migrations) != 25 or sum(len(m['steps']) for m in migrations) != (254 if replicated else 257):
            raise ValueError('Unexpected native migration/step count')
        if replicated and 'sha256-v2' not in doc['result']['checksumFormats']:
            raise ValueError('Missing v2 checksums')
    else:
        by_name = {c['name']: c for c in components}
        if set(by_name) != {'pgmq', 'kansoku'}:
            raise ValueError('Unexpected PostgreSQL components')
        # PostgreSQL identifiers are stable migration IDs.
        names = [m['id'] for m in by_name['kansoku']['migrations']]
        if names[-2:] != ['kansoku/0008-clickhouse-replicated-administration', 'kansoku/0009-clickhouse-replicated-jobs']:
            raise ValueError('Missing replicated coordinator migrations')
    return doc
