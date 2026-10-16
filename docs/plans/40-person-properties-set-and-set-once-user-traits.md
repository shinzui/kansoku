---
id: 40
slug: person-properties-set-and-set-once-user-traits
title: "Person properties: set and set-once user traits"
kind: exec-plan
created_at: 2026-10-15T14:22:40Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T14:22:40Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T00:35:24Z
      mode: "implement"
      note: "Begin governed set/set-once traits, current-user segmentation across implemented metrics and replay-safe erasure primitives after EP-36 acceptance."
---

# Person properties: set and set-once user traits


## Purpose / Big Picture


Provide current user traits with consistent set/set-once semantics and typed user: filters.
Traits can segment browser activity after identity resolution; they are analytics observations,
not trusted authorization facts, since public write-key clients may report them.

## Progress


- [x] M1: Declared typed traits have deterministic set/set-once state under replay and late delivery.
- [x] M2: Supported routes apply user dimensions with correct identity and population semantics.
- [ ] M3: Haskell helper, SDK contract, catalog and trait deletion/rebuild fixtures agree.

## Surprises & Discoveries


Omitting schemaVersion selects v1, not latest. Declaring identify v2 alone would not validate
SDK traits. The old table type omitted its promised receivedAt tie-break, and JSON string
values would compare as quoted text against plain filter values. Anonymous and user IDs need
separate namespaces to prevent accidental trait joins.

Native Float64/JSON extraction rounded a tiny fractional company_size to an integer (and
underflowed another invalid value to zero), so native integral checks alone cannot establish
ingest validation. Preserve server validation eligibility from the first accepted envelope:
new private queue v2 stores traitsEligible, v0/v1 decode as false, raw rows store
server-only governed_traits_valid with old rows default false. The writer revalidates flagged
operations against the immutable declared schema before setting the raw marker. Public JSON
cannot choose it. The actual stored schema_version remains part of native eligibility.

## Decision Log


On 2026-10-15 use current-value traits ordered by `(occurredAt,receivedAt,eventId)` from the
first durably accepted event. Set replaces; set-once initializes an otherwise unset property,
not a permanently immutable field. If any set exists, its latest value wins; otherwise earliest
set-once wins. Omitted keys leave values untouched. Null/deletion operations are not part of
this initial trait API and must be rejected for declared scalar traits.

On 2026-10-16 store a decoded String/numeric Float64/type tuple in argMax/argMin states, not
quoted JSON strings. One shared catalog owns identify v2/identify_once v1 and user: resolution.
Scientific 0.3.9.0 is already the resolved dependency; Mori has no corpus entry, so its current
Hackage release and upstream v0.3.9.0 tag (commit 17870f8706ac8b99d3973bea56fcee1290d821ec)
were verified, and source for isInteger/toRealFloat was read before use. The API now declares
the direct >=0.3.9,<0.4 dependency for exact, finite, nonnegative integer validation.

Trait erasure owns permanent account/event-ID tombstones before clearing both state tables
and scrubbing/deleting governed source events. Rebuilds and old raw replays exclude those IDs;
new event IDs may initialize traits afterward. EP-37 must fence ingest/writer/readers and also
clean queue/archive/acceptance inputs before releasing its fence. The primitives are not an
atomic public maintenance API by themselves.

Current-trait joins pivot only referenced catalog names once per source and join only the
resolved user namespace. Session/acquisition trait selection occurs after full retained
assembly using the first resolved user. Strict funnels accept current-user filters while
keeping all events for each selected subject; event filters remain errors. Exposure selection
with user dimensions uses exact resolved counts instead of the raw-identity sketch; the
unsegmented default stays approximate. Experiments accept only user: selection dimensions.

## Outcomes & Retrospective


M1/M2 native acceptance passes eleven focused examples with no failures or pending cases:
exact declared validation and private queue compatibility, total-order set/set-once replay,
quoted/numeric/null/type cases, legacy exclusion, Unicode/account-isolated scrub/delete and
rebuild/replay tombstones, every implemented metric population, first-user whole-session
ownership across user changes, and numeric 10000/10001 point boundaries plus resource limits.
The first-read canonical view must be refreshed after adding governed_traits_valid; its stored
header does not follow ALTER TABLE automatically. The public seven-column resolved shape is
preserved. Logs: `.dev/acceptance/identity-validation/ep40-native.log`.

Haskell helper/default/version-override coverage and generated catalog v4 are implemented.
The full source gate passes 361 core examples, 18 client examples, four probes, generated
contracts, strict 16-ADR validation, three telemetry modes and four lifecycle cases. Packaged
ordinary public workflow, pinned browser/helper consumer and expanded performance acceptance
remain pending; M3 and whole-child completion stay open.

## Context and Orientation


`Event/Registry.hs` has identify v1 with no declared properties; validation defaults to v1.
The current Haskell helper is `kansoku-client/src/Kansoku/Client.hs`. EP-31 owns typed filters
and nullable namespaced group values; EP-32 exposes resolved subject kind/ID. Read
[ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md),
[ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md) and
[ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md).

## Plan of Work


### M1: Schema and state


Declare identify v2 and identify_once v1 with optional string traits plan, signup_source,
initial_plan, country, role and optional numeric company_size (finite, nonnegative integer).
Require nonempty top-level userId for either trait operation; identify v1 remains valid as an
identity event, but does not mutate governed traits. Current helper defaults explicitly emit
v2 for identify and v1 for identify_once; preserve explicit caller overrides and describe v1's
identity-only behavior. Only schema-declared, validated scalar keys feed storage; extra keys
on an event are not silently promoted to traits. Registry changes cannot change a trait's type
between identify/identify_once or versions without an explicit migration decision.

Create user_properties and user_properties_once aggregate tables keyed by account/user/name.
Store typed scalar values or canonical scalar JSON plus type, and order argMax/argMin state
by a Tuple(DateTime64,DateTime64,String), not just timestamp. Use declared-schema eligibility
including actual stored schema_version. Merged user_traits returns exactly one row per key,
latest set when present else earliest set-once. JSON strings must decode to ordinary text for
comparison; numeric traits retain numeric comparison, not lexicographic ordering. Duplicate
accepted/replayed events must not change state. No initial backfill from ungoverned identify v1.

### M2: Metrics


Add user:<name> to EP-31's dimension registry, using the common trait catalog rather than
requiring every event to declare a person trait. Join by account and resolved user subject ID,
never anonymous fallback text, and deduplicate referenced traits so filters and grouping do
not multiply joins or events. Missing traits are null and use EP-31 set/unset semantics.
Force canonical resolved reads when necessary, including page-view rollup bypass. Support all
implemented metrics with explicit attribution: event/user metrics apply current traits to each
resolved subject; ratios apply the same trait population to numerator and denominator; funnels
use participant traits; cohorts/lifecycle use the same trait population across lookback; sessions
and acquisition use their first resolved user per session, as EP-34 defines. Do not expose
user dimensions on unimplemented organizations/custom stubs as if functional. Publish the matrix.

### M3: Helpers and lifecycle


Add identifyOnce to Haskell and specify browser behavior at
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`.
Browser identifyOnce sets the active user just like identify and sends an explicit schemaVersion;
identify_once also creates implicit-cookie evidence under EP-32. Examples must not skip version
selection. Document that late events can revise trait order and current traits intentionally
reclassify historical queries. Trusted business traits require service-owned producers and
must never be used for access control based on this public ingest contract.

Own a trait deletion/rebuild function and fixtures that EP-37's future admin command consumes;
do not depend on that command before it exists. Delete both aggregate states and scrub/delete
source trait events according to the erasure mode so replay/backfill cannot resurrect them.
Regenerate catalog/OpenAPI and update the guide/runbook.

## Validation and Acceptance


Test reverse arrival, identical timestamps with event-ID ties, repeated insert, multiple keys,
missing/null/type mismatches, quoted strings and numeric comparisons. Set-once before set is
overridden by set; set-once after a set is ignored; first set-once wins if no set exists.
V1 identify creates identity evidence but not governed traits; both SDK helpers emit correct
versions and unknown versions reject. Anonymous pre-login traffic stitched to a user gains
traits, while an anonymous ID equal to another user's ID does not. Exercise every supported
route population, account isolation, repeated trait references and null groups. Delete/rebuild
fixtures leave no restored trait state; EP-37 later proves the CLI path.

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


Only idempotent argMin/argMax states with total ordering may be replayed into existing trait targets. Governed storage excludes unvalidated legacy values. Do not introduce a trait-unset mutation implicitly through null; add a future versioned operation if required.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`, `docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md`.

Hard dependencies: EP-29, EP-31 and EP-32 Complete. EP-34 is a hard prerequisite for session/acquisition trait acceptance, so whole-child completion also waits for EP-34. EP-37 depends on this plan, not vice versa. Owns user: dimensions, trait schemas/storage and erasure primitives.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
