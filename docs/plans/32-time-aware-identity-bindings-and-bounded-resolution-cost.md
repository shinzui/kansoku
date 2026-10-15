---
id: 32
slug: time-aware-identity-bindings-and-bounded-resolution-cost
title: "Time-aware identity bindings and bounded resolution cost"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
---

# Time-aware identity bindings and bounded resolution cost


## Purpose / Big Picture


Resolve anonymous activity without assigning a shared device's entire history to an arbitrary
user, and measure the cost of doing so. Publish what the evidence can prove; no timestamp rule
can infer an unrecorded logout or identify who held a shared device.

## Progress


- [ ] M1: Identity semantics pass shared-device, late-arrival and namespace-collision fixtures.
- [ ] M2: A bounded raw-event resolution source passes a ten-million-row benchmark.
- [ ] M3: Keyed email identifiers and SDK validation/catalog changes agree.

## Surprises & Discoveries


`0012_identity_signals.sql` sets `observed_at = received_at`, not event time, and omits
session_id. The proposed nearest-future binding cannot know which user owns an event between
two logins. Restricting evidence to the query window also loses valid later identify events.
The public seven-column view lacks fields needed by filters and session analytics.

## Decision Log


On 2026-10-15 prefer unambiguous evidence to guessing. Explicit user IDs win; a uniquely
identified session can resolve its own anonymous events, otherwise only an unambiguous
signal binding can stitch. Conflicts stay anonymous and visible. Defer refresh-lag semantics:
the initial exact HTTP path resolves at query time.

## Outcomes & Retrospective


Planning reviewed; benchmark and runtime evidence remain outstanding.

## Context and Orientation


`db/clickhouse/migrations/0012_identity_signals.sql` creates identity evidence, bindings,
conflicts and the resolved view. `Kansoku.Event.Types` owns identifier kinds, `Validation.hs`
their values, and `Kansoku.Metrics.Query` consumes canonical_user.
Read [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md). SDK reset currently
rotates both anonymous and session IDs at `mori://shinzui/kansoku-ts/packages/kansoku-js`.

## Plan of Work


### M1: Define evidence and subject identity


Extend evidence with corrected event time, receive time, event ID and session ID. Session
keys are `(account_id,source_service,session_id)` and only nonempty session IDs qualify.
Implicit cookie evidence comes from identify, identify_once and alias carrying explicit userId;
explicit mapped identifiers keep their documented evidence rule. Use EP-30 canonical events.
For anonymous events first consider same-cookie, same-session evidence: if exactly one user
is observed in that session, resolve to that user, including pre-login events. If the session
has conflicting users, do not resolve from that cookie. Without session evidence, a cookie
with exactly one observed user across retained history may resolve; a conflicted cookie may not.
Apply uniqueness before confidence ranking to other signal kinds, and reject ties with different
users at equal winning confidence. Enforce fingerprint expiry in evidence predicates as well as eventual physical TTL cleanup.
Keep confidence and fingerprint TTL visible as policy, not a
claim that probabilistic signals identify a person with certainty. Explicit user always wins.

Internally represent subject kind and ID separately, or encode canonical_user unambiguously as
`user:<id>` versus `anonymous:<id>` (one fixed prefix plus original ID). Unidentified events
with neither identity remain empty and are excluded from user counts. Traits join only resolved
user subjects, never a coincidentally equal anonymous ID. Update all exact builders and raw-identity sketches (including experiment exposures) to avoid
user/anonymous namespace collisions, while preserving their explicitly approximate policy. Update fixtures,
experiment SQL and direct-consumption documentation for this initial-release contract.

### M2: Bound candidate events, measure evidence lookup


Build a rich internal `resolvedSource` helper from EP-30's canonical raw relation with account
and requested event-time range applied before signal expansion. Preserve raw source, session,
URL and later enrichment columns internally; expose the historical seven columns through the
public `events_resolved` projection. Evidence lookup must retain relevant bindings outside the
request window, including future identify records; only the candidate event scan is window-bound.
Index/order evidence for `(account,kind,value)` lookup and benchmark the evidence side separately.
Do not promise total work independent of history or substitute a five-minute stale refresh into
an exact route without a new decision.

Add `scripts/identity-bench.py` using only an owned scratch database, with ten million events,
70 percent anonymous, 40 percent identified cookies, two accounts and shared-device conflicts.
Record five-run medians, read rows/bytes and peak memory for funnel, retention and conversion
for one-day and one-month windows as account history grows. Target less than twice the matching
unresolved query latency at the stated fixture; if missed, record the blocker and optimize the
same semantics before marking M2 complete. Existing tests asserting latest-wins behavior must
be intentionally replaced; unaffected exactness/account tests stay green.

### M3: Keyed email


Add email_hmac to the wire enum and generated clients, confidence 0.95 and the same bounded
ASCII value rule. Document HMAC-SHA-256, an explicit UTF-8 trim/lowercase normalization convention,
server-side pepper storage and a version prefix for rotation; a browser must never receive the
pepper. Keep email_sha256 supported but discouraged. Extend erasure to every evidence kind.
Coordinate SDK validator/type changes with
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`.

## Validation and Acceptance


Two sessions sharing cookie C, uniquely identifying A and B, resolve their own pre-login events
correctly even if delivery order reverses. An anonymous event between sessions with conflicted
C stays anonymous; a session containing both A and B stays ambiguous. A binding outside the
query window still resolves an unambiguous subject. Explicit IDs, confidence ties, fingerprint
expiry, duplicate evidence and same-text anonymous/user IDs have deterministic tests.
Benchmark evidence covers growing account history and confirms candidate-event pruning.
Public view column order stays seven; the internal relation exposes needed fields without
multiplying rows. Both SDKs accept email_hmac and reject unknown kinds.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Use forward migrations and isolated fixtures. Preserve evidence while replacing views. This is a deliberate pre-release semantic correction; update ADR-5 on implementation rather than preserving latest-wins compatibility.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`.

Hard dependencies: EP-29 and EP-30 Complete (`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`). Owns rich resolvedSource and canonical subject semantics, consumed by EP-31, EP-35, EP-36 and EP-40.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
