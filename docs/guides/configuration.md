# Configure Kansoku

`kansoku-server`, `kansoku-migrate`, and credential issuance read environment variables. Invalid
integer, Boolean, or positive-only values stop startup with a configuration error. There is no
authentication-off mode.

## Database and server settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `PG_CONNECTION_STRING` | `postgresql:///kansoku` | PostgreSQL URI used for PGMQ and API keys. |
| `KANSOKU_CLICKHOUSE_HOST` | `127.0.0.1` | ClickHouse host. |
| `CLICKHOUSE_TCP_PORT` | `9000` | Native-protocol port used by writer and queries. |
| `CLICKHOUSE_HTTP_PORT` | `8123` | HTTP port carried in ClickHouse configuration. |
| `KANSOKU_CLICKHOUSE_DATABASE` | `analytics` | ClickHouse database containing Kansoku tables and views. |
| `KANSOKU_CLICKHOUSE_USER` | `default` | ClickHouse user. |
| `KANSOKU_CLICKHOUSE_PASSWORD` | empty | ClickHouse password. |
| `KANSOKU_CH_QUERY_POOL_SIZE` | `4` | Positive number of ClickHouse query connections. |
| `KANSOKU_SERVER_PORT` | `8080` | HTTP listener port. |

The Nix development shell sets local database paths and ports automatically. Outside it, set the
PostgreSQL and ClickHouse variables explicitly and apply both migration systems before server
startup.

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

For production browser ingestion, set exact scheme/host/port origins, for example:

```bash
export KANSOKU_CORS_ORIGINS='https://app.example.com,https://www.example.com'
```

CORS covers `/v1/*` only and permits `GET`, `POST`, `Content-Type`, `X-Api-Key`, and
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

Canonical probes are `/health/live` and `/health/ready`; `/health` and `/ready`
remain compatibility routes. Probe timeouts are fixed operational limits: 2 seconds
for each complete probe and 750 ms for each external readiness check, including pool
wait and disposal. They do not impose an analytics-query duration policy. ClickHouse
query reachability is checked independently of the writer and queue thresholds.
