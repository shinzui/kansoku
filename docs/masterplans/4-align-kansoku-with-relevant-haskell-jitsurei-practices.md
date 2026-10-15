---
id: 4
slug: align-kansoku-with-relevant-haskell-jitsurei-practices
title: "Align Kansoku with relevant Haskell Jitsurei practices"
kind: master-plan
created_at: 2026-10-15T03:10:58Z
intention: "intention_01m4yrkpeve8c8aktyqnqdftv0"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-15T03:10:58Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:29:25Z
      verdict: "changes-requested"
      note: "Assign query-pool cancellation/recovery ownership and the EP-24/EP-26 handoff; EP-25 needs span-export privacy coverage."
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T03:32:46Z
      mode: "implement"
      note: "Begin EP-23 implementation, preserving existing review notes."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:37:31Z
      mode: "update"
      note: "Apply review: assign EP-24 M2 pool recovery prerequisite, span privacy ownership and acceptance handoffs."
---

# Align Kansoku with relevant Haskell Jitsurei practices

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. Child ExecPlans own implementation milestones.


## Vision & Scope

Kansoku will expose a consistent, accurately documented error contract, distinguish process
liveness from readiness through the shared probe library, and make HTTP traffic observable
without recording credentials or payloads. Analytics requests will have explicit input and
result bounds. A reproducible acceptance command will build and start the actual executable,
exercise it over HTTP against isolated databases, and fail when contracts drift.

The baseline is the local catalog at `mori://shinzui/haskell-jitsurei`, revision `cce10bd`, and
Kansoku revision `0fdaeaf`, inspected on 2026-10-15 UTC. Reconcile source changes at the start
of every child. The intention is recorded in frontmatter. This document schedules work;
creation of these plans is not evidence that any implementation or acceptance has passed.

Included work is RFC 9457 problem documents, complete authentication response documentation,
the compatible OpenAPI dependency pair, shared health probes, HTTP tracing and safe access
logs, bounded complete metric answers, fatal missing-record-field diagnostics, focused
record-convention fixes, Hurl acceptance, and CI. RFC 9457 means the common JSON error shape
identified by `application/problem+json`; Hurl is an external HTTP assertion runner.

Preserve partial batch acceptance, account isolation, the durable queue and writer, the seven
Prometheus pipeline instruments, and the public schema catalog. Do not add event sourcing,
replace Prometheus, introduce a collector requirement for development, migrate the CLI to a
new configuration framework, create deployment infrastructure, or mass-reformat historical
plans. Relay pagination is not applied mechanically to computed metric series: EP-26 owns an
explicit, documented exception with hard bounds and complete-or-error semantics. Future
resource-list APIs must follow `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`.


## Decomposition Strategy

The six children each own one demonstrable behavior. Errors and generated clients must change
together; therefore EP-23 includes the OpenAPI upgrade and authentication documentation rather
than splitting those across plans. Shared probes precede request logging so the logger can
exclude actual probe paths. Query bounds are separate because aggregate correctness and
memory use require database-backed evidence. Core conventions have a narrow source-level
scope. The final child owns executable-level acceptance and the failing CI gate.

Relevant local decisions were read in [ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md)
(partial batches, body limits and CORS), [ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md)
(Prometheus, operational routes, readiness and connection recovery),
[ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) (credential transport,
revocation and tenancy), [ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
(property SQL and the shared projection), and
[ADR 6](../adr/0006-exposure-based-experiment-analytics.md) (exact and approximate metric semantics).
[ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md) also governs the
immutable schema catalog preserved by the convention and acceptance children. The children
repeat the context they need and update affected decisions when implemented.

Mori discovery also identified and resolved
`mori://shinzui/kotei/okf/adrs/concepts/ADR-1` and
`mori://shinzui/jinmyaku/okf/adrs/concepts/ADR-5`. They supply two relevant lessons: generated
clients need both success and problem media types admitted by the route, and shared probe
code should be consumed as a released library. Their resource pagination choices are not
silently imported into Kansoku's aggregate API.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 23 | Problem details and generated contract | [EP-23](../plans/23-standardize-problem-details-and-the-generated-api-contract.md) | None | None | Complete |
| 24 | Shared liveness and readiness | [EP-24](../plans/24-adopt-shared-liveness-and-readiness-probes.md) | EP-23 | None | Not Started |
| 25 | HTTP tracing and safe access logs | [EP-25](../plans/25-trace-http-requests-and-emit-safe-correlated-access-logs.md) | EP-24 | EP-23 | Not Started |
| 26 | Bounded analytics queries and results | [EP-26](../plans/26-bound-analytics-query-inputs-and-result-cardinality.md) | EP-23 | None | Not Started |
| 27 | Core record and route conventions | [EP-27](../plans/27-enforce-core-record-and-route-construction-conventions.md) | None | EP-23, EP-24, EP-25, EP-26 | Not Started |
| 28 | Isolated Hurl acceptance and CI | [EP-28](../plans/28-gate-service-releases-with-isolated-hurl-acceptance-and-ci.md) | EP-23, EP-24, EP-25, EP-26, EP-27 | None | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled. Every hard dependency
above names the entire child; it must be Complete before dependent implementation starts.


## Dependency Graph

Default execution order is EP-23, EP-24, EP-25, EP-26, EP-27, EP-28. EP-24 needs EP-23's
OpenAPI 5.x cohort because the released health library depends on it. EP-25 needs EP-24's
final probe paths and application assembly. EP-26 needs EP-23's error catalog and response
media types for bounded-query failures. After EP-23, EP-26 can proceed independently of the
probe and observability work if shared edits are coordinated. EP-27 can start immediately,
but doing it after the behavioral work avoids repeating record edits. EP-28 consumes all
final public and operational contracts; no temporary contract becomes its release gate.


## Integration Points

EP-23 owns `Kansoku.Api.Response`, the problem catalog, content-type admission, OpenAPI
schema conventions and the initial Cabal/Nix OpenAPI upgrades. EP-26 extends that catalog
with query-bound codes; every wire-changing child regenerates `docs/api/openapi.json` in
its own change. Do not defer contract regeneration to EP-28. EP-23's early interaction proof
is an actual generated Haskell client decoding a typed 400 problem response, followed by
auth rejection decoding and a body-limit response with browser CORS headers.

EP-24 owns the production application seam accepting injectable live and ready checks,
typed operational health routes, legacy probe compatibility and path inventory. It keeps
operational probes outside the customer-facing OpenAPI document. EP-25 wraps that assembled
application with WAI tracing and logging, uses the public analytics proxy for analytics route
annotations and the operational proxy for health annotations, and excludes every canonical
and compatibility probe path from access records. EP-28 reuses this same assembly through
the packaged executable. The first shared check is the probe test kit against production
assembly, not an unrelated miniature service.

EP-25 owns the bracketed telemetry lifecycle in `kansoku-server/app/Main.hs` and
`Kansoku.Telemetry`; pipeline Prometheus metrics keep their current ownership. EP-26 owns
query limits and explicit typed overflow errors; EP-28 seeds isolated high-cardinality data
to exercise them. EP-27 owns warning flags and schema-registry record names and must preserve
all generated wire artifacts byte-for-byte relative to its starting revision.

Each child owns its dependency additions in `cabal.project`, the package Cabal files and
unmanaged `flake.module.nix`. Keep Cabal and Nix on compatible released versions or the same
verified immutable commit. Do not edit Seihou-managed Nix modules for project customizations.
EP-28 owns `just check`, `just acceptance`, test tool additions, scripts and GitHub Actions.

Durable changes belong in ADRs as their owning child lands: EP-23 updates ADR-1 and ADR-3
and records the error catalog; EP-24 and EP-25 update ADR-2 with probe and telemetry decisions;
EP-26 records the aggregate-response exception and bounds; EP-28 records isolated acceptance
ownership if not already covered. Allocate new handles using the profiled OKF workflow in
`agents/skills/exec-plan/ADR.md`; do not invent IDs now or mark proposals Accepted prematurely.


## Progress

EP-23 is Complete, accepted on 2026-10-15. Its Cabal and Nix server/client builds pass,
core/client tests pass with optional live checks reported as pending, and generated artifacts
and strict ADR validation pass. The other five children remain Not Started. The current
implementation scope was EP-23 only. Required executable/storage acceptance remains owned
by EP-28; no passing live database gate is claimed here.


## Surprises & Discoveries

EP-23's released OpenAPI cohort builds under both Cabal and Nix. Its typed successes and
problems decode through real generated clients, while 401/403 auth rejections decode from
client-failure bodies. Later children must use `ProblemDetails`/`ProblemJSON` and preserve the
CORS and synchronous-exception boundary; `Kansoku.Exception` exposes cancellation-preserving
helpers. [ADR-8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md) records the
accepted error/media contract. Query-pool disposal and recovery remain owned by EP-24.

The catalog's prose is not sufficient dependency evidence. Hackage and upstream tags were
checked: the selected OpenAPI releases are 5.0.0 and 5.1.0; servant-health 0.1.0.0 is released
and requires the 5.x model. The Servant tracing fork's verified compatibility commit
`5e99a7857032484abc669076704dee4335e7d0ad` still exists on its feature branch, but remote
`main` has moved. Pin that compatibility commit rather than assuming the current checkout
or branch implements the catalog's API. EP-25 must prove it with the exact served proxies.


## Decision Log

On 2026-10-15, group RFC 9457, generated-client compatibility and OpenAPI dependency repair
into EP-23. One owner must prove the error's runtime body, media type and schema together.

On 2026-10-15, retain Prometheus pipeline metrics and operational-route separation, adopting
shared typed probes as a separate operational Servant surface. This preserves useful local
architecture while replacing handwritten probe rendering.

On 2026-10-15, choose bounded complete aggregate responses in EP-26 rather than cursor pages
of changing aggregates. This is an explicit deviation from the catalog's default collection
policy, requiring an ADR and boundary tests; it must not be reported as Relay compliance.

On 2026-10-15, keep production changes out of this planning change. ADR acceptance, dependency
edits and application implementation occur in the responsible child rather than during plan creation.


## Outcomes & Retrospective

To be filled during implementation and at completion. Completion requires every child and its
acceptance evidence, followed by ADR distillation across all six Decision Logs.
