---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Architecture Decision Record

- [SDK-grade ingest contract boundaries](0001-sdk-grade-ingest-contract-boundaries.md) - Accept syntactically valid ingest batches partially, cap request size and count, and scope CORS to /v1/* so SDKs get stable retry semantics.
- [Pipeline observability, readiness, and writer recovery](0002-pipeline-observability-readiness-and-writer-recovery.md) - Add OpenTelemetry tracing, Prometheus pipeline metrics, ordered readiness checks, and logical writer-connection recovery for the PGMQ-to-ClickHouse pipeline.
- [API-key authentication and account-scoped analytics](0003-api-key-authentication-and-account-scoped-analytics.md) - Require write-key or service-token bearer authentication on ingest and metrics routes, scoped to an account, via SHA-256-hashed credentials.
- [Queryable event properties and identity-resolved projection](0004-queryable-event-properties-and-identity-resolved-projection.md) - Store event properties as native ClickHouse JSON and expose them for metric grouping only after registry declaration.
- [Evidence-based multi-signal identity resolution](0005-evidence-based-multi-signal-identity-resolution.md) - Resolve identity at query time from evidence-based multi-signal identifier bindings instead of a latest-wins cookie-to-user map.
- [Exposure-based experiment analytics](0006-exposure-based-experiment-analytics.md) - Define exposure-based experiment analytics using an approximate daily rollup for exposure counts and exact query-time resolution for conversion and funnels.
- [Versioned event schema governance and publication](0007-versioned-event-schema-governance-and-publication.md) - Govern event schemas as immutable, contiguous versions authored in the Haskell registry, with accepted events recording the schema version they matched.
- [RFC 9457 problem details and generated-client media](0008-rfc9457-problem-details-and-generated-client-media.md) - Use one RFC 9457 error shape and explicit per-response media types across typed handlers, authentication, framework failures, and generated clients.
- [Bounded complete aggregate responses](0009-bounded-complete-aggregate-responses.md) - Bound metric inputs and final aggregate cardinality, returning a complete answer or a permanent problem instead of cursor pages over changing aggregates.
- [Owned executable acceptance environments](0010-owned-executable-acceptance-environments.md) - Gate service changes with deterministic checks and required integration against the Nix executable in fresh owned database processes.
- [Initial release analytics contracts](0011-initial-release-analytics-contracts.md) - Establish coherent event identity, analytical populations and lifecycle boundaries before the first Kansoku deployment.
- [Server enrichment and first-touch web acquisition](0012-server-enrichment-and-first-touch-web-acquisition.md) - Preserve categorical request enrichment in a private versioned queue envelope and assemble complete retained web sessions before acquisition selection.
- [Whole retained replay-safe web sessions](0013-whole-retained-replay-safe-web-sessions.md) - Merge idempotent session state before date and attribute selection so counts, bounce, duration and acquisition share one retained population.
- [Closed-day exact activity and retained-history cohorts](0014-closed-day-exact-activity-and-retained-history-cohorts.md) - Use exact canonical activity populations across rolling users, stickiness, retention and lifecycle with closed UTC observation days and explicit retained-history limits.
- [Deterministic selected funnel chains and exclusive exposure diagnostics](0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md) - Share one deterministic chain evaluator for funnel counts, timing and ordered signup conversion; separate experiment contamination from exclusive first-observed assignment shares.
- [Governed current user traits and replay-safe erasure](0016-governed-current-user-traits-and-replay-safe-erasure.md) - Persist first-acceptance schema eligibility for typed current traits, join only resolved users, attribute whole sessions before segmentation, and reserve erased source IDs before rebuilding state.
- [Fenced resumable administration and applied retention](0017-fenced-resumable-administration-and-applied-retention.md) - Coordinate cross-store jobs with persisted fences, protect stale writer batches with permanent event dispositions, replay archives transactionally, and rebuild current projections under one applied retention cutoff.
- [Stable reader SQL and real consumer conformance](0018-stable-reader-sql-and-real-consumer-conformance.md) - Expose explicit versioned single-tenant projections through constrained reader privileges and verify supported consumers against the packaged database.
- [Saved query-time cohorts and static membership](0019-saved-query-time-cohorts-and-static-membership.md) - Keep account-scoped definitions in PostgreSQL and compute identified-user membership from bounded resolved events or versioned static ClickHouse facts.
- [Custom metric definitions and bounded OR filters](0020-custom-metric-definitions-and-bounded-or-filters.md) - Compile account-scoped saved and ad-hoc metric definitions through the builtin query rules, with bounded alternatives inside each conjoined filter group.
