# Run Kansoku locally

This guide starts a development instance, creates one account's credentials, sends a valid
`page_view`, and reads it through the metrics API. Kansoku currently ships as source plus a Nix
development environment; the repository does not yet publish a container image or a hosted
service.

## Prerequisites

Install [Nix](https://nixos.org/download/) with flakes enabled. The development shell provides
GHC 9.12, Cabal, PostgreSQL, ClickHouse, `just`, `jq`, and `process-compose`.

Clone the repository, enter it, and open three terminals in that directory. Run `nix develop`
once in each terminal before using the commands below.

## 1. Start PostgreSQL and ClickHouse

In terminal 1:

```bash
nix develop
just up
```

`just up` runs `process-compose.yaml`. It starts rootless PostgreSQL and ClickHouse instances
whose data stays inside the checkout, then creates the local PostgreSQL database. Leave this
terminal running.

## 2. Apply both migration systems

In terminal 2:

```bash
nix develop
just migrate
just ch-migrate
```

`just migrate` applies the explicit PostgreSQL plan: the vendored PGMQ queue schema and
Kansoku's API-key table. `just ch-migrate` applies forward-only ClickHouse migrations and records
them in `analytics.schema_migrations`. Normal `kansoku-server` startup does not perform either
schema migration.

Both commands are safe to repeat after a successful run. Do not use `just ch-reset` for ordinary
startup: it is a destructive development command that drops all ClickHouse analytics data.

This is the fresh-install path. If a reused checkout already has a PGMQ schema from a Kansoku
version that predates the current pg-migrate ledger, preserve that database and follow the
[legacy migration note](operations.md#legacy-postgresql-installations) instead of retrying or
dropping it.

## 3. Issue credentials

Create a browser/backend write key and a service token for the same account:

```bash
just issue-key write dev "quickstart writer"
just issue-key service dev "quickstart reader"
```

Each command prints an ID, then the credential, then a reminder that the credential cannot be
shown again. Save the two values in terminal 3:

```bash
export KANSOKU_WRITE_KEY='ksk_w_replace_with_the_printed_write_key'
export KANSOKU_SERVICE_TOKEN='ksk_s_replace_with_the_printed_service_token'
```

Credentials are always required for analytics operations. A write key can ingest. A service
token can ingest and query metrics. Each credential belongs to exactly one account, and Kansoku
uses that account even if an event body supplies a different `accountId`.

## 4. Start Kansoku

Back in terminal 2:

```bash
just run
```

The default address is `http://localhost:8080`. Confirm that the process and its dependencies
are ready from terminal 3:

```bash
curl --fail --silent http://localhost:8080/health
curl --fail --silent http://localhost:8080/ready | jq .
```

The health response is `OK`. A ready response has `"status": "ready"` and four successful
checks: `writer_alive`, `pgmq_reachable`, `queue_depth`, and `writer_flush_stale`.

## 5. Send an event

The following event conforms to version 1 of the published `page_view` schema:

```bash
curl --fail-with-body \
  --request POST http://localhost:8080/v1/events \
  --header "X-Api-Key: $KANSOKU_WRITE_KEY" \
  --header 'Content-Type: application/json' \
  --data '{
    "eventId": "quickstart-page-view-001",
    "eventName": "page_view",
    "schemaVersion": 1,
    "source": "web",
    "occurredAt": "2026-07-20T12:00:00Z",
    "receivedAt": "2026-07-20T12:00:00Z",
    "anonymousId": "quickstart-browser",
    "sessionId": "quickstart-session",
    "url": "https://example.test/docs",
    "properties": {"url": "https://example.test/docs"},
    "context": {"example": "quickstart"}
  }' | jq .
```

Kansoku returns HTTP 202 with:

```json
{
  "accepted": 1,
  "eventId": "quickstart-page-view-001"
}
```

The server replaces `receivedAt` with its current time and stamps the authenticated account
before validation and enqueueing. The writer moves the event from PostgreSQL to ClickHouse
asynchronously, normally within the default five-second flush interval.

## 6. Query the event

After the writer has flushed, query the same half-open UTC date range: `from` is inclusive and
`to` is exclusive.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/events \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-20' \
  --data-urlencode 'to=2026-07-21' \
  --data-urlencode 'timeGrain=day' | jq .
```

The response has metric name `events` and at least one point for `2026-07-20` in a fresh `dev`
account:

```json
{
  "metric": "events",
  "points": [
    {"bucket": "2026-07-20", "group": {}, "value": 1}
  ]
}
```

If the first query returns an empty `points` array, wait for the writer's next flush and retry.
If the account already contains data, `value` may be greater than 1.

## Next steps

- [Send events](send-events.md) explains every field, batch behavior, identity, and retries.
- [Query metrics](query-metrics.md) lists the implemented metrics and their semantics.
- [Configure Kansoku](configuration.md) covers non-development database and runtime settings.
- [Operate Kansoku](operations.md) covers readiness, telemetry, migrations, and recovery.

[Documentation index](../README.md)
