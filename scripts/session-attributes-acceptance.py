#!/usr/bin/env python3
"""Prove event attachment and adjacent populations on owned disposable stores."""
from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary, hspec

for block_size in (65536, 2):
    with isolated_clickhouse(block_size=block_size) as env:
        apply_migrations(env)
        for family in ('Kansoku.Session attributes native',
                       'Kansoku.Sessions native', 'Kansoku.Acquisition native',
                       'Kansoku.Activity native'):
            hspec([binary('kansoku-core:test:kansoku-core-test'),
                   '--match=' + family], env=env, timeout=300)
