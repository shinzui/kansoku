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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T18:42:36Z
      mode: "implement"
      note: "Begin conservative session-aware identity resolution, bounded candidate source and native ten-million-event evidence."
---

# Time-aware identity bindings and bounded resolution cost


## Purpose / Big Picture


Resolve anonymous activity without assigning a shared device's entire history to an arbitrary
user, and measure the cost of doing so. Publish what the evidence can prove; no timestamp rule
can infer an unrecorded logout or identify who held a shared device.

## Progress


- [x] M1: Identity semantics pass shared-device, late-arrival and namespace-collision fixtures.
- [x] M2: A bounded raw-event resolution source passes a ten-million-row benchmark.
- [x] M3: Keyed email identifiers and SDK validation/catalog changes agree.

## Surprises & Discoveries


Native acceptance passes 20 explicit subject expectations before merges, after merges and
after rebuilding migration 0018. Both independent direct SQL and the actual application
snapshot setup return identical results without fanout; the public projection remains seven
columns. Native pool tests cover new evidence, mutations, empty-table swaps, missing indexes,
account/window changes, fingerprint expiry without storage changes and physical isolation.

Early ten-million-event implementations missed the target by 5.9–29.9x. Per-event signal
expansion and repeated non-deterministic scalar lookups were costly. The current HTTP path
resolves distinct account/date-scoped contexts into exact connection-owned Join snapshots,
then materializes one lookup per candidate row. Each use checks all three index UUIDs/parts;
account/window changes or the next fingerprint expiry rebuild the snapshot. An engine-clock
guard rejects expiry crossing between preparation and SELECT. No timed refresh lag is added.
Cold preparation and steady queries are measured separately, including native preflight work.
The required-size benchmark now passes all twelve cases (1.17–1.58x). Persisting a lossless,
length-prefixed context key avoids five-key lookup overhead; the single-pass conditional
conversion aggregate preserves its two distinct-user sets while sharing the resolved scan.

The initial benchmark gave each session only one event. The corrected fixture puts up to
20 events in a session with independent event names, stable session-day placement and global
shared-cookie conflicts across sessions. Anonymous events remain exactly 70% and 40% of cookies
have explicit evidence. Earlier reports are diagnostic only; acceptance uses the corrected
fixture and five measured native runs for every case at three and ten million retained events.

The released ClickHaskell 1.1.0 wire enum labels initial requests as secondary queries, and its
command/insert loops reject legitimate progress/profile packets. The vendored driver repairs
both protocol defects; query-log instrumentation requires initial classification. The upstream
release/tag check still identifies 1.1.0 as current. The native command lifetime test proves
CREATE-AS-SELECT, INSERT-AS-SELECT and subsequent pings consume complete protocol streams.

`0012_identity_signals.sql` sets `observed_at = received_at`, not event time, and omits
session_id. The proposed nearest-future binding cannot know which user owns an event between
two logins. Restricting evidence to the query window also loses valid later identify events.
The public seven-column view lacks fields needed by filters and session analytics.

## Decision Log


On 2026-10-15 prefer unambiguous evidence to guessing. Explicit user IDs win; a uniquely
identified session can resolve its own anonymous events, otherwise only an unambiguous
signal binding can stitch. Conflicts stay anonymous and visible. Defer refresh-lag semantics:
the exact HTTP path uses revision-checked, expiry-bounded snapshots owned by each physical
query connection, with a separate direct public SQL resolver.

## Outcomes & Retrospective


Complete on 2026-10-15. Conservative subjects, namespaced sketches, rich bounded candidates,
expiry-aware exact snapshots and catalog v3/keyed-email validation are accepted. The twenty-
subject native proof passes before/after merges and repeated rebuilds; pool tests cover
mutation/replacement/missing-index recovery, account/window invalidation, physical isolation
and both clock refresh and the SELECT expiry guard. The native command lifetime and regrouped
replay metric tests also pass.

`just check` passes 179 deterministic core examples, 16 client examples, four probes, generated
contracts, strict ADR validation and all three HTTP telemetry modes. Packaged `just acceptance`
passes 211 core examples, 17 client examples, four probes, 45 normal Hurl requests plus the
metrics-disabled request, independent recovery/limits/replay/identity checks and three packaged
telemetry modes, with no required pending cases. Sanitized evidence is under
`.dev/acceptance/run-b71njtml/sanitized`.

The actual browser SDK at `mori://shinzui/kansoku-ts/packages/kansoku-js`, revision
`8bc1bc0`, pins server `9e81117eb194210aeef614ca5a940461aa4ce417`. Its identifier vocabulary and
public union are generated from catalog v3, HMAC values and unknown-kind rejection are tested,
and the wire alias consumes generated ProblemDetails. Type checks, lint/format, SSR,
package/size checks, generated-contract checks and strict ADR validation pass. Tests pass
59 DOM/unit cases and two native SSR cases; the seven unconfigured SDK live cases remain the
explicit EP-38 joint release gate, not acceptance evidence for this child.

All twelve required-size warm benchmark cases pass at 1.17–1.58x. Cold preparation grows with
retained evidence and may recur after writes/merges; the tables below qualify that cost rather
than claiming generic production latency. EP-31 owns work budgets across preparation and the
final SELECT. EP-37 owns fenced lifecycle of every derived index and the raw identity key.

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

### Accepted performance evidence (2026-10-15)

Owned report `.dev/acceptance/identity-bench-w0cmluzm/report.json`: Apple M1 Max, 64 GiB,
macOS 26.7, ClickHouse 26.8.2.7, four threads. Three million recent facts are measured, then
seven million older facts are appended. Exact fractions are 70% anonymous and 40% identified
cookies, with two accounts and shared-cookie conflicts. Each cell is a five-run native median;
resolved measurements include the index-revision preflight. Query-log rows/bytes and maximum
SELECT memory are included below. Baselines use the same compiler and settings, replacing
only identity resolution with raw namespaced identity. These are fixture measurements.

| History | Window | Metric | Raw / resolved ms | Ratio | Resolved rows / bytes | Peak bytes |
|---|---|---|---:|---:|---:|---:|
| recent-only | day | funnel | 14 / 19 | 1.36 | 49166 / 3738305 | 2662224 |
| recent-only | day | retention | 28 / 35 | 1.25 | 163854 / 12324519 | 10916391 |
| recent-only | day | conversion | 12 / 19 | 1.58 | 49166 / 3738305 | 1964951 |
| recent-only | month | funnel | 51 / 71 | 1.39 | 925710 / 69611224 | 55433661 |
| recent-only | month | retention | 133 / 185 | 1.39 | 3014670 / 225066189 | 146101505 |
| recent-only | month | conversion | 41 / 59 | 1.44 | 925710 / 69611224 | 50137212 |
| grown-history | day | funnel | 14 / 19 | 1.36 | 49175 / 3738898 | 2661712 |
| grown-history | day | retention | 29 / 34 | 1.17 | 163863 / 12325112 | 10917087 |
| grown-history | day | conversion | 13 / 19 | 1.46 | 49175 / 3738898 | 1965647 |
| grown-history | month | funnel | 48 / 67 | 1.40 | 925719 / 69611817 | 59682574 |
| grown-history | month | retention | 131 / 182 | 1.39 | 3014679 / 225066782 | 144552843 |
| grown-history | month | conversion | 41 / 58 | 1.41 | 925719 / 69611817 | 50143676 |

Cold preparation is measured on five fresh physical sessions per window. It includes
revision lookup, all temporary-table construction and a trivial SELECT, separately from warm
metric latency. Index bytes are physical on-disk bytes across both fixture accounts.

| History | Window | Median ms | Rows / bytes | Peak bytes | Index bytes |
|---|---|---:|---:|---:|---:|
| recent-only | day | 70 | 114700 / 6048217 | 37468990 | 5578341 |
| recent-only | month | 182 | 221196 / 15171251 | 52905219 | 5578341 |
| grown-history | day | 144 | 229397 / 11674987 | 103710747 | 18040606 |
| grown-history | month | 259 | 352277 / 22186870 | 85625552 | 18040606 |

Candidate rows for the same recent window remain stable as older history grows. Cold
evidence preparation grows with retained account history and is bounded by explicit memory
caps; this design does not claim history-independent total work or warm-cache latency on every
request. Active writes/merges can invalidate a snapshot and require cold preparation.


## Idempotence and Recovery


Use forward migrations and isolated fixtures. Preserve evidence while replacing views. This is a deliberate pre-release semantic correction; update ADR-5 on implementation rather than preserving latest-wins compatibility.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`.

Hard dependencies: EP-29 and EP-30 Complete (`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`). Owns rich resolvedSource and canonical subject semantics, consumed by EP-31, EP-35, EP-36 and EP-40.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
