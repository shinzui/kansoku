# Operate Kansoku

Kansoku runs the HTTP server, PostgreSQL queue producer, Shibuya batch writer, ClickHouse query
pool, queue-depth poller, and rejection cleanup in one supervised process. Operate PostgreSQL and ClickHouse as
durable dependencies; restarting Kansoku does not replace their backups, monitoring, or capacity
planning.

## Migrations and startup order

Kansoku has two independent, forward-only migration systems:

1. `just migrate` (or `cabal run kansoku-migrate -- up`) installs the vendored PGMQ schema and
   then the application credential, rejection and acceptance-ledger tables in PostgreSQL.
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
- `kansoku_queue_archive_length`
- `kansoku_queue_oldest_message_age_seconds`
- `kansoku_writer_batches_total`
- `kansoku_writer_events_written_total`
- `kansoku_writer_batch_flush_seconds`
- `kansoku_writer_insert_failures_total`
- `kansoku_writer_breaker_state`
- `kansoku_writer_recovery_failures_total`
- `kansoku_writer_dead_letters_total`
- `kansoku_ingest_events_total{outcome,transport}`
- `kansoku_ingest_newly_queued_total{transport}`
- `kansoku_ingest_rate_limited_requests_total{transport}`
- `kansoku_ingest_rejections_total{reason,transport}`
- `kansoku_ingest_timestamp_adjustments_total{adjustment,transport}`
- `kansoku_ingest_quarantine_failures_total`
- `kansoku_ingest_quarantine_cleanup_lag_seconds`

Alert on sustained queue growth and oldest-message age, readiness failures, insert-failure or
dead-letter increases, and a mismatch between accepted traffic and written-event rate. A drained
queue resets the backlog-sensitive stale-flush readiness condition, so monotonic counters are
important for historical alerting.

Accepted counts include acknowledged equal retries after commit; newly queued counts include only
new identities. Rate-limited requests have their own request counter and no event outcome.
Rejected counts increase once per event, and
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
Pool shutdown closes idle physical connections. Metric queries return retryable HTTP 503.
The writer retains one unchanged batch and closes the source gate before further adapter pulls.
Prefetch is disabled, the inbox and ready-batch buffer are each one element, and a read already
in progress may finish. For the single constant batch key, a conservative retained-delivery
bound is `2 * writerBatch + adapterBatch + 3` (11003 at defaults); recovery itself retains
one unchanged active batch. Framework buffers and chunks account for the rest.
A separate physical connection probes storage every five seconds (750 ms deadline); ping permits
another insert attempt, and only a successful insert reopens consumption. Inserts have a 30-second
deadline. Failed connections are discarded. Native batch lease renewal uses at least 60 seconds.

`kansoku_writer_breaker_state` is 0 while closed, 1 while unavailable, and 2 for a rejected
SQL/schema insert. State 2 parks the batch and retries at the same cadence; repair the schema
rather than replaying valid data. Recovery failures increment their own counter. Batch-flush
histograms include time retained for recovery. Alert on an open breaker and archive growth.

The adapter delivery maximum is 9223372036854775807, with a proven source pause. Its underlying
read count is still a finite Int32; overflow fails rather than archiving a valid event. This is
a practically non-exhausting delivery policy, conditional on finite PostgreSQL disk/WAL capacity
and eventual storage recovery. Ordinary storage retry renews the held batch without consuming
more deliveries. A restart redelivers leased messages after visibility expiry; immutable acceptance
and canonical reads make uncertain committed inserts safe. Allow at least the 35-second total
writer shutdown deadline before forcibly terminating the process.

Run `just outage-acceptance` for the owned packaged-server ten-minute, 200-events/s outage and
restart proof, or `just outage-smoke` for a short recovery regression. Both require native tools
from `nix develop`, own their stores/processes, fail on missing required cases, and record private
measurement reports under `.dev/acceptance/outage-*/report.json`. See the
[capacity procedure](capacity.md) for finite disk and drain budgets.

### Malformed queued payload

A payload that no longer decodes as an analytics event is dead-lettered and increments
`kansoku_writer_dead_letters_total`. Inspect the archived body and producing version before any
manual replay.

### Graceful shutdown

Send SIGTERM or SIGINT. The supervisor cancels the server, writer, poller, and rejection-cleanup lifetimes and shuts
down the trace provider. Stop accepting traffic before termination and allow the platform's grace
period to complete. Producer-side Haskell clients still need their own `flush`/`close` handling.

## Event identity and analytical replay

`kansoku.accepted_events` retains account/event IDs, canonical producer SHA-256 hashes, first
acceptance times and optional erasure tombstones indefinitely. Budget PostgreSQL disk for this
ledger as well as queued payloads. Do not truncate it during queue maintenance: that would allow
an old ID to be normalized and accepted again. It contains no complete event payload.

`analytics.events_canonical` is the internal logical source, currently `events_raw FINAL` with
its native JSON column explicitly projected. Query-time sums, averages, sessions and identity
joins use that source. Daily event/page-view rollups store exact distinct event-ID states; use
`uniqExactMerge`, not `countMerge`. Duplicate physical raw rows are expected after uncertain
insert acknowledgements. Their logical identity does not depend on background merges or a
finite insert-block token window.

Migration `0017_replay_safe_sources.sql` requires the writer stopped for its entire execution.
It builds replacement rollups from canonical retained rows, verifies every aggregate group,
then atomically swaps each public table name. If interrupted, leave the writer stopped and
reapply the migration; appending an additive backfill to an existing table is unsafe. Fresh
install and interrupted-rebuild native checks verify this administrative boundary.

## Data maintenance

Identity evidence and raw identifiers require special handling for erasure and fingerprint
retention. Follow [Identity data deletion and fingerprint retention](../runbooks/identity-data-deletion.md)
exactly; those ClickHouse mutations are asynchronous, expensive, and irreversible.

The raw `analytics.events_raw` table is the event source of truth. Establish external backup,
retention, disk, and replica procedures appropriate to the deployed ClickHouse topology. Kansoku
does not currently automate backups or tenant-specific raw-event retention.

[Documentation index](../README.md)
