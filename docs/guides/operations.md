# Operate Kansoku

Kansoku runs the HTTP server, PostgreSQL queue producer, Shibuya batch writer, ClickHouse query
pool, and queue-depth poller in one supervised process. Operate PostgreSQL and ClickHouse as
durable dependencies; restarting Kansoku does not replace their backups, monitoring, or capacity
planning.

## Migrations and startup order

Kansoku has two independent, forward-only migration systems:

1. `just migrate` (or `cabal run kansoku-migrate -- up`) installs the vendored PGMQ schema and
   then `kansoku.api_keys` in PostgreSQL.
2. `just ch-migrate` applies `db/clickhouse/migrations/*.sql` in filename order and records them
   in `analytics.schema_migrations`.

Apply both before starting a new release. Normal `kansoku-server` startup does not migrate a
database; it only idempotently creates the configured PGMQ queue after the PGMQ schema exists.
Use the migration executable's read-only commands to inspect the PostgreSQL plan:

```bash
cabal run kansoku-migrate -- plan
cabal run kansoku-migrate -- list
cabal run kansoku-migrate -- status
cabal run kansoku-migrate -- verify
```

Run `cabal run kansoku-migrate -- --help` for the authoritative command list for the pinned
version. ClickHouse migration files are immutable after application. Back up durable data and
test migrations against a restored copy before a production rollout.

`just ch-reset` drops the entire `analytics` database and replays every ClickHouse migration. It
is development-only and destroys all analytics data.

## Credentials and accounts

Issue credentials only after the PostgreSQL plan is applied:

```bash
just issue-key write account_123 "browser production"
just issue-key service account_123 "reporting backend"
```

The plaintext token is displayed once. Store it immediately in a secret manager. PostgreSQL
stores only its SHA-256 hash. Write keys can ingest; service tokens can ingest and query metrics.
Every request performs a database lookup, so revocation takes effect on the next request.

There is not yet a key-management HTTP API or revocation CLI. Revoke by the printed key UUID,
using an administrative PostgreSQL session and an audited change:

```sql
UPDATE kansoku.api_keys
SET revoked_at = now()
WHERE id = '00000000-0000-0000-0000-000000000000'
  AND revoked_at IS NULL;
```

Confirm that exactly one row changed. Do not identify a key by plaintext—the database never
stores it. Issue a replacement as a separate step and update callers before revoking during a
zero-downtime rotation.

## Probes and public references

| Route | Success | Meaning |
| --- | --- | --- |
| `GET /health` | HTTP 200, `OK` | The HTTP process can answer. It does not check dependencies. |
| `GET /ready` | HTTP 200 JSON | Writer, PGMQ, queue depth, and flush freshness satisfy readiness thresholds. |
| `GET /internal/metrics` | HTTP 200 Prometheus text | Pipeline telemetry, when enabled. |
| `GET /openapi.json` | HTTP 200 JSON | Current generated public HTTP contract. |
| `GET /v1/schemas` | HTTP 200 JSON | Current public event schema catalog. |

`/ready` always reports four checks in this order: `writer_alive`, `pgmq_reachable`,
`queue_depth`, and `writer_flush_stale`. A failure returns HTTP 503 with `status: unavailable`, a
`failing` list, and details on the failed checks. Configure orchestration readiness from `/ready`
and liveness from `/health`.

The reference and operational routes are unauthenticated. Restrict `/ready`,
`/internal/metrics`, and deployment-specific diagnostics with network policy or a reverse proxy.

## Prometheus metrics

The built-in scrape exports seven Kansoku pipeline instruments in addition to runtime/process
metrics:

- `kansoku_queue_length`
- `kansoku_queue_oldest_message_age_seconds`
- `kansoku_writer_batches_total`
- `kansoku_writer_events_written_total`
- `kansoku_writer_batch_flush_seconds`
- `kansoku_writer_insert_failures_total`
- `kansoku_writer_dead_letters_total`

Alert on sustained queue growth and oldest-message age, readiness failures, insert-failure or
dead-letter increases, and a mismatch between accepted traffic and written-event rate. A drained
queue resets the backlog-sensitive stale-flush readiness condition, so monotonic counters are
important for historical alerting.

## Traces

Kansoku exports OpenTelemetry spans only when trace export is configured. The writer traces batch
processing and uses the configured provider for shutdown flushing. See
[configuration](configuration.md#trace-export) for opt-in variables. Correlate writer failure
counters, queue age, and trace errors when investigating storage latency.

## Failure and recovery behavior

### PostgreSQL unavailable

Ingest and credential checks return retryable HTTP 503, `/ready` fails `pgmq_reachable`, and queue
sampling logs warnings. Restore PostgreSQL, then confirm `/ready` and queue metrics recover.
Accepted events already in the queue remain durable.

### ClickHouse unavailable

Metric queries return retryable HTTP 503. Writer inserts fail, increment
`kansoku_writer_insert_failures_total`, and are retried within the adapter policy. The writer
discards a failed physical connection and opens a new one on the next delivery so a repaired
ClickHouse can recover without restarting Kansoku.

The pinned adapter auto-archives a message after its retry budget is exhausted. A long outage can
therefore require deliberate archive inspection and replay after storage recovers; do not assume
an arbitrarily long outage drains automatically. Verify event IDs before replay so ClickHouse's
idempotency boundary remains effective.

### Malformed queued payload

A payload that no longer decodes as an analytics event is dead-lettered and increments
`kansoku_writer_dead_letters_total`. Inspect the archived body and producing version before any
manual replay.

### Graceful shutdown

Send SIGTERM or SIGINT. The supervisor cancels the server, writer, and poller lifetimes and shuts
down the trace provider. Stop accepting traffic before termination and allow the platform's grace
period to complete. Producer-side Haskell clients still need their own `flush`/`close` handling.

## Data maintenance

Identity evidence and raw identifiers require special handling for erasure and fingerprint
retention. Follow [Identity data deletion and fingerprint retention](../runbooks/identity-data-deletion.md)
exactly; those ClickHouse mutations are asynchronous, expensive, and irreversible.

The raw `analytics.events_raw` table is the event source of truth. Establish external backup,
retention, disk, and replica procedures appropriate to the deployed ClickHouse topology. Kansoku
does not currently automate backups or tenant-specific raw-event retention.

[Documentation index](../README.md)
