# Operate Kansoku

Kansoku runs the HTTP server, PostgreSQL queue producer, Shibuya batch writer, ClickHouse query
pool, queue-depth poller, and rejection cleanup in one supervised process. Operate PostgreSQL and ClickHouse as
durable dependencies; restarting Kansoku does not replace their backups, monitoring, or capacity
planning.

## Migrations and startup order

Kansoku has two independent, forward-only migration systems:

1. `just migrate` (or `cabal run kansoku-migrate -- up`) installs the vendored PGMQ schema and
   then `kansoku.api_keys` and `kansoku.ingest_rejections` in PostgreSQL.
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

### Legacy PostgreSQL installations

The standard `up` path is for a fresh database or one already tracked by the current pg-migrate
ledger. A database containing a PGMQ schema installed by an older Kansoku/`pgmq-migration`
release but no current ledger is not auto-classified. `up` refuses to claim that history and can
fail when the baseline encounters an existing PGMQ object. This is intentional evidence
protection, not an idempotent success.

Do not drop, edit, or repeatedly replay that database. Preserve it, inspect both the old
`public.schema_migrations` history and current pg-migrate status, and plan an explicit history
import or a data cutover using the pinned `pgmq-migration` package's schema-migration guidance.
Kansoku's CLI does not currently automate that legacy import. A development database with no
valuable data may instead be replaced deliberately after confirming its exact path and backup
requirements.

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
| `GET /health/live` | HTTP 200 JSON | Process responsiveness, independent of dependencies. |
| `GET /health/ready` | HTTP 200 JSON | First failing dependency determines 503. |
| `GET /health` | HTTP 200, `OK` | The HTTP process can answer. It does not check dependencies. |
| `GET /ready` | HTTP 200 JSON | Compatibility diagnostics: writer, PGMQ, ClickHouse, queue depth, and flush freshness satisfy readiness thresholds. |
| `GET /internal/metrics` | HTTP 200 Prometheus text | Pipeline telemetry, when enabled. |
| `GET /openapi.json` | HTTP 200 JSON | Current generated public HTTP contract. |
| `GET /v1/schemas` | HTTP 200 JSON | Current public event schema catalog. |

Use `/health/live` for orchestration liveness and `/health/ready` for readiness.
Canonical bodies contain exactly `status`, `check`, and `failingSince`: healthy is
`{"status":"ok","check":"all","failingSince":null}`; failure is HTTP 503 with
`status: failed`, the first failing check, and the original consecutive failure onset.
Recovery resets the onset. Dependency failure does not fail liveness.

Readiness checks run in order: `writer_alive`, `pgmq_reachable`,
`clickhouse_query_reachable`, `queue_depth`, `writer_flush_stale`. External checks
include pool acquisition and physical cleanup in a 750 ms deadline; the complete
probe has a 2 second deadline. Query reachability uses native ping without scanning
analytics tables. Backlog thresholds still use the poller's cached sample.

`/health` retains its `OK` text response. `/ready` retains detailed diagnostics,
including all five ordered checks and observations for failed thresholds. It returns
503 with `status: unavailable` and a `failing` list on failure. These four exact probe
paths are operational contracts, exempt from RFC 9457 problem bodies and excluded
from access logging. They are absent from customer OpenAPI and outside ingestion
CORS, authentication and body limits.

The reference and operational routes are unauthenticated. Restrict `/ready`,
`/internal/metrics`, and deployment-specific diagnostics with network policy or a reverse proxy.

## Prometheus metrics

The built-in scrape exports these Kansoku pipeline instruments in addition to runtime/process
metrics:

- `kansoku_queue_length`
- `kansoku_queue_oldest_message_age_seconds`
- `kansoku_writer_batches_total`
- `kansoku_writer_events_written_total`
- `kansoku_writer_batch_flush_seconds`
- `kansoku_writer_insert_failures_total`
- `kansoku_writer_dead_letters_total`
- `kansoku_ingest_events_total{outcome,transport}`
- `kansoku_ingest_rejections_total{reason,transport}`
- `kansoku_ingest_timestamp_adjustments_total{adjustment,transport}`
- `kansoku_ingest_quarantine_failures_total`
- `kansoku_ingest_quarantine_cleanup_lag_seconds`

Alert on sustained queue growth and oldest-message age, readiness failures, insert-failure or
dead-letter increases, and a mismatch between accepted traffic and written-event rate. A drained
queue resets the backlog-sensitive stale-flush readiness condition, so monotonic counters are
important for historical alerting.

Accepted counts increase after queue commit; rejected counts increase once per event, and
reason counts once per distinct reason per event. Labels never contain account, credential or
payload values. Transports are `single` and `batch` (the later beacon route uses the same
instruments). Compare rates while watching queue depth/oldest age for backlog; writer retries
and replay mean counters are not an exact equality invariant.

Opt-in quarantine preserves original parsed event objects for declared-schema failures only.
Writes have one 250 ms best-effort budget per request on a dedicated short-lived connection
and cannot roll back queue writes or invalidate an ingest-pool connection.
No request credentials or transport envelopes are captured. Oversized objects are replaced
with `{}`; `payload_truncated` and `original_payload_bytes` explain the loss. Cleanup runs on
startup and hourly, including when new capture is disabled. Expiry and per-account row caps
are eventual within that interval; failures retry each minute and increase the failure counter.
The cleanup-lag gauge is refreshed each minute. This is not a hard deletion deadline.

## Traces

Every non-probe request writes one JSON access line to stdout. Fields are `method`,
`path` (without query), `path_truncated`, numeric `status`, UTC `time`, monotonic
`duration_ms`, optional `user_agent`/`user_agent_truncated`, and valid lowercase
`trace_id`/`span_id` when provided by the serving context. Path and user-agent
inputs are capped at 2048 and 512 bytes. Canonical and compatibility probes are
excluded by exact path; authenticated traffic is included. Bodies, credentials,
cookies, arbitrary headers and query values are never captured. Diagnostics use stderr.

HTTP and writer spans export only when traces are explicitly configured. Incoming
W3C `traceparent` supplies the parent of one server span. Served routes produce
bounded names such as `GET metrics/events`; unmatched routes retain a method-only
name. Instrumentation sees a bounded request copy without query values, while the
application receives its complete original request and the instrumented context.
This privacy boundary applies before processors/exporters, including legacy,
`http`, and `http/dup` semantic modes. A 5xx response records the actual status and
an error span without copying the problem body.

The process owns tracer and optional meter providers. Exit and exception unwinding
flush providers before shutdown. HTTP instruments are OTel request duration,
active-request and request-count instruments, enabled for export by explicit
`OTEL_METRICS_EXPORTER` configuration; the pipeline instruments above remain
Prometheus-owned. See [configuration](configuration.md#trace-export) for opt-in
variables. Writer batches do not claim to be children of individual ingest requests.

## Failure and recovery behavior

### PostgreSQL unavailable

Ingest and credential checks return retryable HTTP 503, `/ready` fails `pgmq_reachable`, and queue
sampling logs warnings. Restore PostgreSQL, then confirm `/ready` and queue metrics recover.
Accepted events already in the queue remain durable.

### ClickHouse unavailable

Canonical readiness fails `clickhouse_query_reachable`. Interrupted and failed query
connections close before errors propagate; the next pool checkout opens a fresh connection.
Pool shutdown closes idle physical connections. Metric queries return retryable HTTP 503. Writer inserts fail, increment
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

Send SIGTERM or SIGINT. The supervisor cancels the server, writer, poller, and rejection-cleanup lifetimes and shuts
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
