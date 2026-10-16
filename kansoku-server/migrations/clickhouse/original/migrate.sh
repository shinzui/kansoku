#!/usr/bin/env bash
# ClickHouse migration runner.
#
# Applies db/clickhouse/migrations/*.sql in filename order, skipping files
# already recorded in analytics.schema_migrations, and recording each applied
# file. RULE: a migration file is IMMUTABLE once applied anywhere — never edit
# an applied file; add a new numbered file instead. The ledger keys on the
# filename, so an edited file would silently not re-run.
set -euo pipefail

port="${CLICKHOUSE_TCP_PORT:?CLICKHOUSE_TCP_PORT must be set (enter nix develop)}"

ch() {
  clickhouse-client --port "$port" "$@"
}

ch --query "CREATE DATABASE IF NOT EXISTS analytics"
ch --query "
  CREATE TABLE IF NOT EXISTS analytics.schema_migrations
  (
      filename   String,
      applied_at DateTime64(3, 'UTC') DEFAULT now64(3)
  )
  ENGINE = MergeTree
  ORDER BY filename"

for f in db/clickhouse/migrations/*.sql; do
  name="$(basename "$f")"
  applied="$(ch --query "SELECT count() FROM analytics.schema_migrations WHERE filename = '$name'")"
  if [ "$applied" = "0" ]; then
    echo "applying $name"
    ch --multiquery < "$f"
    ch --query "INSERT INTO analytics.schema_migrations (filename) VALUES ('$name')"
  else
    echo "skipping $name (already applied)"
  fi
done
