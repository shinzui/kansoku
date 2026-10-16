#!/usr/bin/env python3
"""Required paths/flows proof on an owned disposable ClickHouse."""
from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary, hspec

with isolated_clickhouse(block_size=2) as env:
    apply_migrations(env)
    hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Paths'], env=env)
