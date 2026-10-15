#!/usr/bin/env python3
"""Required query-boundary proofs against private, migrated native instances."""
import subprocess
import re
from isolated_clickhouse import apply_migrations, isolated_clickhouse

subprocess.run(['cabal', 'build', 'kansoku-core:test:kansoku-core-test'], check=True)
binary = subprocess.check_output(['cabal', 'list-bin', 'kansoku-core:test:kansoku-core-test'], text=True).strip()
for block_size, group in ((65536, "Kansoku.Metrics.Limits"), (2048, "Kansoku.Metrics.Limits"), (3, "numeric aggregate ordering")):
    with isolated_clickhouse(block_size) as env:
        env['KANSOKU_QUERY_LIMIT_FIXTURES'] = '1'
        apply_migrations(env)
        print(f'Required native metric bounds, max_block_size={block_size}', flush=True)
        result = subprocess.run([binary, '--match', group], env=env, capture_output=True, text=True, timeout=120)
        print(result.stdout, end='')
        print(result.stderr, end='')
        result.check_returncode()
        summary = re.search(r'(\d+) examples?, (\d+) failures(?:, (\d+) pending)?', result.stdout)
        assert summary and int(summary[1]) > 0 and summary[2] == '0' and not summary[3], result.stdout

with isolated_clickhouse() as env:
    apply_migrations(env)
    result = subprocess.run([binary, '--match', 'Kansoku.Query integration'], env=env, capture_output=True, text=True, timeout=120)
    print(result.stdout, end='')
    print(result.stderr, end='')
    result.check_returncode()
    summary = re.search(r'(\d+) examples?, (\d+) failures(?:, (\d+) pending)?', result.stdout)
    assert summary and int(summary[1]) > 0 and summary[2] == '0' and not summary[3], result.stdout
