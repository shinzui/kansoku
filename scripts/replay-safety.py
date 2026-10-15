#!/usr/bin/env python3
"""Owned ClickHouse restart, old-block replay and interrupted rebuild proof."""
import json
from pathlib import Path
import subprocess
import tempfile

from isolated_clickhouse import isolated_clickhouse, apply_migrations


def query(env, sql):
    return subprocess.check_output(
        ['clickhouse-client', '--host', '127.0.0.1', '--port', env['CLICKHOUSE_TCP_PORT'],
         '--multiquery'], input=sql, env=env, text=True, stderr=subprocess.PIPE, timeout=150).strip()


INSERT = """INSERT INTO analytics.events_raw
  (event_id,event_name,source,occurred_at,received_at,user_id,account_id,session_id,url,properties,context)
  VALUES
  ('payment1','payment_completed','web','2026-07-01 12:00:00','2026-07-01 12:00:01','user','replay','session','/home','{"amount":3}','{}'),
  ('payment2','payment_completed','web','2026-07-01 12:00:00','2026-07-01 12:00:01','user','replay','session','/home','{"amount":7}','{}'),
  ('page1','page_view','web','2026-07-01 12:00:00','2026-07-01 12:00:01','user','replay','session','/home','{}','{}'),
  ('page2','page_view','web','2026-07-01 12:00:00','2026-07-01 12:00:01','user','replay','session','/home','{}','{}');"""

SNAPSHOT = """SELECT count() AS events,
  sumIf(JSONExtractFloat(properties,'amount'),event_name='payment_completed') AS revenue,
  avgIf(JSONExtractFloat(properties,'amount'),event_name='payment_completed') AS average,
  uniqExact(session_id) AS sessions,
  (SELECT uniqExactMerge(views) FROM analytics.page_views_by_route WHERE account_id='replay') AS views,
  (SELECT uniqExactMerge(events) FROM analytics.daily_event_counts WHERE account_id='replay') AS daily
FROM analytics.events_canonical WHERE account_id='replay' FORMAT JSONEachRow"""
EXPECTED = dict(events=4, revenue=10, average=5, sessions=1, views=2, daily=4)


def check(env):
    assert json.loads(query(env, SNAPSHOT)) == EXPECTED, 'replay changed canonical aggregates'


def main():
    with tempfile.TemporaryDirectory(prefix='kansoku-replay-') as directory:
        with isolated_clickhouse(directory=directory) as env:
            apply_migrations(env)
            query(env, 'SYSTEM STOP MERGES analytics.events_raw; ' + INSERT + INSERT)
            assert int(query(env, "SELECT count() FROM analytics.events_raw WHERE account_id='replay'")) == 8
            check(env)
            query(env, 'SYSTEM START MERGES analytics.events_raw')
            # More than the contemplated 1000-block token window, using a
            # separate account so padding cannot alter the expected population.
            padding = """INSERT INTO analytics.events_raw
              (event_id,event_name,source,occurred_at,received_at,user_id,account_id,properties,context)
              VALUES ('padding_%d','padding','web','2026-07-01 12:00:00','2026-07-01 12:00:01','','padding','{}','{}');"""
            query(env, '\n'.join(padding % number for number in range(1001)))
            check(env)
        # Own a new real server on the same private data, with new connections.
        with isolated_clickhouse(directory=directory) as env:
            check(env)
            query(env, INSERT)
            check(env)
            migration = Path('db/clickhouse/migrations/0017_replay_safe_sources.sql').read_text()
            # The published tables survive a failed pre-swap verification.
            query(env, migration.split('-- Verify complete')[0])
            query(env, 'TRUNCATE TABLE analytics.daily_event_counts_rebuild')
            verify = migration.split('-- Verify complete')[1].split('-- Each swap')[0]
            try:
                query(env, '-- Verify complete' + verify)
            except subprocess.CalledProcessError as error:
                assert "canonical daily-event rebuild mismatch" in error.stderr, error.stderr
            else:
                raise AssertionError('corrupt replacement passed pre-swap verification')
            check(env)
            query(env, migration)
            check(env)
            # Restart both before publishing and after only the first swap.
            for interrupted in (migration.split('-- Verify complete')[0],
                                migration.split('EXCHANGE TABLES analytics.page_views_by_route AND')[0],
                                migration.split('-- Trigger inputs')[0]):
                query(env, interrupted)
                query(env, migration)
                check(env)
            query(env, 'OPTIMIZE TABLE analytics.events_raw FINAL')
            check(env)
    print('Native replay: 1001 intervening insert blocks, restart, old replay, verified swaps, interrupted rebuild and merge passed.', flush=True)


if __name__ == '__main__':
    main()
