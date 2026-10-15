#!/usr/bin/env python3
"""Required native query-pool faults on an owned disposable ClickHouse instance."""
import subprocess
from isolated_clickhouse import isolated_clickhouse, apply_migrations

with isolated_clickhouse() as env:
    apply_migrations(env)
    subprocess.run(['cabal', 'test', 'kansoku-core-test', '--test-options=--match Kansoku.QueryPool', '--test-show-details=direct'], env=env, check=True, timeout=120)
