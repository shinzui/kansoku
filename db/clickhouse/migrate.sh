#!/usr/bin/env bash
# Historical bytes and hash: kansoku-server/migrations/clickhouse/original/migrate.sh
printf '%s\n' 'The filename-only ClickHouse migration runner is retired. Use kansoku-ch-migrate with an explicit maintenance session; see docs/guides/clickhouse-migrations.md. Existing history is not imported.' >&2
exit 1
