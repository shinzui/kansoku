#!/usr/bin/env python3
"""Run explicit deterministic subsets while making accidental native calls fail."""
import os
import socket
from test_support import binary, hspec, probes

skips = [
    'Kansoku.ClickHouse',
    'Kansoku property metrics HTTP integration',
    'Kansoku.Query integration',
    'Kansoku.QueryPool',
    'Kansoku.Identity.Cache native',
    'Kansoku.Metrics.Limits/native',
    'Kansoku.Metrics filters native',
    'Kansoku.Enrichment native',
    'Kansoku.Acquisition native',
    'Kansoku.Sessions native',
    'Kansoku.Writer.Batch/decodes a pgmq payload',
    'Kansoku.Writer.Batch/keeps a committed insert',
    'Kansoku.Writer.Batch/retains a committed batch',
]
# Binding without listening reserves a non-service endpoint for the entire run.
# An incorrectly selected native example cannot contact an ambient database.
with socket.socket() as unavailable:
    unavailable.bind(('127.0.0.1', 0))
    env = dict(os.environ, KANSOKU_REQUIRED_INTEGRATION='1', KANSOKU_CLICKHOUSE_HOST='127.0.0.1', CLICKHOUSE_TCP_PORT=str(unavailable.getsockname()[1]))
    env.pop('KANSOKU_QUERY_LIMIT_FIXTURES', None)
    env.pop('KANSOKU_TELEMETRY_LIFECYCLE_CHILD', None)
    hspec([binary('kansoku-core:test:kansoku-core-test')] + ['--skip=' + pattern for pattern in skips], env=env)
    hspec([binary('kansoku-client:test:kansoku-client-test'), '--skip=live integration'], env=env)
    probes([binary('kansoku-core:test:kansoku-probe-test')], env=env)
