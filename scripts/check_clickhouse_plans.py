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
    assert inspect(args.binary) == json.loads(fixture.read_text()), 'Direct offline JSON changed from 2008b67'
    subprocess.run(['git','diff','--exit-code','2008b67','--','kansoku-server/migrations/clickhouse'],cwd=REPO,check=True)
    doc = inspect(args.binary,True)
    components = doc['result']['components']
    assert len(components) == 1 and components[0]['name'] == 'kansoku_replicated'
    migrations = components[0]['migrations']
    assert len(migrations) == 25 and sum(len(m['steps']) for m in migrations) == 254
    print('offline plans: direct recursively identical to 2008b67 (25/257); replicated 25/254')


if __name__ == '__main__':
    main()
