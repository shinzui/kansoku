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
        # Previously published 25-migration artifacts remain independently valid.
        # New artifacts must carry the complete named, seven-step suffix.
        if (len(migrations) not in (25,26) or
                sum(len(m['steps']) for m in migrations[:25]) != (254 if replicated else 257) or
                (len(migrations)==26 and (migrations[-1].get('name')!='0026_diagnostic_session_engagement' or len(migrations[-1]['steps'])!=7))):
            raise ValueError('Unexpected native migration/step count')
        if replicated and 'sha256-v2' not in doc['result']['checksumFormats']:
            raise ValueError('Missing v2 checksums')
    else:
        by_name = {c['name']: c for c in components}
        if set(by_name) != {'pgmq', 'kansoku'}:
            raise ValueError('Unexpected PostgreSQL components')
        # PostgreSQL identifiers are stable migration IDs.
        names = [m['id'] for m in by_name['kansoku']['migrations']]
        required = ['kansoku/0008-clickhouse-replicated-administration', 'kansoku/0009-clickhouse-replicated-jobs']
        if not any(names[index:index+2] == required for index in range(len(names))):
            raise ValueError('Missing replicated coordinator migrations')
        suffix = names[names.index(required[-1])+1:]
        if suffix not in ([], ['kansoku/0010-saved-analyses']):
            raise ValueError('Unexpected PostgreSQL migration suffix')
    return doc
