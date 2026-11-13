# ClickHouse buffering qualification

[Plan 72](../../plans/72-keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md)
separates durable admission from ClickHouse delivery. Source checkpoint `d6330c9`
contains the runtime implementation, health contract, owned fixtures and tests.
Feature acceptance and native regressions passed. Production-version/image
qualification and publication remain pending. No local archive is a published
deployment input.

The normal development loop uses the Nix-provided native ClickHouse/Keeper
26.8.28.14 on Darwin arm64. Major qualification retains the exact Linux arm64
Altinity 26.3.60.10002.altinitystable fixture under Apple Container. These are
separate server/platform observations. Docker and Colima are not used for
ClickHouse. Application-image Linux amd64 execution is a separate boundary.

Run the packaged buffering harness from the repository root:

```bash
nix develop --no-write-lock-file -c just ch-buffering-acceptance
nix develop --no-write-lock-file -c just ch-buffering-acceptance --production-fixture
```

`--case startup|admission|recovery|mismatch` selects a focused development group;
omitting it executes all fifteen cases. `--package-output` binds a run to an
already-built immutable Nix output. Every case requires actual executable
migration, PostgreSQL persistence, HTTP admission and independent per-replica
readback. Missing prerequisites and zero selected cases fail. Private logs,
credentials, process inventories and raw migration receipts remain under
`.dev/acceptance/`; public JSON contains synthetic IDs and compact observations.

All fifteen packaged Nix cases passed with zero skips; see
[the consolidated report](acceptance-nix-all-packaged.json). In the five startup
cases, launch through persisted admission took less than 0.251 seconds,
including refused connections and stalled native handshakes. Admission remained
200 during delivery failure;
maintenance ingestion and PostgreSQL-failed readiness each returned 503.
Outage/mismatch cases observed zero unsafe INSERTs, retained exact accepted IDs
and drained after repair. Recovery verified exact IDs independently on each
replica. Only selector correction required an explicit server rollout.

Regression checks passed: `just check` (553 core, 23 client, four shared probe
tests, three seven-example telemetry modes and sixteen release-validator unit
tests), full packaged acceptance, all seventeen replicated migration fixture
cases, and all five replicated runtime groups. The writer group retained its
cross-replica lost-acknowledgement and expired-deduplication assertions. Direct
outage smoke accepted 8,000 events through a 52.8-second outage and writer
restart, then drained with zero valid archives. Detailed private logs remain in
`.dev/`; these Darwin/Nix results do not qualify the Linux application image or
the production-version Altinity fixture.

Use `/health/live` for liveness and `/health/ready` for PostgreSQL/PGMQ admission.
Monitor `/health/pipeline` for ClickHouse, topology, breaker and backlog failures.
Move former ClickHouse/backlog readiness alerts to pipeline health or metrics.
Keep finite PostgreSQL disk/WAL budgets and reserve drain capacity above ongoing
arrivals as described in [capacity guidance](../../guides/capacity.md). Metric
queries may return retryable 503 during outages. Deploy-time migration jobs still
need ClickHouse; the serving process applies no migrations. A selector change
requires a rollout retaining PostgreSQL messages; same-endpoint target repair
can recover in the running writer.
