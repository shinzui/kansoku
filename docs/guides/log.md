# Bundle Update Log

## 2026-11-01

* **Update**: Remove legacy probe routes from operator instructions and document the canonical replacements and HTTP 404 behavior.

## 2026-10-17

* **Update**: Correct DOC-7 checkout reuse and DOC-9 interrupted migration recovery after native adoption; expand DOC-13 with retained-identity reload, recurring execution and fresh recovery counters. Preserve original SQL as evidence rather than a replay procedure.

## 2026-10-16

* **Update**: Document PostgreSQL-first native initialization, retained identities, explicit sessions/drain/repair and qualification limits; add DOC-13 migration runbook.

* **Update**: Document current organization traits inside saved cohort event conditions, including nullable filters and fixed event attribution.

* **Update**: DOC-6: document the fixture-isolation gate and scenario-owned saved-resource cleanup convention.

* **Update**: DOC-11: document compatible JSON shapes, permanent storage-path rejections and correction under an unclaimed event ID.

* **Migration**: Adopt the frozen v0.20.0 [user-documentation profile](mori://shinzui/okf-profiles/profiles/user-documentation), targeting OKF 0.2, for the 12 existing pages in `docs/guides/`. Allocate DOC-1 through DOC-12 in lexical filename order. Preserve every original page body, H1 and URL; classify by dominant reader intent without splitting mixed-purpose pages.
* **Provenance**: Keep each page’s last meaningful Git content revision as `generated.at`, normalized to UTC. The inspected commits change content, not just formatting. Map the historical `codex-cli` implementation sessions in the linked ExecPlans to the repository’s established `process:codex` actor, also used by their companion ADRs. Git’s human author identity is not used as evidence of human prose authorship. The metadata migration does not restamp content or assert independent verification.
* **Integration**: Generate the bundle index, declare the `guides` bundle and pinned publisher binding in `mori.dhall`, link the catalog from the documentation entry point, and include strict profile/log validation in `just check`.

The following table records the content and actor evidence used for adoption:

| Page | ID | Primary intent | Content revision UTC | Git commit | Implementation provenance |
| --- | --- | --- | --- | --- | --- |
| [administration.md](administration.md) | DOC-1 | Runbook | `2026-10-16T03:20:35Z` | `562b4c864f0b` | [37-administrative-executable-for-keys-erasure-retention-and-replay.md](../../docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md) |
| [capacity.md](capacity.md) | DOC-2 | Guide | `2026-10-16T05:27:26Z` | `e0eb7820d941` | [38-single-tenant-consumption-guide-for-dashboards-and-experiments.md](../../docs/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments.md) |
| [configuration.md](configuration.md) | DOC-3 | Reference | `2026-10-16T03:01:19Z` | `ba403e263c33` | [37-administrative-executable-for-keys-erasure-retention-and-replay.md](../../docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md) |
| [consume-clickhouse.md](consume-clickhouse.md) | DOC-4 | Guide | `2026-10-16T13:03:13Z` | `0c48895a8b8b` | [45-organisation-and-b2b-analytics.md](../../docs/plans/45-organisation-and-b2b-analytics.md) |
| [consumer-conformance.md](consumer-conformance.md) | DOC-5 | Guide | `2026-10-16T05:34:46Z` | `b0a548c34cb2` | [38-single-tenant-consumption-guide-for-dashboards-and-experiments.md](../../docs/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments.md) |
| [development.md](development.md) | DOC-6 | Guide | `2026-10-15T05:27:55Z` | `80769979c717` | [28-gate-service-releases-with-isolated-hurl-acceptance-and-ci.md](../../docs/plans/28-gate-service-releases-with-isolated-hurl-acceptance-and-ci.md) |
| [getting-started.md](getting-started.md) | DOC-7 | Tutorial | `2026-10-16T05:27:26Z` | `e0eb7820d941` | [38-single-tenant-consumption-guide-for-dashboards-and-experiments.md](../../docs/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments.md) |
| [haskell-sdk.md](haskell-sdk.md) | DOC-8 | Guide | `2026-10-16T01:18:47Z` | `81161553c95a` | [40-person-properties-set-and-set-once-user-traits.md](../../docs/plans/40-person-properties-set-and-set-once-user-traits.md) |
| [operations.md](operations.md) | DOC-9 | Runbook | `2026-10-16T03:01:19Z` | `ba403e263c33` | [37-administrative-executable-for-keys-erasure-retention-and-replay.md](../../docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md) |
| [query-metrics.md](query-metrics.md) | DOC-10 | Reference | `2026-10-16T13:03:13Z` | `0c48895a8b8b` | [45-organisation-and-b2b-analytics.md](../../docs/plans/45-organisation-and-b2b-analytics.md) |
| [send-events.md](send-events.md) | DOC-11 | Guide | `2026-10-16T03:45:04Z` | `3d0e3d8a81ce` | [39-beacon-ingest-route-for-page-exit-delivery.md](../../docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md) |
| [web-enrichment.md](web-enrichment.md) | DOC-12 | Explanation | `2026-10-15T22:32:50Z` | `e42fd1bd3002` | [33-acquisition-and-device-enrichment-with-bot-flagging.md](../../docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md) |
