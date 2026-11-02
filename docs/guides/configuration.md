---
type: Reference
title: "Configure Kansoku"
description: "Look up database, server, writer, ingestion, readiness, telemetry, query-budget and retention configuration."
docId: DOC-3
tags: ["configuration", "deployment", "ingestion", "telemetry"]
generated:
  by: process:codex
  at: "2026-11-02T03:15:02Z"
---

# Configure Kansoku

`kansoku-server`, `kansoku-migrate`, `kansoku-ch-migrate`, and credential issuance read environment variables. Invalid
integer, Boolean, or positive-only values stop startup with a configuration error. There is no
authentication-off mode.

## Database and server settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `PG_CONNECTION_STRING` | `postgresql:///kansoku` | PostgreSQL URI used for PGMQ and API keys. |
| `KANSOKU_CLICKHOUSE_HOST` | `127.0.0.1` | ClickHouse host. |
| `CLICKHOUSE_TCP_PORT` | `9000` | Native-protocol port used by writer and queries. |
| `CLICKHOUSE_HTTP_PORT` | `8123` | HTTP port carried in ClickHouse configuration. |
| `KANSOKU_CLICKHOUSE_SECURE` | `false` | Verify TLS certificates and hostname for every native writer/query connection. Set `true` with the endpoint's explicit native TLS port; no plaintext fallback. |
| `KANSOKU_CLICKHOUSE_DATABASE` | `analytics` | ClickHouse database containing Kansoku tables and views. |
| `KANSOKU_CLICKHOUSE_USER` | `default` | ClickHouse user. |
| `KANSOKU_CLICKHOUSE_PASSWORD` | empty | ClickHouse password. |
| `KANSOKU_CH_QUERY_POOL_SIZE` | `4` | Positive number of ClickHouse query connections. |
| `KANSOKU_SERVER_PORT` | `8080` | HTTP listener port. |

The Nix development shell sets local database paths and ports automatically. Outside it, set the
PostgreSQL and ClickHouse variables explicitly and apply both migration systems before server
startup.

## ClickHouse migration administration

The native CLI loads these only for live commands; `plan` needs no database or credentials.
There is no ambient/default target identity. The [runbook](clickhouse-migrations.md) describes
first use, retained bindings and explicit recovery.

| Variable | Requirement | Purpose |
| --- | --- | --- |
| `KANSOKU_CH_MIGRATION_TARGET` | Required | Stable application target key. |
| `KANSOKU_CH_MIGRATION_ENDPOINT` | Required direct HTTP(S) origin, or explicit host/HTTP-port pair | Administrative endpoint; no proxy, Cloud or failover alias. |
| `KANSOKU_CH_MIGRATION_SERVER_ID` | Required | Retained expected lowercase server UUID; never rediscover it on every run. |
| `KANSOKU_CH_MIGRATION_LEDGER_ID` | Required | Operator-retained lowercase UUID, including interrupted initialization. |
| `KANSOKU_CH_MIGRATION_SESSION` | Required for guarded/mutating native entries and finish | Persistent PostgreSQL session UUID returned by maintenance begin. |
| `PG_CONNECTION_STRING` | Required for coordination | Same migrated PostgreSQL target used for traffic admission and existing administration. |
| `KANSOKU_CLICKHOUSE_USER` | Defaults to `default` | Explicit migration operator; retain reader-view definer privileges. |
| `KANSOKU_CLICKHOUSE_PASSWORD` | Must be set, may be empty for an owned local fixture | Never included in rendering or coordination state. |

The endpoint fallback requires both `KANSOKU_CLICKHOUSE_HOST` and `CLICKHOUSE_HTTP_PORT`.
Native TLS uses the system CA store, or the trusted bundle selected by `SSL_CERT_FILE`.
For example, a provider's native endpoint on 9440 needs both
`KANSOKU_CLICKHOUSE_SECURE=true` and `CLICKHOUSE_TCP_PORT=9440`. The migration endpoint
is independent: configure `KANSOKU_CH_MIGRATION_ENDPOINT=https://host:8443` explicitly
when its HTTP interface requires TLS. Enabling native TLS does not qualify a migration
server version or topology; see [verified native TLS](../adr/0023-verified-tls-for-native-clickhouse-connections.md).
The ledger namespace is fixed to `kansoku_migration_ledger`, separate from analytics. First use
also requires `--initialize-ledger UUID`; recurring runs bind the existing ledger and refuse to
create missing history. `--predecessor ENTRY`, `--quiescent` and audit/evidence arguments bind
an entry to its retained session and external drain procedure. Environment settings alone grant
neither initialization nor recovery authorization. `maintenance status` can find an active
session from its retained target/server/ledger binding if begin lost its response.

## Queue and writer settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `KANSOKU_QUEUE_NAME` | `kansoku_events` | PGMQ queue provisioned idempotently at startup. |
| `KANSOKU_WRITER_MAX_BATCH` | `5000` | Maximum events combined into one ClickHouse insert. |
| `KANSOKU_WRITER_MAX_LATENCY_MS` | `5000` | Maximum batch accumulation latency in milliseconds. |
| `KANSOKU_WRITER_VT_SEC` | `60` | PGMQ visibility timeout in seconds while processing a delivery. |
| `KANSOKU_WRITER_ADAPTER_BATCH` | `1000` | Messages requested from the queue per adapter read. |
| `KANSOKU_QUEUE_POLL_INTERVAL_SEC` | `15` | Positive queue-depth sampling interval in seconds. |

Tune these as one pipeline. A visibility timeout must comfortably exceed normal ClickHouse flush
time. Larger batches improve insertion efficiency but increase memory use and worst-case
latency. The writer and queue-depth poller are supervised with the HTTP process; an unexpected
exit brings down the server rather than leaving a write-only or read-only partial process.

## Ingestion and browser settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `KANSOKU_CORS_ORIGINS` | unset / `*` | Allow all browser origins. Otherwise, a comma-separated exact origin allowlist. |
| `KANSOKU_INGEST_MAX_BODY_BYTES` | `5242880` | Positive maximum request body size; default is 5 MiB. |
| `KANSOKU_INGEST_MAX_BATCH_LENGTH` | `500` | Positive maximum events in one parsed batch. |
| `KANSOKU_INGEST_RATE_PER_SEC` | `2000` | Nonnegative submitted events per second per credential per process; zero disables admission limits. |
| `KANSOKU_INGEST_RATE_BURST` | `10000` | Token-bucket burst; when enabled must cover the maximum batch length. |
| `KANSOKU_INGEST_FUTURE_TOLERANCE_SEC` | `86400` | Nonnegative future offset clamped when no usable `sentAt` exists; zero disables clamping. |
| `KANSOKU_INGEST_QUARANTINE` | `false` | Enable best-effort capture of declared-schema rejections. |
| `KANSOKU_INGEST_QUARANTINE_RETENTION_DAYS` | `14` | Positive diagnostic retention in days. |
| `KANSOKU_INGEST_QUARANTINE_MAX_ROWS` | `10000` | Positive per-account row cap, enforced by hourly cleanup. |
| `KANSOKU_INGEST_QUARANTINE_MAX_PAYLOAD_BYTES` | `16384` | Payload cap of at least 2 bytes; oversized payloads become `{}` with truncation and byte-count metadata. |

For production browser ingestion, set exact scheme/host/port origins, for example:

```bash
export KANSOKU_CORS_ORIGINS='https://app.example.com,https://www.example.com'
```

Admission charges all submitted events, including schema-invalid events and equal retries, after
authentication and bounded decoding. Single and batch share each credential bucket. Bucket state
is atomic, capped at 10000 credentials, and evicted only after idle full-refill time (at least
60 seconds). A new credential at capacity receives 429 until state can expire. Multiple server
processes have independent limits; enforce outer request/byte limits at the proxy.

CORS exposes `Retry-After`. It covers `/v1/*` only and permits `GET`, `POST`, `Content-Type`, `X-Api-Key`, and
`Authorization`. Analytics metrics and operational endpoints are not CORS-enabled. CORS is not
an access-control substitute; ingestion authentication remains mandatory.

## Readiness and internal metrics

| Variable | Default | Purpose |
| --- | --- | --- |
| `KANSOKU_INTERNAL_METRICS_ENABLED` | `true` | Serve Prometheus text at `/internal/metrics`; accepts `true`, `false`, `1`, or `0`. |
| `KANSOKU_READY_MAX_QUEUE_DEPTH` | `100000` | Non-negative queue depth above which readiness fails. |
| `KANSOKU_READY_MAX_FLUSH_AGE_SEC` | `120` | Positive maximum age of the last successful flush while backlog exists. |

Queue samples older than three poll intervals do not drive the depth or flush-age failures;
PostgreSQL reachability has its own readiness check. Disable the metrics route if it cannot be
restricted at the network or reverse-proxy layer.

## Trace export

With neither `OTEL_EXPORTER_OTLP_ENDPOINT` nor `OTEL_TRACES_EXPORTER` set, Kansoku uses a no-op
tracer and makes no exporter connection. Setting either opts into the OpenTelemetry SDK. Standard
OpenTelemetry exporter variables then select and configure OTLP or the registered `console`
exporter. For a collector deployment, set its endpoint before starting Kansoku, for example:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT='http://otel-collector:4318'
export OTEL_TRACES_EXPORTER='otlp'
```

Validate exporter names and transport settings in the deployment environment; a trace exporter
is operational infrastructure and is not part of the public Kansoku API.

`OTEL_SDK_DISABLED=true` takes precedence over configured trace and metric export.
Set `OTEL_SERVICE_NAME=kansoku` and use `OTEL_RESOURCE_ATTRIBUTES` for deployment
identity. Sampling follows `OTEL_TRACES_SAMPLER` and `OTEL_TRACES_SAMPLER_ARG`
(for example `parentbased_traceidratio` with `0.1`). Development with no exporter
selection or OTLP endpoint performs no network export. `OTEL_TRACES_EXPORTER=console`
supports collector-free validation and flushes on exit.

The HTTP instrumentation captures providers once during startup. Optional OTel HTTP
metric export requires `OTEL_METRICS_EXPORTER=otlp`; it is separate from the built-in
Prometheus pipeline scrape. The base OTLP HTTP endpoint is normally port 4318; the
exporter appends `/v1/traces` or `/v1/metrics` for each signal. Set the base endpoint,
not a trace-specific path. `OTEL_SEMCONV_STABILITY_OPT_IN=http` selects stable HTTP
names, `http/dup` emits both names, and unset retains legacy names. In every mode,
HTTP query values are removed before attribute capture. Access JSON is independent
of exporter configuration; see [operations](operations.md#traces) for its fixed fields.

## A minimal non-development environment

```bash
export PG_CONNECTION_STRING='postgresql://kansoku:secret@postgres.example/kansoku'
export KANSOKU_CLICKHOUSE_HOST='clickhouse.example'
export CLICKHOUSE_TCP_PORT='9000'
export CLICKHOUSE_HTTP_PORT='8123'
export KANSOKU_CLICKHOUSE_DATABASE='analytics'
export KANSOKU_CLICKHOUSE_USER='kansoku'
export KANSOKU_CLICKHOUSE_PASSWORD='replace-me'
export KANSOKU_CORS_ORIGINS='https://app.example.com'
export KANSOKU_INTERNAL_METRICS_ENABLED='true'
```

Keep secrets in the deployment platform's secret store, not a checked-in environment file. Use
TLS and network policy at the load balancer/database layer; the current Warp listener does not
terminate TLS itself.

[Operate Kansoku](operations.md) describes migrations, probes, metrics, key revocation, and
recovery.

[Documentation index](../README.md)

The probe endpoints are `/health/live` and `/health/ready`. Probe timeouts are fixed operational limits: 2 seconds
for each complete probe and 750 ms for each external readiness check, including pool
wait and disposal. They do not impose an analytics-query duration policy. ClickHouse
query reachability is checked independently of the writer and queue thresholds.


## Metric execution budgets

| Variable | Default | Purpose |
| --- | --- | --- |
| `KANSOKU_METRICS_MAX_EXECUTION_SEC` | `30` | Positive whole seconds for the complete metrics request, including pool wait and identity preparation; also set on native queries. |
| `KANSOKU_METRICS_MAX_MEMORY_BYTES` | `536870912` | Positive native-query memory cap, including subqueries. Cold identity preparation uses at most the smaller of this value and 256 MiB per construction query. |

Budget failures return non-retryable 400 `query_resource_limit` and no partial result. They
dispose failed connections and their temporary identity snapshots. The independent 10000-point
result cap still applies. Resident identity Join tables have separate bounded per-connection
footprints described in [operations](operations.md); per-query memory is not a process-wide
or deployment-wide memory quota.

## Optional country enrichment

Geography is off unless both `KANSOKU_INGEST_GEOIP_DB` (a readable supported country/city
MMDB path) and `KANSOKU_INGEST_TRUSTED_PROXY_CIDRS` (comma-separated explicit IPv4/IPv6 CIDRs)
are configured. Missing/invalid paired configuration or a corrupt/unsupported configured
file fails startup. The locked Nix environment supplies the reader automatically.
[Web enrichment](web-enrichment.md) describes the trust chain, missing-country behavior,
versioned classifications and request-address privacy boundary.

## Administrative retention

`KANSOKU_EVENTS_RETENTION_DAYS` is read by `kansoku-admin apply-retention`; 0/unset means
unlimited event retention. Values must be nonnegative and at most 36500. Setting it does not
run maintenance at startup. Preview and explicitly confirm the applied cutoff; schedule the
command for periodic advancement. Each confirmed run also applies the separate 180-day
fingerprint cleanup. [Administration](administration.md) describes profiles, source payloads,
permanent identities, failure fences and the diagnostic-retention boundary.
