---
id: 24
slug: adopt-shared-liveness-and-readiness-probes
title: "Adopt shared liveness and readiness probes"
kind: exec-plan
created_at: 2026-10-15T03:10:58Z
intention: "intention_01m4yrkpeve8c8aktyqnqdftv0"
master_plan: "docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-15T03:10:58Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:29:26Z
      verdict: "changes-requested"
      note: "Specify cancellation-safe query-pool recovery and prove native driver timeout/reconnect behavior before relying on 750ms check bounds."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:37:31Z
      mode: "update"
      note: "Specify native timeout/recovery proof, failed-connection disposal, driver repair ownership and EP-26 handoff."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T04:15:16Z
      mode: "implement"
      note: "Implement production probe assembly and bounded native connection lifetime."
---

# Adopt shared liveness and readiness probes

This ExecPlan is a living document. Update its living sections and durable ADRs as work proceeds.


## Purpose / Big Picture

Operators will use `/health/live` to test process responsiveness and `/health/ready` to decide
whether Kansoku should receive traffic. Dependency outages will fail readiness without failing
liveness. Both endpoints will use the released probe contract, bounded checks and stable failure
onset, demonstrated against actual application assembly with the library's test kit.


## Progress

- [x] (2026-10-15) M1: Shared typed probes and production assembly pass the independent live/ready failure matrix. Four test-kit cases plus the both-failing production HTTP check pass.
- [x] (2026-10-15) M2: Native timeout/cancellation and query-pool recovery pass the early failure proof; real checks retain bounded behavior and diagnostic compatibility routes. The isolated required-native command passes four examples in 7.72 seconds; repeated stalls and cancellation leave zero active proxy connections before recovery.
- [x] (2026-10-15) M3: Operations documentation, probe exclusions and separate contract tests agree with the final routes. Public OpenAPI regenerates without a diff; strict ADR validation and the Nix server build pass.


## Surprises & Discoveries

Source review found that `withQueryConnection` catches exceptions inside its pool callback,
so a failed opaque handle is returned for reuse before the exception is rethrown. The pinned
driver also reconnects during exception cleanup, including timeout interruption. The native proof confirmed these defects and now passes with the minimal vendored
compatibility repair. Both build systems consume `vendor/ClickHaskell`, copied from
`mori://KovalevDima/ClickHaskell/packages/ClickHaskell` v1.1.0 revision
`4524fbdd08cd0cf4a3468180323cbf6c4cf5667b`. Hackage preferred versions and upstream
tags still identify 1.1.0 as current. The repair adds close and closes failed initial
handshakes, invalidates failed handles and removes synchronous reconnect on unwind.
`vendor/ClickHaskell/KANSOKU.md` describes its exact scope. The callback signature is
unchanged; errors now escape after physical disposal.


## Decision Log

On 2026-10-15, mount a typed operational Servant API separately from the customer-facing
analytics API. Keep `/health` and `/ready` as documented compatibility endpoints during this
initiative; retain `/ready`'s detailed check array for operators. Canonical probes use the shared
fixed wire type. This preserves useful diagnostics without reimplementing shared status mapping.

On 2026-10-15, check ClickHouse query reachability as well as queue/writer health in readiness,
because this executable directly serves metrics reads. Do not make ClickHouse a liveness check.
The durable queue still buffers writer outages; no extra unrelated downstream service is probed.

On 2026-10-15, assign query-pool disposal and cancellation ownership to this child. Its M2
native proof is a hard prerequisite for the bounded-query child. Reject a timeout wrapper that
returns promptly only by abandoning an unbounded background operation or leaking a connection.


## Outcomes & Retrospective

The typed production probes, stable failure onset, bounded service checks and physical
query-pool disposal are implemented. The core suite passes 152 examples (21 optional
storage cases pending when databases are absent); the separate four-case probe kit
passes. Required native evidence uses its own isolated database and has zero pending
cases. Documentation, strict ADR validation and the Nix server build pass. All three milestones are accepted; EP-26 can consume the unchanged query callback interface with physical disposal before error classification.


## Context and Orientation

`kansoku-core/src/Kansoku/Server.hs` currently handles `/health`, `/ready`, `/openapi.json`
and `/internal/metrics` outside public Servant routing. `ReadyProbe` injects writer state,
PGMQ reachability and pipeline threshold evaluation. `kansoku-core/src/Kansoku/Readiness.hs`
contains pure threshold logic; missing/stale samples disable backlog checks while independent
PGMQ reachability remains authoritative. `kansoku-server/app/Main.hs` assembles these checks
from supervised writer state, the PostgreSQL pool and poller cells. Query reads use their own
bounded pool from `kansoku-core/src/Kansoku/ClickHouse.hs`.

[ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) requires four ordered
legacy readiness diagnostics, Prometheus pipeline metrics, and operational endpoints outside
public OpenAPI and ingest CORS/body handling. Extend this ADR with the canonical probe contract,
query-readiness check and bounded-failure behavior. Do not quietly erase old diagnostics or add
operational probes to `kansoku-api/src/Kansoku/Api.hs`.

Read `mori://shinzui/haskell-jitsurei/docs/api-health-endpoints` and locate dependencies through
Mori. `mori://shinzui/servant-health/packages/servant-health` supplies `HealthApi`,
`ProbeCheck = IO ProbeVerdict`, `healthServer` and path constants. Its Check module supplies
`safeCheck`, `withProbeTimeout`, `sequenceChecks` and `newFailureTracker`.
`mori://shinzui/servant-health/packages/servant-health:testkit` supplies Tasty tests, whereas
Kansoku currently uses Hspec. Add a separate small Tasty test executable rather than migrating
the existing test framework. Hackage and upstream v0.1.0.0 were verified on 2026-10-15;
the released package requires openapi-hs >=5.0 && <5.1.


## Plan of Work

### M1: Serve the package's real probes through production assembly

After the entire prerequisite `docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`
is Complete, add released servant-health 0.1.0.0 to Cabal and Nix with compatible bounds and
verified fetched hashes. Define `Kansoku.Health` in `kansoku-core/src/Kansoku/Health.hs` for
the operational route record, proxy, checks and probe-path inventory. Serve
`"health" :> NamedRoutes HealthApi` as a typed operational application. Introduce a production
application builder that accepts live and ready ProbeChecks independently and dispatches health
traffic to that typed application; production and test kit must call this same builder.

Add `kansoku-probe-test` in `kansoku-core/kansoku-core.cabal`, with its entry point in
`kansoku-core/probe-test/Main.hs`, importing `common` and `-threaded`, depending on Tasty and
servant-health:testkit only for tests. Drive `probeContractTests` against the real middleware
assembly with inert analytics dependencies that are never touched by probes. Verify both healthy,
each failing alone and both failing. Avoid a fake assembly that could pass despite swapped
production checks. Inspect Tasty's source via Mori before invoking any unfamiliar test API.

### M2: Bound and preserve service-owned checks

First prove the native resource boundary before mounting real database checks. This child owns
`kansoku-core/src/Kansoku/ClickHouse.hs`, including query connection creation, checkout, failure
disposal and shutdown. Preserve the separate writer connection. Inspect the pinned
`mori://KovalevDima/ClickHaskell` source: its exception cleanup attempts reconnection, whose
connect timeout alone is 3 seconds and whose handshake can block. Wrapping that path in
`withProbeTimeout` does not by itself prove a 750-millisecond operation deadline.

Use a bounded prototype in `kansoku-core/test/Kansoku/QueryPoolSpec.hs`, wired into Cabal and
`kansoku-core/test/Spec.hs`, with a private native endpoint or controllable TCP fault proxy.
Exercise failed connect, a stalled handshake, a stalled query, failed reconnect, and cancellation
with a pool size of one. The deadline covers acquisition, operation and cleanup. On an operation
exception, let the pool observe the failure so it discards the resource; catch and classify
errors only outside that resource boundary. Disposal must close native resources, not merely
forget a handle, and asynchronous cancellation must propagate after bounded cleanup.

The chosen behavior is to invalidate and dispose an interrupted connection, with fresh connection
creation on the next checkout; never reconnect synchronously while unwinding cancellation. If
the pinned driver cannot supply that behavior and a close operation through a supported API,
this child owns a minimal driver compatibility repair and its matching Cabal/Nix pin, verified
against current registry releases and upstream tags. Record its canonical source reference and
exact revision in this plan. Do not claim M2 accepted until the repaired real path passes; do not
substitute a timeout around a fake IO action, detach leaking workers, or relax the deadlines.
The prototype is promoted into regression coverage once it proves recovery and bounded resource
use; an unsuccessful approach is discarded before expanding probe wiring.

Allocate independent failure trackers once at startup, not per request. Liveness checks an
in-process heartbeat/state read; wrap it with `safeCheck` inside a 2-second timeout. Readiness
runs named checks in order: writer_alive, pgmq_reachable, clickhouse_query_reachable,
queue_depth, writer_flush_stale. Bound readiness as a whole to 2 seconds and each external
check to 750 milliseconds, using safe exception conversion and preserving asynchronous
cancellation. Use cheap database checks through the real pools; inspect driver APIs through
`mori://KovalevDima/ClickHaskell` and pool sources before choosing a query/ping operation.
Do not scan analytics tables or queue contents for probes. Continue using the poller's cached
samples for backlog thresholds. Keep synchronous errors generic on the wire.

Canonical readiness reports the first failing check through the package's fixed fields
`status`, `check`, `failingSince`. Keep the legacy `/ready` diagnostic check array, adding the
query dependency explicitly and documenting the new order. Share the underlying check functions
and threshold evaluator between both surfaces; the compatibility diagnostic renderer is
service-owned, but the canonical 200/503 mapping is library-owned. Preserve legacy `/health`
behavior. Add deterministic tests for timeouts, synchronous exceptions, cancellation, repeated
failure onset, recovery reset, idle empty queues and stale samples. Pool failures must not poison
later probes; prove a recovered pool can answer again.

M2's handoff to `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` is the
accepted `withQueryConnection` contract: exceptions escape only after disposal/release, failed
handles are never reused, and later native operations succeed after dependency recovery.
Retain the general query callback interface where possible; document any necessary signature
change here and in the consuming plan in the same change. Expose probe deadlines explicitly
without introducing a new analytics query-duration policy.

### M3: Document and verify the operational surface

Update `docs/guides/operations.md`, `docs/guides/configuration.md`, `docs/guides/getting-started.md`
and the root README to recommend canonical probes and identify compatibility routes. Public
OpenAPI remains the analytics contract; operational endpoints have a separately tested route
inventory. Exempt canonical and legacy probes by exact path from problem-document conformance.
Publish path constants/one inventory for the observability child to exclude from access logs.
Update ADR-2 and its bundle log/index through the established profiled workflow.


The accepted M2 regression command starts a temporary ClickHouse instance on private
ports, creates an empty isolated events table, requires all native cases, imposes a
120-second process watchdog, and removes the instance on exit:

```bash
nix develop -c python3 scripts/native-query-pool.py
```

It covers refused connect, four stalled handshakes, four stalled queries, failure
without reconnect, six cancellations, pool exhaustion, and recovery through both
ping and native analytics SELECT on the same size-one pool. External deadlines are
750 ms with an asserted elapsed limit below 1 second (250 ms scheduling tolerance).
Cancellation cleanup is below 250 ms; proxy connection counts drain to zero before
recovery. The fixture is in `Kansoku.QueryPoolSpec`; EP-26 and EP-28 reuse it.

## Concrete Steps

From the repository root, use `nix develop`, then discover and verify:

```bash
mori registry show shinzui/servant-health --full
mori registry docs shinzui/servant-health
curl -fsSL https://hackage.haskell.org/package/servant-health/preferred.json
curl -fsSL https://hackage.haskell.org/package/servant-health-0.1.0.0/servant-health.cabal
```

After implementation:

```bash
cabal test kansoku-probe-test --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.QueryPool' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.Readiness' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.Api.OpenApi.kansokuOpenApi' --test-show-details=direct
nix build .#kansoku-server
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

With an isolated running server, `curl -i http://127.0.0.1:8080/health/live` and the matching
`/health/ready` request return application/json, HTTP 200 when healthy. The test kit must report
zero failures; an injected readiness failure gives 503 while liveness remains 200.


## Validation and Acceptance

Prove canonical status/body/media mapping, the cross-probe failure matrix, timeout behavior and
onset retention with injected checks and a controlled clock or sufficiently deterministic
synchronization. A real unavailable database must produce bounded 503, never an escaping 500 or
an indefinitely pending request. Query-pool recovery must restore readiness. Legacy diagnostic
fields and documented routes remain testable. Ensure probes are public without credentials and
outside ingestion CORS/body limits, and canonical paths never enter customer OpenAPI.

Measure external checks against their 750 ms budget and whole readiness against 2 seconds,
with an explicitly recorded scheduling tolerance of at most 250 ms in tests. Include pool wait
and cleanup time. Use an independent test-process watchdog so a broken timeout fails rather than
hangs the suite. Repeat stalled-operation/cancellation cases and show sockets/workers do not
accumulate; after recovery, the same size-one pool must answer both a probe and an analytics
query without restarting the service. Record nonzero native-case counts and isolated setup
commands for the later acceptance harness. These cases are required before M2 is accepted.


## Idempotence and Recovery

No database migration is needed. Repeated probes have no persistent side effects. Allocate
tracker state once and bound resource use under concurrent probes. Legacy aliases permit staged
operator migration; do not remove them during this initiative. Revert dependency and application
wiring together if rollback is needed, preserving the previous public analytics contract.


## Interfaces and Dependencies

Hard dependency: all of `docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`.
This child owns `Kansoku.Health`, the operational proxy, injectable check seam and exact probe
path inventory, plus the query-pool lifetime and driver repair described in M2. The bounded-query
child requires accepted M2 evidence and consumes this pool; it does not redefine disposal or
reconnection. Later tracing uses these artifacts rather than inventing path strings. Keep
test-kit dependencies out of production stanzas. Commit trailers use the parent, this plan and
intention from frontmatter.
