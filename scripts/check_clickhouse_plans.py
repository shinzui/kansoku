#!/usr/bin/env python3
"""Compare all direct offline fields against the independently built 2008b67 CLI."""
import json
import os
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[1]


def inspect(binary, replicated=False):
    env = {k:v for k,v in os.environ.items() if not k.startswith(('KANSOKU_', 'CLICKHOUSE', 'PG'))}
    if replicated:
        env.update(KANSOKU_CH_MIGRATION_CLUSTER='fixture', KANSOKU_CH_MIGRATION_REPLICA_IDS='11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222')
    return json.loads(subprocess.check_output([binary,'plan','--json'],env=env,text=True,timeout=30))


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--capture-reference', help='Executable built from 2008b67')
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    fixture = REPO / 'kansoku-server/test/fixtures/clickhouse-direct-plan-2008b67.json'
    if args.capture_reference:
        fixture.parent.mkdir(parents=True,exist_ok=True)
        fixture.write_text(json.dumps(inspect(args.capture_reference),indent=2)+'\n')
    canonical = lambda value: json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
    current = inspect(args.binary)
    assert len(current['result']['components'][0]['migrations']) == 26
    current['result']['components'][0]['migrations'] = current['result']['components'][0]['migrations'][:25]
    current['result']['schedule'] = current['result']['schedule'][:25]
    assert canonical(current) == canonical(json.loads(fixture.read_text())), 'Direct prefix changed from 2008b67'
    from check_clickhouse_conversion import verify, verify_replicated
    verify()
    verify_replicated()
    doc = inspect(args.binary,True)
    components = doc['result']['components']
    assert len(components) == 1 and components[0]['name'] == 'kansoku_replicated'
    migrations = components[0]['migrations']
    assert len(migrations) == 26 and sum(len(m['steps']) for m in migrations[:25]) == 254 and len(migrations[-1]['steps']) == 7
    assert 'sha256-v2' in doc['result']['checksumFormats']
    for migration in migrations:
        assert len(migration['checksums']['sha256-v2']) == 64
        assert all(len(step['checksums']['sha256-v2']) == 64 for step in migration['steps'])
    print('offline plans: immutable direct 25/257 and replicated 25/254 prefixes plus 0026 (7 steps)')


if __name__ == '__main__':
    main()
