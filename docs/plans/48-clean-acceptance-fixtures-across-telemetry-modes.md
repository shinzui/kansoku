---
id: 48
slug: clean-acceptance-fixtures-across-telemetry-modes
title: "Clean acceptance fixtures across telemetry modes"
kind: exec-plan
created_at: 2026-10-16T17:20:48Z
intention: "intention_01m52vndmcenmvqq6w1yphfykk"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T17:20:48Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T17:46:01Z
      mode: "update"
      note: "Update EP-46 reference after first-release scope correction"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T17:55:20Z
      mode: "implement"
      note: "Repair required fixture isolation prerequisite for EP-46 packaged acceptance"
---

# Clean acceptance fixtures across telemetry modes

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into the relevant ADRs before completion.

## Purpose / Big Picture


Close F4 in [REV-2](../reviews/2026-10-16-initial-release-implementation-correctness.md#f4-shared-cohort-fixtures-break-packaged-acceptance). The packaged release suite currently fails in its second telemetry mode because a custom-metrics scenario leaves a static cohort behind. After this change, scenarios release the saved resources they own, repeated execution cannot pollute later pagination checks, and the complete gate reaches its reader and administrative families.

This plan has three milestones. [EP-46](46-reject-storage-incompatible-json-before-acceptance.md) and [EP-47](47-support-organization-trait-filters-in-saved-cohorts.md) use the repaired gate for their final acceptance. Preserve strict pagination coverage and failure reporting; a green result must still mean all required families executed.

## Progress


- [x] M1: (2026-10-16; both scenario ownership wrappers pass repeated success and injected membership-failure cleanup in the focused composition proof.) Custom-metric fixtures clean up every owned definition and static membership on success and failure, across both accounts.
- [x] M2: (2026-10-16; `just fixture-isolation-acceptance` passed twice per scenario, exact two-account baselines, native active-membership clearing, unrelated sentinel and continued cleanup after an injected cleanup failure; evidence `.dev/acceptance/cohort-ebdemk_y/`.) A shared-store regression proves repeated scenarios preserve resource baselines and cohort pagination remains exact.
- [ ] M3: Full packaged acceptance passes all three telemetry modes and the later reader/administration families, with private evidence retained.

## Surprises & Discoveries


2026-10-16: Complete ID baselines in both accounts reproduce the original leak without relaxing pagination. The registered-resource context manager releases the foreign metric as well as all local variants. Explicit static-member clearing is verified with native `argMax(present,version)` after injected failure. The standalone large-upload/erasure proof also passes (`just cohorts-acceptance`, evidence `.dev/acceptance/cohort-vizgc8qb/`).

## Decision Log


2026-10-16: Implement this acceptance-only prerequisite while completing [EP-46](46-reject-storage-incompatible-json-before-acceptance.md), which requires the combined packaged gate. Its Intention ID is the same.

2026-10-16: Use scenario-owned cleanup with resource IDs and originating credentials. Keep the existing shared-store mode loop so it continues to expose isolation problems; do not remove pagination assertions or filter unexpected leftovers out of their expected results.

2026-10-16: Clearing a static cohort writes an empty membership replacement before deleting its definition. This removes active membership through the public contract. Physical historical present/absent facts may remain under ADR-19; deleting those rows is not required fixture cleanup.

## Outcomes & Retrospective


(To be filled during implementation.)

## Context and Orientation


`scripts/acceptance.py` starts the packaged server in three OpenTelemetry HTTP semantic modes: legacy (`''`), stable (`http`) and duplicate (`http/dup`). It reuses an account and stores across those runs. `verify_cohorts` runs every mode, while `verify_custom_metrics` runs only in the first.

`scripts/custom_metrics_acceptance.py` creates five local metric definitions, a foreign-account metric definition and a static cohort. Its successful end deletes only the original local metric. The other resources survive. `scripts/cohorts_acceptance.py` then walks all cohort definitions forward and backward and correctly expects exactly its three fixture IDs. The leaked fourth cohort breaks that assertion. The review reproduced this independently and did not find a production pagination defect.

[ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires fresh owned processes, nonzero required checks, retained private evidence and sanitized shared logs. [ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md) permits historical static membership facts to outlive definition deletion; a full empty replacement removes active membership. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md) defines account-scoped saved metrics and OR predicates. Cleanup must respect ownership rather than deleting all account resources.

## Plan of Work


### M1 — Track and finalize scenario-owned resources


Add a small reusable helper in `scripts/acceptance_resources.py`, or an equivalently scoped helper shared by the existing scenario scripts, that records a successful resource creation immediately with its ID, resource kind and account credential. Use a context manager or `try/finally` around the scenario body. Capture IDs for every local and foreign metric definition, the rate variants, the trait metric and the static cohort. Do not infer ownership from a name prefix or a full account list when deleting.

Delete all dependent metric definitions before clearing and deleting the static cohort. Preserve explicit deletion behavior assertions inside the test; deregister a resource after that successful deletion or treat only its already-absent 404 as benign during cleanup. A failed cleanup must attempt the remaining owned resources and report a failure. When a scenario assertion has already failed, preserve that primary error and add cleanup failures as context rather than replacing it or making the process succeed. Bound network calls and keep tokens out of diagnostics. Avoid generic retries of mutations; the empty replacement is repeatable and DELETE's already-absent handling is explicit.

Apply the same ownership pattern to `scripts/cohorts_acceptance.py` so its definitions and optional large-upload cohort are released if an intermediate assertion fails. Preserve the existing erase-user and post-delete behavior checks. Coordinate with EP-47's added definitions. M1 acceptance is a public run that returns saved-resource lists to their original baseline in both accounts on normal completion and on an injected failure after static membership upload.

### M2 — Prove repeatability without weakening pagination


Add an owned composition verifier in `scripts/acceptance_fixture_isolation.py`, using the existing `scripts/cohorts_acceptance.py` owned-stack entry point. Expose a `fixture-isolation-acceptance` recipe in `justfile` with the existing build-with-tests prerequisite. On one fresh shared stack, capture complete definition/cohort ID baselines for both credentials, execute custom metrics then cohorts twice, and compare complete lists after each call. Pagination checks inside the scenarios remain strict and continue to verify canonical forward/backward order and no skips or duplicates.

Add a controlled failure injection at a resource-lifecycle seam, such as a test wrapper that raises immediately after a successful membership upload has registered its cleanup. Do not introduce a production server failure toggle. Verify cleanup restores baselines, membership is cleared before definition removal, and the original injected failure remains observable. Separately test the helper with a preexisting unrelated resource to prove it never deletes resources it did not create; do not mix that sentinel into scenarios whose strict list assertions intentionally require an otherwise empty account. These are behavioral fixture regressions, not unit tests mirroring each helper line.

Run the composition verifier in the owned packaged environment as a required scenario, or incorporate its repeatability/baseline assertions into the existing verifier sequence so the original failure cannot recur silently. Avoid duplicating entire expensive native suites just to exercise resource cleanup. M2 passes only when repeated execution and failure cleanup succeed while the production pagination assertions are unchanged in meaning.

### M3 — Complete the packaged gate


Run `just acceptance` after the cleanup changes. It must pass the cohort scenario in every semantic mode and reach all subsequent reader and packaged administrative families. If a later existing family fails, retain that evidence and diagnose it rather than suppressing or skipping the family; do not declare this release gate green from the repaired early section alone. If another implementation defect is outside fixture ownership, record it as a separate finding with its remaining acceptance obligation.

Update `docs/guides/development.md` with the focused fixture-isolation command and the ownership/cleanup convention. Update ADR-10 if a durable fixture convention needs to be recorded, with the bundle log and validation. Record the final source revision, command exit status, executed families and private evidence directory here. EP-46 and EP-47 should reuse the repaired gate on the combined final candidate.

## Concrete Steps


Run from the repository root after adding the new focused recipe. All database-owning commands use fresh private directories and must not connect to ambient services.

```bash
nix develop -c just custom-metrics-acceptance
nix develop -c just cohorts-acceptance
nix develop -c just fixture-isolation-acceptance
nix develop -c just acceptance
```

For the documentation and final integration boundary:

```bash
nix develop -c just check
nix develop -c just guides-check
nix develop -c just adr-check
nix develop -c just reviews-check
git diff --check
```

Expected results are exit zero, exact baseline equality after each scenario in the isolated composition proof, and a complete full-gate result with no pending required tests. The reviewed failing command was `nix develop -c just acceptance`; preserving that entry point is part of the repair.

## Validation and Acceptance


Immediately after `verify_custom_metrics`, no owned cohort or metric definition remains under either credential. Static membership was explicitly replaced with an empty list before cohort deletion, and the original resource baseline is preserved. A second invocation against the same stores passes. Running the cohort verifier next still proves the exact three-ID bidirectional walk. The full packaged suite passes legacy, stable and duplicate HTTP modes and executes its later reader and administration scenarios.

The injected scenario failure must still be a failure, cleanup must attempt all remaining resources, and an unrelated resource must remain unchanged. Cleanup must not use a global TRUNCATE, silently ignore 500s or authentication errors, remove a pagination assertion, convert a required scenario to optional, or log credentials. Physical static-history rows are acceptable in disposable stores when the public active membership and definitions are cleaned according to ADR-19.

## Idempotence and Recovery


Resources are registered only after successful creation and finalized by their recorded IDs. Already-deleted owned definitions are safe to revisit; all other cleanup errors remain visible. Failure to clean up terminates the owning run, whose private stores can be inspected and whose next run starts fresh. Do not reset or mutate external databases. The existing owned-process shutdown must still execute on scenario and cleanup exceptions.

## Interfaces and Dependencies


Only the Python acceptance harness, its `justfile` entry points and documentation change. Public server APIs and production pagination behavior remain unchanged. The helper uses the existing HTTP operations and Python standard library; no dependency upgrade is planned. This plan can be implemented first and independently. EP-46 and EP-47 depend on its passing full gate for their final acceptance, not for their focused implementation work.
