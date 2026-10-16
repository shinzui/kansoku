---
type: Capability
title: "Operational probes and telemetry"
description: "Expose dependency-aware readiness, liveness, pipeline metrics and bounded correlated request telemetry for operating the service."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-17
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "GET /health/live"
  - "GET /health/ready"
  - "GET /internal/metrics"
  - "OTLP trace export"
  - "JSON request logs"
tags: [operations]
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/HealthSpec.hs"
    proves: "Checks readiness failure onset, recovery, native deadlines, cancellation and production HTTP assembly."
  - kind: test
    resource: "kansoku-core/test/Kansoku/ObservabilitySpec.hs"
    proves: "Checks exported metric families and successful writer flush observations."
  - kind: conformance
    resource: "scripts/http-telemetry.py"
    proves: "Defines trace and access-log privacy/contract checks."
---

# Operational probes and telemetry

Keep process liveness separate from ordered writer, PostgreSQL, ClickHouse, backlog and flush-freshness checks. Export Prometheus queue/writer/admission telemetry, correlated JSON access logs and explicitly configured OpenTelemetry HTTP/writer traces. See [operations](../guides/operations.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Operational routes are unauthenticated and need deployment network policy. Backlog readiness uses sampled values. Traces and OTel metric export are opt-in; request bodies, credentials and query values are excluded. Writer batches do not claim parentage to an individual ingest request.

## Evidence

- [HealthSpec.hs](../../kansoku-core/test/Kansoku/HealthSpec.hs) — Checks readiness failure onset, recovery, native deadlines, cancellation and production HTTP assembly.
- [ObservabilitySpec.hs](../../kansoku-core/test/Kansoku/ObservabilitySpec.hs) — Checks exported metric families and successful writer flush observations.
- [http-telemetry.py](../../scripts/http-telemetry.py) — Defines trace and access-log privacy/contract checks.
