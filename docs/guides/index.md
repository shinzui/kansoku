---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Explanation

- [Web enrichment and acquisition](web-enrichment.md) - Understand preserved web enrichment, first-touch acquisition, versioned device and bot classifications, and trusted optional country lookup.

# Guide

- [Measure pipeline capacity](capacity.md) - Measure pipeline outage and recovery capacity, size a finite storage budget, and set alerts from the recorded workload.
- [Consume ClickHouse from a trusted analytics tool](consume-clickhouse.md) - Configure a trusted ClickHouse reader and use supported projections and recipes with dashboard and experiment consumers.
- [Reproduce the external consumer gate](consumer-conformance.md) - Reproduce the pinned external-consumer release gate and ordinary SDK adoption and recovery proof in owned environments.
- [Develop Kansoku](development.md) - Build and test Kansoku, follow source conventions, regenerate contracts, and run isolated acceptance gates.
- [Use the Haskell SDK](haskell-sdk.md) - Integrate the buffered Haskell producer SDK and typed clients with explicit schema versions, retries, identity helpers and trait writes.
- [Send events](send-events.md) - Send authenticated single, batch or beacon events with governed schemas, identity signals, immutable event IDs and correct retry handling.

# Reference

- [Configure Kansoku](configuration.md) - Look up database, server, writer, ingestion, readiness, telemetry, query-budget and retention configuration.
- [Query metrics](query-metrics.md) - Look up metric populations, query bounds, filters, grouping, analytical semantics, cohorts and saved definitions.

# Runbook

- [Administrative operations](administration.md) - Issue and revoke credentials, inspect rejected events, and preview or resume fenced erasure, retention and archive maintenance.
- [Operate Kansoku](operations.md) - Operate migrations, credentials, probes and telemetry, diagnose pipeline failures, and coordinate recovery and data maintenance.

# Tutorial

- [Run Kansoku locally](getting-started.md) - Start Kansoku locally, migrate both stores, issue credentials, send an event, and query it before rehearsing reuse and recovery.

