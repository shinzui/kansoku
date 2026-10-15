#!/usr/bin/env python3
"""Required native query-pool faults on an owned disposable ClickHouse instance."""
import subprocess
from isolated_clickhouse import isolated_clickhouse

with isolated_clickhouse() as env:
    subprocess.run(['clickhouse-client', '--port', env['CLICKHOUSE_TCP_PORT'], '--multiquery', '--query', 'CREATE DATABASE analytics; CREATE TABLE analytics.events_raw (n UInt8) ENGINE = Memory'], check=True)
    subprocess.run(['cabal', 'test', 'kansoku-core-test', '--test-options=--match Kansoku.QueryPool', '--test-show-details=direct'], env=env, check=True, timeout=120)
