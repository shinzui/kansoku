---
id: 18
slug: multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching
title: "Multi-signal identity: identifier kinds, fingerprints, and confidence-aware stitching"
kind: exec-plan
created_at: 2026-07-15T21:43:59Z
intention: intention_01kxxscv06exbvqdtefzqnf9h5
master_plan: "docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md"
---

# Multi-signal identity: identifier kinds, fingerprints, and confidence-aware stitching

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku today can describe a visitor with exactly two identifiers: an `anonymousId` (one
opaque, cookie-scoped id chosen by the client) and a `userId` (the product's account id,
present once the person logs in or is identified). Those two are stitched together by a
single latest-wins lookup table: `analytics.identity_map` holds at most one `user_id` per
`anonymous_id`, and the newest write silently overwrites whatever was there before.

That model has no room for evidence that is not a cookie. A browser fingerprint (a hash
computed from browser characteristics — probabilistic, survives cookie clearing, shared by
everyone using the same browser profile), a device id (stable per app install), or a hashed
email (deterministic but arriving from a different system) cannot be represented as what
they are. Overloading `anonymousId` with a fingerprint would conflate a stable cookie with
a probabilistic signal, and the latest-wins map silently mis-resolves the moment one
identifier is legitimately seen with two different users — a shared family iPad is enough,
and fingerprints make that failure mode common rather than rare. The 2026-07-15 data-model
assessment named this the model's second flat spot (the first, opaque JSON properties, is
EP-17's).

After this plan, identity is evidence-based. Events may carry an optional `identifiers`
map from a closed set of identifier *kinds* (`cookie`, `device`, `fingerprint`,
`email_sha256`) to values. Every observation of "signal X was seen bound to user U" is
recorded as an immutable evidence row in a new ClickHouse table
`analytics.identity_signals`, scoped to the owning account. Resolution becomes
confidence-aware: an event's canonical user is its explicit `user_id` if present,
otherwise the user reachable from the event's signals ranked by (per-kind confidence,
recency) above a threshold, otherwise its cookie id. When one signal has been seen with two
users, both bindings remain queryable through a new `analytics.identity_conflicts` view
instead of being silently overwritten, and resolution picks a winner by a documented
ranking. Fingerprints get an explicit privacy posture: a 180-day ClickHouse TTL on
fingerprint evidence rows and a per-user deletion runbook.

You can see it working end to end: ingest a fixture story in which two different browser
sessions (two cookies) share one fingerprint and only one session ever identifies as user
`user-U`; a unique-users query then counts **1** user where the cookie-only model counts
**2**. The transcript for that demonstration is in Validation and Acceptance.

Every consumer that reads `canonical_user` from `analytics.events_resolved` — the metric
SQL in `kansoku-core/src/Kansoku/Query.hs` and EP-19's experiment rollups — keeps working
unchanged, because this plan freezes the view's name and output columns and proves
output-shape stability by re-running the MasterPlan-2-era query battery.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-19 13:14 PDT) M1: `identifiers :: Maybe (Map Text Text)` field on `AnalyticsEvent` with JSON
      roundtrip (omitted field still parses; existing payloads unaffected)
- [x] (2026-07-19 13:14 PDT) M1: `IdentifierKind` closed set and validation errors (unknown kind rejected with the
      allowed list; empty/oversized/bad-charset values rejected)
- [x] (2026-07-19 13:14 PDT) M1: `events_raw` gains an `identifiers` column (migration) and
      `Kansoku.ClickHouse.EventRow` persists it
- [x] (2026-07-19 13:14 PDT) M1: `kansoku-client` (`EventIds`, `buildEvent`) and the OpenAPI document updated in
      the same commit as the wire type
- [x] (2026-07-19 13:14 PDT) M1: `just build` and `just test` green; authenticated curl ingest transcript captured
- [x] (2026-07-19 13:20 PDT) M2: `analytics.identity_signals` table + `mv_identity_signals` + backfill migration
      applied
- [x] (2026-07-19 13:20 PDT) M2: `analytics.identity_bindings` (confidence policy) and confidence-aware
      `analytics.events_resolved` replacement live; output columns verified identical
- [x] (2026-07-19 13:20 PDT) M2: `analytics.identity_conflicts` view live; conflict fixture appears in it and
      resolves by the documented ranking
- [x] (2026-07-19 13:20 PDT) M2: fixture story transcripts captured (with-fingerprints counts 1, without counts 2)
- [ ] M3: fingerprint TTL on `identity_signals` verified (aged fingerprint row deleted by
      TTL, aged cookie row survives)
- [ ] M3: deletion runbook written at `docs/runbooks/identity-data-deletion.md` and
      exercised once against fixture data
- [ ] M3: `identity_map`/`mv_identity_map` retired in a follow-up migration after the
      stability battery passes
- [ ] M3: MP-2-era resolution query battery re-run; `canonical_user` output-shape
      stability recorded (the EP-19 invariant)
- [ ] MasterPlan 3 Progress and Integration Points updated (field-name claim recorded)
- [x] (2026-07-19 13:08 PDT) Reconciled the plan with EP-17's landed native-JSON
      projection, migration ledger through `0010`, and the live seven-column
      `analytics.events_resolved` contract; baseline `just build` and `just test` passed.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-19: EP-17 landed before implementation and extended
  `analytics.events_resolved` with a seventh `properties_json JSON` column. Live
  `DESCRIBE TABLE analytics.events_resolved` confirmed the ordered contract recorded in
  ADR 0004, so every M2/M3 shape-stability check in this plan now includes that column.
  The migration ledger is occupied through `0010`; EP-18 therefore claims `0011` through
  `0013`.

- 2026-07-19: The default local PostgreSQL database contained an untracked pre-existing
  PGMQ schema, so the strict migration runner refused to replay `message_record`. The M1
  HTTP proof used a fresh `kansoku_ep18` development database instead; all three
  application migrations applied there without weakening migration verification or
  altering the stale database.

- 2026-07-19: EP-18's authored fixture omitted the raw `properties` column. After EP-17,
  that omission supplies an empty string and the materialized `CAST(properties, 'JSON')`
  correctly fails with ClickHouse error 117. Both EP-18 fixtures now write explicit
  `'{}'` values for `properties` and `context`; the production Haskell writer already
  always emits valid objects.


## Decision Log

Record every decision made while working on the plan.

- Decision: The wire field is named `identifiers` (JSON key `identifiers`), typed
  `Maybe (Map Text Text)` from identifier kind to value.
  Rationale: Plural, self-describing, and visibly distinct from the existing singular
  `anonymousId`/`userId`. It cannot collide with EP-20's planned schema-version field
  (EP-20 will claim a name like `schemaVersion`); per MasterPlan 3's "AnalyticsEvent wire
  type" integration point, this claim must be recorded in the MasterPlan before merging so
  EP-20 picks a disjoint name. A map (not a list of objects) keeps the payload small, makes
  "one value per kind per event" structural, and serializes to a plain JSON object.
  Date: 2026-07-15

- Decision: The identifier-kind set is closed: `cookie`, `device`, `fingerprint`,
  `email_sha256`. Unknown kinds are a validation error listing the allowed kinds.
  Rationale: Confidence policy, TTL policy, and deletion policy are all *per kind*; an
  open set would mean signals with no defined confidence or retention silently
  accumulating. Extending the set is a deliberate act: add a constructor to
  `IdentifierKind`, a confidence entry to the `identity_bindings` view, and a retention
  decision — all named in this plan.
  Date: 2026-07-15

- Decision: Confidence is a static per-kind policy encoded once in resolution SQL (the
  `analytics.identity_bindings` view), not a float stored per evidence row. Values:
  explicit `user_id` on the event = 1.0 (implicit — it short-circuits resolution),
  `email_sha256` = 0.95, `cookie` = 0.90, `device` = 0.80, `fingerprint` = 0.50.
  Resolution threshold: confidence >= 0.50.
  Rationale: A stored float per row is write-time policy — revising it means rewriting
  history with mutations, and nobody can say afterwards which rows carry which policy
  version. A view-encoded policy is auditable (one `multiIf` to read), applies uniformly
  to all history, and is revisable by a single view-recreating migration. The alternative
  (stored per-row confidence) buys per-observation nuance — e.g. an SDK reporting its own
  fingerprint match quality — that no producer can supply today; if that arrives, add a
  `confidence_hint` column then, without undoing this design. The threshold equals the
  lowest kind's confidence today so every known kind participates; it exists so a future
  low-trust kind (e.g. `ip`) can be *recorded* as evidence yet excluded from resolution.
  Date: 2026-07-15

- Decision: `identity_signals` keeps ALL observations. Engine
  `ReplacingMergeTree` with `ORDER BY (account_id, signal_kind, signal_value, user_id,
  observed_at, event_id)` so only *exact* duplicates (queue replays of the same event)
  ever collapse; two observations binding the same signal to different users, or at
  different times, are distinct rows forever.
  Rationale: Conflicts must be representable — that is the point of the plan. A
  latest-wins engine keyed on the signal (like `identity_map`) is exactly the silent
  mis-resolution this plan removes. Keeping all rows also gives the conflicts view its
  data and makes the evidence log auditable. The dedup identity includes `event_id`, so
  dedup is precisely "the at-least-once queue delivered the same event twice", mirroring
  how `events_raw` already dedups.
  Date: 2026-07-15

- Decision: Bindings are event-local ("one hop"): a signal binds to a user only if some
  single event carried both that signal and a `user_id`. There is no transitive closure
  (no "F was seen with cookie A, A binds to U, therefore F binds to U" inference across
  events).
  Rationale: Transitive closure over probabilistic signals is an unbounded graph
  computation that ClickHouse views cannot express without recursion, and it silently
  amplifies weak links (two users sharing a device would merge everything either ever
  touched). One hop is honest and sufficient in practice because a well-behaved SDK sends
  its full current identifier set on `identify` — the identify event itself carries the
  fingerprint, creating the fingerprint→user binding directly. The fixture story encodes
  this assumption; it is a documented producer requirement, not an accident.
  Date: 2026-07-15

- Decision: Cookie (`anonymous_id`) bindings are created only from `identify`/`alias`
  events, preserving `mv_identity_map`'s existing semantics; identifier-map bindings
  (`identifiers` field) are created from ANY event that carries both `identifiers` and a
  `user_id`.
  Rationale: `anonymous_id` co-occurs with `user_id` on ordinary events routinely (see
  `db/clickhouse/fixtures/ep5_fixtures.sql` row `f3`) and today only `identify`/`alias`
  are treated as binding intent — changing that would change resolution for existing data
  and break the stability battery. The `identifiers` field is new, so "carrying it next to
  a user_id is binding evidence" can be defined from day one; requiring a dedicated
  identify for fingerprints would miss the common SDK pattern of attaching the fingerprint
  to every event.
  Date: 2026-07-15

- Decision: `identifiers` is persisted in `events_raw` as a JSON-object `String` column
  (`identifiers String DEFAULT '{}'`), matching the existing `properties`/`context`
  representation.
  Rationale: The batched writer inserts through clickhaskell's typed columns and
  `ChString` is its proven wire type here; `properties` and `context` already use exactly
  this shape. Coordination with EP-17 (runs in parallel; owns the properties storage
  representation): if EP-17 has already migrated `properties` to a ClickHouse-native JSON
  type and taught the writer that representation, `identifiers` should adopt the same one
  and this plan's `JSONExtractKeysAndValues(identifiers, 'String')` calls become native
  map access — check EP-17's Decision Log at implementation time and record the actual
  choice here.
  Date: 2026-07-15

- Decision: Fingerprint evidence default retention is 180 days, enforced by a row-level
  ClickHouse TTL (`TTL toDateTime(observed_at) + INTERVAL 180 DAY DELETE WHERE
  signal_kind = 'fingerprint'`) on `identity_signals`. Retention numbers are configurable
  policy: changing them is a one-statement `ALTER TABLE ... MODIFY TTL` migration, and the
  current default lives here in the Decision Log, in the migration comment, and in the
  runbook.
  Rationale: Fingerprints are personal data under GDPR even when first-party; unbounded
  retention of a probabilistic tracker is indefensible. 180 days covers two quarters of
  funnel/retention analysis. Cookie/device/email evidence follows the product's normal
  data lifecycle and is not TTL'd here.
  Date: 2026-07-15

- Decision: The `analytics.events_resolved` output contract is FROZEN: name
  `analytics.events_resolved`, columns exactly `event_id`, `event_name`, `occurred_at`,
  `url`, `account_id`, `canonical_user`, `properties_json`. This plan swaps the
  resolution *underneath* that contract and proves stability by re-running the
  MP-2-era query battery plus EP-17's property-query integration (Milestone 3).
  Rationale: MasterPlan 3's "Identity resolution" integration point: EP-19's rollups and
  every `Kansoku.Query` builder consume `canonical_user` opaquely; if EP-19 lands first,
  its rollups must remain correct when this plan swaps resolution. Resolution stays
  FINAL-free per MP-2 EP-12's discipline.
  Date: 2026-07-15

- Decision: Preserve EP-17's server-only `properties_json JSON` projection when replacing
  `analytics.events_resolved`, and use migrations `0011`, `0012`, and `0013` for EP-18.
  Rationale: ADR 0004 makes the seventh column a downstream contract for property-grouped
  unique-user metrics and EP-19. The live migration ledger is already occupied through
  `0010`; applied files are immutable.
  Date: 2026-07-19

- Decision: `identity_map`/`mv_identity_map` are retired in a *separate* follow-up
  migration, applied only after the stability battery passes — not in the migration that
  introduces the replacement.
  Rationale: MP-2 EP-12 established the deferred-drop discipline (its 0004 kept the old
  table until 0007 verified). While both exist, `identity_map` keeps filling harmlessly
  and is the rollback target.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 completed on 2026-07-19. The API, client, OpenAPI document, writer, and
ClickHouse storage now carry the optional identifier map as one compatible wire change.
The test suites passed with 109 core examples and 10 client examples (one opt-in live
client test pending), and the authenticated HTTP proof accepted a fingerprint/device
event while rejecting an unknown kind with the complete allowed vocabulary.

Milestone 2 completed on 2026-07-19. A fresh ClickHouse reset replayed all twelve
migrations, the identity fixture produced cookie and fingerprint evidence, anonymous
sessions converged to one canonical user, and the cookie-only control remained two users.
The conflict fixture retained both users and resolved equal-confidence fingerprint
bindings by recency. `DESCRIBE analytics.events_resolved` remained identical to the
pre-milestone seven-column contract.


## Context and Orientation

Kansoku is a Haskell analytics service in this repository, built as four cabal packages:

- `kansoku-api` — servant API types and the wire model. The event record lives in
  `kansoku-api/src/Kansoku/Event/Types.hs` (`AnalyticsEvent`, with newtype ids like
  `AnonymousId`, `UserId`, `AccountId`). Pure validation lives in
  `kansoku-api/src/Kansoku/Event/Validation.hs` (`ValidationError`, `validateEvent`).
  Smart constructors (`baseEvent`, `identifyEvent`, `aliasEvent`) live in
  `kansoku-api/src/Kansoku/Event.hs`.
- `kansoku-core` — server implementation and ClickHouse plumbing. The typed row the
  batched writer inserts is `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`
  (`EventColumns` type-level column list + `EventRow` record + `eventRowFromEvent`).
  Metric SQL builders are in `kansoku-core/src/Kansoku/Query.hs`. The OpenAPI document is
  generated from the servant types in `kansoku-core/src/Kansoku/OpenApi.hs`. Tests are
  under `kansoku-core/test/` (`Kansoku/EventSpec.hs`, `Kansoku/OpenApiSpec.hs`,
  `Kansoku/QuerySpec.hs`, `Kansoku/ClickHouseSpec.hs`).
- `kansoku-server` — the executable.
- `kansoku-client` — the Haskell SDK (`kansoku-client/src/Kansoku/Client.hs`; `EventIds`
  carries the optional ids, `buildEvent` assembles an `AnalyticsEvent`).

Events flow: HTTP ingest → validation → a durable Postgres queue (pgmq) → a batched
writer → one `INSERT` per flush into ClickHouse `analytics.events_raw`. ClickHouse schema
changes are made ONLY through versioned migration files under `db/clickhouse/migrations/`,
applied by `just ch-migrate`, which (since MasterPlan 2's EP-12,
`docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`)
records applied filenames in `analytics.schema_migrations` and applies only unapplied
files, in filename order. An applied migration file is immutable — never edit one, always
add a new file. `just ch-reset` drops and replays everything for a scratch database.

Development runs inside `nix develop` with `process-compose up` providing Postgres and
ClickHouse; `just build` = `cabal build all`, `just test` = `cabal test`. GHC 9.12.4.
Code standards (already in force in every module you will touch — keep them): GHC2024,
import `Kansoku.Prelude`, postpositive qualified imports (`import Data.Text qualified as
Text`), generic-lens `#label` optics for field access, strict fields (`!`), explicit
`deriving stock`/`deriving newtype`/`deriving anyclass`, and `MultilineStrings` for any
SQL embedded in Haskell (this plan embeds none — all SQL lives in migration files).

This plan runs strictly AFTER MasterPlan 2
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`)
is complete. The MP-2 contracts this plan builds on, stated so you can verify them before
starting (Concrete Steps, step 0):

Relevant durable context is recorded in
`docs/adr/0004-queryable-event-properties-and-identity-resolved-projection.md`, which
owns the seven-column resolved-event projection, and
`docs/adr/0005-evidence-based-multi-signal-identity-resolution.md`, which owns the signal
vocabulary, evidence semantics, ranking policy, conflict visibility, and fingerprint
retention boundary.

- Post EP-12, `analytics.events_raw` identity columns are plain `String DEFAULT ''`
  (empty string means absent — NOT `Nullable`), the sort key is
  `(account_id, event_name, occurred_at, event_id)` on `ReplacingMergeTree(received_at)`,
  `analytics.events_resolved` reads WITHOUT `FINAL`, and the `dau`/`wau` materialized
  views are join-free over the *raw* identity `if(user_id != '', user_id, anonymous_id)`
  (they do not consult the identity map and this plan does not touch them).
- Post EP-15 (`docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`),
  ingest is authenticated, the server stamps every event's `account_id` from the caller's
  key, metric queries carry a mandatory account predicate, and `events_resolved` exposes
  `account_id`. Identity data is tenant data: every object this plan creates carries
  `account_id` and every view keys on it.
- Post plan 9 / EP-14, `kansoku-api` wire-type changes are SDK-grade: `kansoku-client`
  and the generated OpenAPI document move in the SAME commits as the API type.

Current identity machinery this plan replaces, in
`db/clickhouse/migrations/0002_identity.sql` (as amended by EP-12's 0004/0005 and EP-15):
`analytics.identity_map` is `ReplacingMergeTree(version) ORDER BY anonymous_id` — at most
one row per `anonymous_id` survives merges, newest `version` (= `received_at`) wins.
`analytics.mv_identity_map` fills it from `identify`/`alias` events that carry both ids.
`analytics.events_resolved` LEFT JOINs the collapsed map and computes `canonical_user =
coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')`.
Its consumers in `kansoku-core/src/Kansoku/Query.hs` (unique users, retention, funnel,
ratio) aggregate `canonical_user` with `uniqExact`/`min`, which is why FINAL-free reads
are safe (duplicate rows cannot change a distinct count) — a property this plan preserves.

Two terms used throughout: a **signal** is one (kind, value) identifier observation, e.g.
`("fingerprint", "fp-F")`; a **binding** is evidence that a signal was seen on the same
event as a `user_id`, i.e. a row "signal → user".

Migration numbering was reconciled at implementation start. MP-2 occupies files
`0004`–`0008` and EP-17 occupies `0009`–`0010`, so this plan uses
`0011_events_raw_identifiers.sql`, `0012_identity_signals.sql`, and
`0013_retire_identity_map.sql`. Applied migration files are immutable.


## Plan of Work

The work is three milestones. M1 makes the wire model carry identifier evidence and
persists it (nothing reads it yet — purely additive, everything keeps working). M2 builds
the evidence store, the confidence policy, and swaps resolution underneath the frozen
`events_resolved` contract, with the fixture story as proof. M3 delivers the privacy
posture (TTL + deletion runbook), retires the old map, and proves output-shape stability
for downstream consumers.


### Milestone 1 — The `identifiers` wire field, validation, and persistence

Scope: `AnalyticsEvent` gains an optional `identifiers :: Maybe (Map Text Text)` field
(kind → value); validation enforces the closed kind set and value hygiene; `events_raw`
gains an `identifiers` column and the writer persists the field; `kansoku-client` and the
OpenAPI document move in the same commit. At the end, a curl POST carrying
`"identifiers": {"fingerprint": "fp-F"}` is accepted and the value is visible in
ClickHouse, a POST with an unknown kind is rejected with an error listing the allowed
kinds, and every pre-existing producer (which omits the field) works unchanged.

Wire type, `kansoku-api/src/Kansoku/Event/Types.hs`. Add `import Data.Map.Strict (Map)`
(the package already depends on `containers`). Add the identifier-kind vocabulary and
export it (`IdentifierKind (..)`, `identifierKindToText`, `identifierKindFromText`,
`allowedIdentifierKindNames`):

```haskell
-- | Closed set of identifier-signal kinds an event may carry in its
-- @identifiers@ map. Extending this set is a policy act: a new kind needs a
-- confidence entry in the analytics.identity_bindings view and a retention
-- decision (see docs/plans/18-multi-signal-identity-...md, Decision Log).
data IdentifierKind = Cookie | Device | Fingerprint | EmailSha256
  deriving stock (Generic, Eq, Ord, Show, Enum, Bounded)

identifierKindToText :: IdentifierKind -> Text
identifierKindToText k = case k of
  Cookie -> "cookie"
  Device -> "device"
  Fingerprint -> "fingerprint"
  EmailSha256 -> "email_sha256"

identifierKindFromText :: Text -> Maybe IdentifierKind
identifierKindFromText t = case t of
  "cookie" -> Just Cookie
  "device" -> Just Device
  "fingerprint" -> Just Fingerprint
  "email_sha256" -> Just EmailSha256
  _ -> Nothing

allowedIdentifierKindNames :: [Text]
allowedIdentifierKindNames = identifierKindToText <$> [minBound .. maxBound]
```

Then add one field to `AnalyticsEvent`, immediately after `userId` so the identity fields
read together:

```haskell
    userId :: !(Maybe UserId),
    identifiers :: !(Maybe (Map Text Text)),
```

The existing `analyticsEventOptions` (`omitNothingFields = True`,
`rejectUnknownFields = False`) makes this fully additive on the wire: producers that omit
the key parse to `Nothing`, and `Nothing` serializes to an absent key, so recorded
payloads and old SDKs are byte-identical. The JSON key is `identifiers` (the Haskell field
name; generic derivation uses it verbatim, as with every other field). The map keys are
the *kind strings* above; `anonymousId` and `userId` remain on the wire and are treated as
implicit signals of kind `cookie` and as the explicit user respectively — clients should
NOT duplicate the cookie into `identifiers` (it is legal but redundant). Aeson's stock
`FromJSON`/`ToJSON` for `Map Text Text` gives the `{"kind": "value"}` object encoding; no
instance work is needed. Also update `baseEvent` in `kansoku-api/src/Kansoku/Event.hs` to
initialize `identifiers = Nothing`.

Validation, `kansoku-api/src/Kansoku/Event/Validation.hs`. Add
`import Data.Map.Strict qualified as Map` and `import Data.Text qualified as Text`.
Extend `ValidationError`:

```haskell
  | UnknownIdentifierKind Text [Text]      -- offending kind, allowed kinds
  | EmptyIdentifierValue Text              -- kind whose value is empty
  | IdentifierValueTooLong Text Int Int    -- kind, actual length, maximum
  | IdentifierValueBadCharset Text         -- kind whose value has illegal chars
```

and add the checks (wired into `validateEventWith` alongside `structuralErrors`, so they
run on every event regardless of registry knowledge):

```haskell
    identifierErrors =
      case identifiers event of
        Nothing -> []
        Just ids -> concatMap identifierError (Map.toList ids)

    identifierError (kind, value) =
      [ UnknownIdentifierKind kind allowedIdentifierKindNames
        | isNothing (identifierKindFromText kind)
      ]
        <> [EmptyIdentifierValue kind | Text.null value]
        <> [ IdentifierValueTooLong kind (Text.length value) maxIdentifierValueLength
           | Text.length value > maxIdentifierValueLength
           ]
        <> [ IdentifierValueBadCharset kind
           | not (Text.all isIdentifierValueChar value)
           ]

maxIdentifierValueLength :: Int
maxIdentifierValueLength = 256

-- | Printable ASCII excluding space. Hex digests, base64, UUIDs, and opaque
-- device tokens all pass; control characters, whitespace, and non-ASCII fail.
isIdentifierValueChar :: Char -> Bool
isIdentifierValueChar c = c > ' ' && c <= '~'
```

The result: unknown kinds are a validation error whose payload lists the allowed kinds;
values must be non-empty, at most 256 characters, printable non-space ASCII. How a
validation error becomes an HTTP response follows the MP-2 EP-14 ingest contract
(per-event rejection in a batch, 4xx for a single event) — this plan changes no plumbing
there, only adds error constructors, so whatever rendering exists picks them up; if the
error-rendering code enumerates constructors exhaustively, extend it in the same commit.

Storage column, new migration `db/clickhouse/migrations/0011_events_raw_identifiers.sql`:

```sql
-- EP-18 M1: persist the identifiers map (kind -> value) on raw events.
-- Representation: JSON object encoded as String, matching properties/context.
-- '{}' (not '') as the default keeps every row valid JSON for the
-- JSONExtractKeysAndValues calls in mv_identity_signals / events_resolved.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS identifiers String DEFAULT '{}' AFTER context;
```

`ALTER TABLE ... ADD COLUMN` is metadata-only in ClickHouse: existing parts are not
rewritten; old rows read the default `'{}'`. The column is deliberately NOT added to the
`ORDER BY` (the ReplacingMergeTree dedup identity is untouched, so queue-replay dedup
behaves exactly as before).

Writer mapping, `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`. Append to the END of
the `EventColumns` type-level list (matching the SQL column's position after `context`):

```haskell
     Column "properties" ChString,
     Column "context" ChString,
     Column "identifiers" ChString
```

add the field `identifiers :: !ByteString` at the end of `EventRow`, and in
`eventRowFromEvent`:

```haskell
      identifiers = maybe "{}" identifiersBytes (event ^. #identifiers)
```

with a small helper next to `objectBytes` (add `import Data.Map.Strict (Map)`;
`kansoku-core` already depends on `containers`):

```haskell
identifiersBytes :: Map Text Text -> ByteString
identifiersBytes = LBS.toStrict . Aeson.encode
```

`Aeson.encode` on `Map Text Text` produces exactly the `{"kind":"value"}` object.

Client, `kansoku-client/src/Kansoku/Client.hs`, same commit. Add
`identifiers :: !(Maybe (Map Text Text))` to `EventIds` (import `Data.Map.Strict (Map)`;
add `containers` to `kansoku-client.cabal` build-depends if it is not already there),
initialize it to `Nothing` in `emptyIds`, and thread it in `buildEvent`:

```haskell
      & #identifiers
      .~ (ids ^. #identifiers)
```

This gives every SDK helper (`trackEvent`, `identify`, `alias`, `group`) identifier
support through the ids record: `emptyIds & #identifiers ?~ Map.fromList
[("fingerprint", "fp-F")]`. Note for the fixture story and for real SDKs alike: send the
current identifier set ON the identify call itself — bindings are event-local (Decision
Log), so the identify event carrying the fingerprint is what binds fingerprint → user.

OpenAPI, `kansoku-core/src/Kansoku/OpenApi.hs`, same commit. `AnalyticsEvent`'s
`ToSchema` instance is generically derived, and the `openapi3` library ships a `ToSchema`
instance for `Map Text Text` (rendered as an object with `additionalProperties: {type:
string}`), so usually no code change is needed — but the generated document CHANGES, and
`kansoku-core/test/Kansoku/OpenApiSpec.hs` asserts over it; update its expectations in
this commit. If the `Map Text Text` instance is missing in the pinned openapi3 version,
add an explicit schema in `OpenApi.hs` via `declareNamedSchema` producing an object
schema with `additionalProperties` of type string, and document the field's closed kind
set in its description.

Tests, `kansoku-core/test/Kansoku/EventSpec.hs` (or wherever event JSON/validation specs
live at implementation time): (a) JSON roundtrip of an event with
`identifiers = Just (Map.fromList [("fingerprint","fp-1"),("email_sha256","ab12")])`;
(b) a payload WITHOUT the key parses to `identifiers = Nothing` (wire compatibility);
(c) `validateEvent` rejects kind `"mac_address"` with
`UnknownIdentifierKind "mac_address" ["cookie","device","fingerprint","email_sha256"]`;
(d) empty, 257-char, and non-ASCII values each produce their error; (e) all four legal
kinds with legal values validate cleanly.

Acceptance: `just ch-migrate` applies the new file (and skips all prior ones);
`just build` and `just test` green; the curl transcript in Validation and Acceptance
(ingest with identifiers → row visible; unknown kind → rejection naming the allowed
kinds). Commit (conventional commits; both trailers mandatory):

```text
feat(api): optional identifiers map on AnalyticsEvent with closed kind set

Add identifiers :: Maybe (Map Text Text) (kinds: cookie, device, fingerprint,
email_sha256; unknown kinds and malformed values are validation errors), an
events_raw identifiers String DEFAULT '{}' column via migration, the EventRow
mapping, kansoku-client EventIds support, and the regenerated OpenAPI schema —
all in one change per the MP-2 EP-14 wire-discipline.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md
```


### Milestone 2 — Evidence store, confidence policy, and confidence-aware resolution

Scope: one migration creates `analytics.identity_signals` (append-only evidence),
`analytics.mv_identity_signals` (fills it at insert time), a backfill of historical
evidence, `analytics.identity_bindings` (the confidence policy view),
`analytics.identity_conflicts` (conflicts stay queryable), and replaces
`analytics.events_resolved` with confidence-aware resolution under the frozen output
contract. `identity_map` and `mv_identity_map` are left in place (retired in M3). At the
end, the full fixture story in Validation and Acceptance runs with the documented
numbers.

Before writing the migration, capture the current contract so you can prove you kept it:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "DESCRIBE TABLE analytics.events_resolved" | tee /tmp/events_resolved_columns_before.txt
```

Expected after EP-17: exactly `event_id`, `event_name`, `occurred_at`, `url`,
`account_id`, `canonical_user`, `properties_json` (types `String`,
`LowCardinality(String)`, `DateTime64(3,'UTC')`, `String`, `String`, `String`, `JSON`).
If what you see differs, stop and reconcile with ADR 0004 and the actual landed tree before
proceeding — the replacement view below must reproduce the incumbent's column list
verbatim.

New migration `db/clickhouse/migrations/0012_identity_signals.sql`:

```sql
-- EP-18 M2: evidence-based identity.
--
-- identity_signals is an append-only evidence log: one row per observation of
-- "signal (kind, value) was seen on the same event as user_id", scoped by
-- account (identity data is tenant data — MP-2 EP-15). Engine choice: the
-- ORDER BY tuple includes user_id, observed_at, AND event_id, so
-- ReplacingMergeTree collapses only exact queue-replay duplicates; distinct
-- observations — including the same signal bound to DIFFERENT users — are all
-- kept forever. Conflicts are data here, not merge casualties.
--
-- Retention: fingerprint evidence is personal data (GDPR); rows of kind
-- 'fingerprint' expire after 180 days (configurable policy — the default is
-- recorded in the ExecPlan Decision Log). The toDateTime() cast is
-- load-bearing: TTL expressions must be Date/DateTime and observed_at is
-- DateTime64(3).
CREATE TABLE IF NOT EXISTS analytics.identity_signals
(
    account_id   String,
    signal_kind  LowCardinality(String),
    signal_value String,
    user_id      String,
    observed_at  DateTime64(3, 'UTC'),
    event_id     String
)
ENGINE = ReplacingMergeTree
ORDER BY (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY DELETE WHERE signal_kind = 'fingerprint';

-- Insert-time extraction of binding evidence from raw events.
-- Cookie bindings only from identify/alias (preserves mv_identity_map's
-- semantics); identifiers-map bindings from ANY event carrying a user_id.
-- The arrayFilter drops the cookie tuple on non-identify events (its kind
-- slot is '') and any empty values; validation upstream already forbids empty
-- identifier values, so the filter is belt and braces.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_identity_signals
TO analytics.identity_signals
AS
SELECT
    account_id,
    sig.1 AS signal_kind,
    sig.2 AS signal_value,
    user_id,
    received_at AS observed_at,
    event_id
FROM analytics.events_raw
ARRAY JOIN arrayFilter(
    kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat(
        [(if(event_name IN ('identify', 'alias'), 'cookie', ''), anonymous_id)],
        JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
WHERE user_id != '';

-- Backfill: run the MV's SELECT once over history. Historical rows have
-- identifiers = '{}' (the M1 column default), so this reproduces exactly the
-- identify/alias cookie bindings that identity_map already holds — resolution
-- of existing data is unchanged by construction. Idempotence note: re-running
-- inserts byte-identical rows, which the ORDER BY tuple dedups at merge.
INSERT INTO analytics.identity_signals
    (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
SELECT
    account_id,
    sig.1 AS signal_kind,
    sig.2 AS signal_value,
    user_id,
    received_at AS observed_at,
    event_id
FROM analytics.events_raw
ARRAY JOIN arrayFilter(
    kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat(
        [(if(event_name IN ('identify', 'alias'), 'cookie', ''), anonymous_id)],
        JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
WHERE user_id != '';

-- The confidence policy, encoded in exactly ONE place. Static per-kind
-- confidences (explicit user_id on an event is 1.0 implicitly — it
-- short-circuits resolution before bindings are consulted):
--   email_sha256 0.95 | cookie 0.90 | device 0.80 | fingerprint 0.50
-- Revising the policy = one migration recreating this view; history is
-- re-scored uniformly and audit is trivial (read the multiIf). The rejected
-- alternative — a stored confidence float per row — would freeze policy at
-- write time and make revisions a data rewrite (see ExecPlan Decision Log).
CREATE VIEW IF NOT EXISTS analytics.identity_bindings
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    user_id,
    observed_at,
    multiIf(
        signal_kind = 'email_sha256', 0.95,
        signal_kind = 'cookie',       0.90,
        signal_kind = 'device',       0.80,
        signal_kind = 'fingerprint',  0.50,
        0.0) AS confidence
FROM analytics.identity_signals;

-- Merge conflicts stay queryable: every signal value observed with more than
-- one user, with the full user list and observation stats. Resolution does
-- NOT hide these — it picks a winner by (confidence, recency) and this view
-- shows what it picked over.
CREATE VIEW IF NOT EXISTS analytics.identity_conflicts
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    groupUniqArray(user_id) AS user_ids,
    uniqExact(user_id) AS user_count,
    count() AS observation_count,
    max(observed_at) AS last_observed_at
FROM analytics.identity_signals
GROUP BY account_id, signal_kind, signal_value
HAVING user_count > 1;

-- Confidence-aware resolution. OUTPUT CONTRACT FROZEN: name and columns
-- (event_id, event_name, occurred_at, url, account_id, canonical_user,
-- properties_json) must match the incumbent view exactly. Property-grouped
-- unique-user metrics and EP-19 consume the server-only JSON projection.
--
-- canonical_user =
--   1. the event's explicit user_id, if present (confidence 1.0 by fiat);
--   2. else the user bound to any of the event's signals (implicit cookie
--      from anonymous_id, plus the identifiers map), ranked by
--      (confidence, observed_at) descending, above the 0.50 threshold;
--   3. else the event's cookie id (anonymous_id), else ''.
--
-- FINAL-free per MP-2 EP-12: consumers aggregate canonical_user with
-- uniqExact/min, which are insensitive to transient replay duplicates; the
-- GROUP BY event_id in the stitching subquery keeps duplicates from
-- multiplying join output. Row-COUNT consumers must protect themselves
-- (count DISTINCT event_id), as before.
--
-- join_use_nulls = 0 note (same trap 0002 documented): a LEFT JOIN miss
-- fills r.stitched_user with '', not NULL, so the multiIf tests != ''.
CREATE VIEW IF NOT EXISTS analytics.events_resolved_v3
AS
WITH event_signal_users AS
(
    SELECT
        s.account_id AS account_id,
        s.event_id AS event_id,
        argMax(b.user_id, tuple(b.confidence, b.observed_at)) AS stitched_user
    FROM
    (
        SELECT
            account_id,
            event_id,
            sig.1 AS signal_kind,
            sig.2 AS signal_value
        FROM analytics.events_raw
        ARRAY JOIN arrayFilter(
            kv -> kv.2 != '',
            arrayConcat(
                [('cookie', anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
        WHERE user_id = ''
    ) AS s
    INNER JOIN analytics.identity_bindings AS b
        ON  b.account_id   = s.account_id
        AND b.signal_kind  = s.signal_kind
        AND b.signal_value = s.signal_value
    WHERE b.confidence >= 0.50
    GROUP BY s.account_id, s.event_id
)
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    e.account_id AS account_id,
    multiIf(
        e.user_id != '', e.user_id,
        r.stitched_user != '', r.stitched_user,
        e.anonymous_id) AS canonical_user,
    e.properties_json AS properties_json
FROM analytics.events_raw AS e
LEFT JOIN event_signal_users AS r
    ON r.account_id = e.account_id AND r.event_id = e.event_id;

-- Atomic contract swap: consumers never see a missing events_resolved.
DROP VIEW IF EXISTS analytics.events_resolved;
CREATE VIEW analytics.events_resolved AS SELECT * FROM analytics.events_resolved_v3;
```

Design notes a novice needs, restated in prose. The stitching subquery only expands
events with `user_id = ''` — identified events short-circuit at rule 1 and never pay the
ARRAY JOIN. `ARRAY JOIN` over an empty array drops the row, so signal-less anonymous
events simply miss the join and fall through to the cookie fallback. `argMax(user_id,
tuple(confidence, observed_at))` implements the documented ranking: among all bindings
reachable from the event's signals, the highest confidence wins, and within equal
confidence the most recent observation wins — that tuple ordering is the ONLY
tie-breaking rule, and the conflict fixture in Validation exercises it. Resolution is
query-time, so fixture insertion order does not matter (unlike the old insert-time
dau/wau join that EP-12 removed). The two-step `events_resolved_v3` + thin
`events_resolved` alias costs nothing (views compose at parse time) and makes the M3
retirement/rollback story a one-line view swap. Equivalence with the old model, for the
data that exists today: historical rows carry only identify/alias cookie bindings, and
for those `argMax by (0.90, observed_at)` degenerates to `argMax(user_id, version)` — the
exact latest-wins the old collapsed `identity_map` subquery computed, which is why the M3
stability battery is expected to reproduce MP-2-era numbers identically.

No Haskell changes in this milestone. `mv_dau`/`mv_wau` are untouched (they aggregate raw
identities post-EP-12 and never consulted the map). `identity_map`/`mv_identity_map` keep
filling, unused by resolution — that is intentional (rollback target until M3).

Fixture files (the full story with expected numbers lives in Validation and Acceptance):
create `db/clickhouse/fixtures/ep18_fixtures.sql` and
`db/clickhouse/fixtures/ep18_conflict.sql` exactly as shown there, and add two justfile
recipes mirroring the existing ones:

```text
# Load the EP-18 multi-signal identity fixtures.
ch-fixtures-ep18:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep18_fixtures.sql

# Load the EP-18 conflict-phase fixture (run after ch-fixtures-ep18).
ch-fixtures-ep18-conflict:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep18_conflict.sql
```

Acceptance: on a `just ch-reset` database, `just ch-migrate` applies cleanly;
`DESCRIBE TABLE analytics.events_resolved` is byte-identical to
`/tmp/events_resolved_columns_before.txt`; the fixture transcripts in Validation and
Acceptance produce exactly the documented numbers (1 with fingerprints, 2 without,
conflict listed and ranked); `just test` stays green. Commit:

```text
feat(clickhouse): identity_signals evidence store and confidence-aware resolution

Add analytics.identity_signals (append-only, exact-duplicate-dedup only, all
observations kept), mv_identity_signals + history backfill, the
identity_bindings static per-kind confidence view (email_sha256 .95, cookie
.90, device .80, fingerprint .50; threshold .50), identity_conflicts, and a
FINAL-free events_resolved that resolves explicit user_id, then best
(confidence, recency) signal binding, then cookie — output columns unchanged.
identity_map is left in place until the M3 stability battery passes.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md
```


### Milestone 3 — Privacy enforcement, deletion runbook, retirement, stability battery

Scope: prove the fingerprint TTL deletes what it should and nothing else; write and
exercise the per-user deletion runbook (`docs/runbooks/identity-data-deletion.md`);
re-run the MP-2-era resolution battery to prove `canonical_user` output-shape stability
(the EP-19 invariant from MasterPlan 3's Integration Points); retire
`identity_map`/`mv_identity_map`; update MasterPlan 3's Progress checkboxes and record
the `identifiers` field-name claim under its "AnalyticsEvent wire type" integration point.

TTL verification. The TTL clause was created in M2; TTL enforcement happens at merge
time, so demonstrate it deterministically by inserting pre-aged evidence and forcing a
merge (exact transcript in Validation and Acceptance): one fingerprint row and one cookie
row, both observed 200 days ago, then `OPTIMIZE TABLE analytics.identity_signals FINAL`
— the fingerprint row must vanish, the cookie row must survive. Also verify the clause
itself: `SHOW CREATE TABLE analytics.identity_signals` contains
`TTL toDateTime(observed_at) + toIntervalDay(180) WHERE signal_kind = 'fingerprint'`
(ClickHouse normalizes `INTERVAL 180 DAY` to `toIntervalDay(180)` and elides the
default `DELETE` action when printing).

Deletion runbook, new file `docs/runbooks/identity-data-deletion.md`. Its content is a
prose walkthrough of the following statements (parameterize `ACCOUNT` and `USER`), with
the mutation-cost warning included verbatim. Order matters — collect signal values
BEFORE deleting the evidence rows that let you find them:

```sql
-- Step 1 (read-only): enumerate the user's known signal values. Save this
-- output; steps 3 and 4 need it and step 5 destroys the source.
SELECT DISTINCT signal_kind, signal_value
FROM analytics.identity_signals
WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

-- Step 2: scrub the identifiers column on the user's own events.
ALTER TABLE analytics.events_raw
UPDATE identifiers = '{}'
WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

-- Step 3: scrub anonymous events carrying any of the user's signal values
-- (substitute the step-1 values into the IN list).
ALTER TABLE analytics.events_raw
UPDATE identifiers = '{}'
WHERE account_id = 'ACCOUNT'
  AND user_id = ''
  AND arrayExists(kv -> kv.2 IN ('VALUE1', 'VALUE2'),
                  JSONExtractKeysAndValues(identifiers, 'String'));

-- Step 4 (optional, full-event erasure — the bigger GDPR hammer, listed for
-- completeness; identity scrubbing alone is steps 2-3):
-- ALTER TABLE analytics.events_raw
-- DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

-- Step 5: delete the evidence rows.
ALTER TABLE analytics.identity_signals
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

-- Step 6: watch the mutations drain (all of the above are asynchronous
-- part-rewriting mutations — expensive on large tables; run off-peak, one
-- account at a time).
SELECT mutation_id, command, is_done, latest_fail_reason
FROM system.mutations
WHERE is_done = 0;
```

The runbook also carries the *retention* mutation that aligns `events_raw` with the
fingerprint policy (the TTL covers `identity_signals`; raw events keep their
`identifiers` JSON, so fingerprints older than the retention window are scrubbed from the
raw column by a periodically-run mutation — policy, not automation, per the Decision
Log):

```sql
-- Remove only the fingerprint key from identifiers on old rows, preserving
-- other kinds. toJSONString(map) re-encodes {'k':'v'} as a JSON object; an
-- emptied map encodes as '{}'. Verify toJSONString/mapFromArrays exist on the
-- deployed ClickHouse version; the blunt fallback is UPDATE identifiers = '{}'.
ALTER TABLE analytics.events_raw
UPDATE identifiers = toJSONString(mapFromArrays(
        arrayMap(kv -> kv.1, arrayFilter(kv -> kv.1 != 'fingerprint',
                 JSONExtractKeysAndValues(identifiers, 'String'))),
        arrayMap(kv -> kv.2, arrayFilter(kv -> kv.1 != 'fingerprint',
                 JSONExtractKeysAndValues(identifiers, 'String')))))
WHERE occurred_at < now() - INTERVAL 180 DAY
  AND JSONHas(identifiers, 'fingerprint');
```

Exercise the runbook once against fixture data (transcript in Validation and Acceptance:
after running steps 1–3 and 5 for `user-U`, the user's evidence rows are gone, their
events' `identifiers` read `'{}'`, and their previously-stitched anonymous events fall
back to cookie resolution).

Stability battery (the EP-19 invariant). On a fresh `just ch-reset` + `just ch-migrate`
database, load the MP-2-era fixtures (`just ch-fixtures-ep5`, `just ch-fixtures-ep6`) and
re-run the EP-12 acceptance queries recorded in
`docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`:
the stitched unique-user count over `events_resolved` for 2026-06-08 must still be `3`
(`anon-2` resolves to `user-10` through its identify cookie binding; `user-20` explicit;
`anon-3` falls back to itself), the raw-identity `dau` merge must still be `4`, and
`DESCRIBE TABLE analytics.events_resolved` must match the pre-M2 capture. Run
`cabal test` (`just test`) — `QuerySpec`, `ClickHouseSpec`, and the rest must be green
with zero query-side changes. This demonstrates precisely the MasterPlan 3 integration
guarantee: rollups and builders keyed on `canonical_user` are correct before and after
the resolution swap.

Retirement, new migration `db/clickhouse/migrations/0013_retire_identity_map.sql`,
applied ONLY after the battery passes:

```sql
-- EP-18 M3: identity_map is superseded by identity_signals + identity_bindings.
-- The backfill in 0009 reproduced its content (identify/alias cookie bindings)
-- and the stability battery verified identical resolution; safe to drop.
DROP TABLE IF EXISTS analytics.mv_identity_map;
DROP TABLE IF EXISTS analytics.identity_map;
```

Finally: update MasterPlan 3 — tick its three EP-18 Progress entries as they complete,
and add a line to its "AnalyticsEvent wire type" integration point recording that EP-18
shipped the field as `identifiers` (so EP-20 names its schema-version field disjointly).

Acceptance: TTL transcript, runbook transcript, and battery transcript all recorded in
this plan (Surprises & Discoveries if anything deviated); `just test` green. Commit:

```text
feat(clickhouse): fingerprint TTL proof, identity deletion runbook, retire identity_map

Verify the 180-day fingerprint TTL on identity_signals (aged fingerprint row
merged away, cookie row survives), add docs/runbooks/identity-data-deletion.md
with per-user mutation statements and the events_raw fingerprint-scrub, re-run
the MP-2 resolution battery proving canonical_user output-shape stability, and
drop the superseded identity_map/mv_identity_map.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md
```


## Concrete Steps

All commands run at the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside `nix develop`, with
services up via `process-compose up` (or `just up`) in another terminal.

Step 0 — verify the MP-2 ground you stand on (do not skip):

```bash
ls db/clickhouse/migrations/            # note the next free numbers; adjust filenames
just ch-migrate                         # must report already-applied files as skipped
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "SHOW CREATE TABLE analytics.events_raw" | grep -E "identifiers|anonymous_id|ORDER BY"
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "DESCRIBE TABLE analytics.events_resolved"
just build && just test                 # green before you touch anything
```

Expect: `anonymous_id String DEFAULT ''` (post-EP-12; if you see `Nullable(String)`,
MP-2 is not complete — stop), no `identifiers` column yet, and the seven
`events_resolved` columns listed in Milestone 2. If `analytics.schema_migrations` does
not exist, EP-12 has not landed — stop.

Step 1 — Milestone 1 edits, in this order: `Types.hs` (kind vocabulary + field),
`Event.hs` (`baseEvent`), `Validation.hs` (errors + checks), migration file,
`EventRow.hs`, `Client.hs`, `OpenApi.hs`/`OpenApiSpec.hs` expectations, `EventSpec.hs`
tests. Then:

```bash
just ch-migrate     # applies 0011_events_raw_identifiers.sql only
just build
just test
```

Expected test output ends with all specs passing (`0 failures`). Run the M1 curl
transcript from Validation and Acceptance and commit (one commit — wire type, client,
OpenAPI together).

Step 2 — Milestone 2: capture the `DESCRIBE` baseline, write
`0012_identity_signals.sql`, the two fixture files, and the justfile recipes. Then:

```bash
just ch-reset && just ch-migrate
diff <(clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "DESCRIBE TABLE analytics.events_resolved") /tmp/events_resolved_columns_before.txt
just ch-fixtures-ep18
```

The `diff` must be empty. Run the phase-1 and phase-2 fixture queries from Validation and
Acceptance, compare every number, run `just test`, commit.

Step 3 — Milestone 3: run the TTL demonstration, write and exercise the runbook, run the
stability battery:

```bash
just ch-reset && just ch-migrate && just ch-fixtures-ep5 && just ch-fixtures-ep6
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT uniqExact(canonical_user) FROM analytics.events_resolved
  WHERE canonical_user != '' AND toDate(occurred_at) = '2026-06-08'"   # expect 3
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT uniqExactMerge(users) FROM analytics.dau WHERE day = '2026-06-08'"  # expect 4
just test
```

Then add `0013_retire_identity_map.sql`, `just ch-migrate`, re-run the two queries above
(same numbers — nothing read the map anymore), update MasterPlan 3, update this plan's
living sections, commit.


## Validation and Acceptance

### M1: wire field end to end (curl transcript)

With the server running (`just run` in another terminal; default port per
`kansoku-core/src/Kansoku/Config.hs`). Post-EP-15 ingest is authenticated: obtain a
write key by EP-15's issuance path and export it as `KANSOKU_WRITE_KEY`; the server
stamps `account_id` from the key, so the value below lands under the key's account. If
running a pre-auth local build, drop the header.

```bash
curl -sS -X POST http://localhost:8080/v1/events \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KANSOKU_WRITE_KEY" \
  -d '{
    "eventId": "ep18-m1-1",
    "eventName": "page_view",
    "source": "web",
    "occurredAt": "2026-07-01T09:00:00Z",
    "receivedAt": "2026-07-01T09:00:00.100Z",
    "anonymousId": "anon-m1",
    "url": "https://app.example.com/pricing",
    "identifiers": {"fingerprint": "fp-m1", "device": "dev-m1"},
    "properties": {},
    "context": {}
  }'
```

Expected: HTTP 202 with the ingest ack. After the writer's next flush (about a second):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT event_id, identifiers FROM analytics.events_raw WHERE event_id = 'ep18-m1-1'"
```

```text
ep18-m1-1	{"device":"dev-m1","fingerprint":"fp-m1"}
```

(Key order may differ — aeson encodes `Map` in key order.) Now the rejection: repeat the
POST with `"identifiers": {"mac_address": "aa:bb"}` and a fresh `eventId`. Expected: a
4xx response (per the MP-2 EP-14 contract shape) whose error payload names
`UnknownIdentifierKind`, the offending kind `mac_address`, and the allowed list
`cookie, device, fingerprint, email_sha256` — and no row appears in `events_raw`. Also
verify compatibility: the same POST with the `identifiers` key removed entirely is
accepted (existing producers unaffected).

Implementation transcript (2026-07-19, isolated `kansoku_ep18` PostgreSQL database and
port 18080 because process-compose's control server occupied localhost:8080):

```text
POST identifiers={device:dev-m1,fingerprint:fp-m1}
{"accepted":1,"eventId":"ep18-m1-1"}
HTTP 202

SELECT event_id, identifiers ...
ep18-m1-1    {"device":"dev-m1","fingerprint":"fp-m1"}

POST identifiers={mac_address:aa:bb}
{"code":"validation_failed","message":"validation failed: identifier kind 'mac_address' is not supported; allowed kinds: cookie, device, fingerprint, email_sha256","retryable":false}
HTTP 400

POST with identifiers omitted
{"accepted":1,"eventId":"ep18-m1-compatible"}
HTTP 202
```

### M2: the fixture story

`db/clickhouse/fixtures/ep18_fixtures.sql` — two accounts tell the with/without story in
one load. `acct-1` carries fingerprints; `acct-ctl` is the identical story WITHOUT
fingerprints (what the old model sees). Cookie A and cookie B are two browser sessions of
the SAME person; the person identifies as `user-U` only in session A; the SDK attaches
the fingerprint to every event including the identify (the event-local binding
assumption, Decision Log):

```sql
-- EP-18 fixture: two sessions, one fingerprint, one identify.
-- Insertion order is irrelevant: resolution is query-time.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, account_id, anonymous_id, user_id, url, identifiers)
VALUES
    ('s-a1', 'page_view',    'web', '2026-07-01 09:00:00.000', '2026-07-01 09:00:00.100', 'acct-1', 'anon-A', '',       'https://app.example.com/pricing', '{"fingerprint":"fp-F"}'),
    ('s-a2', 'page_view',    'web', '2026-07-01 09:05:00.000', '2026-07-01 09:05:00.100', 'acct-1', 'anon-A', '',       'https://app.example.com/signup',  '{"fingerprint":"fp-F"}'),
    ('s-id', 'identify',     'web', '2026-07-01 09:10:00.000', '2026-07-01 09:10:00.100', 'acct-1', 'anon-A', 'user-U', '',                                '{"fingerprint":"fp-F"}'),
    ('s-b1', 'page_view',    'web', '2026-07-01 10:00:00.000', '2026-07-01 10:00:00.100', 'acct-1', 'anon-B', '',       'https://app.example.com/docs',    '{"fingerprint":"fp-F"}'),
    ('s-b2', 'feature_used', 'app', '2026-07-01 10:05:00.000', '2026-07-01 10:05:00.100', 'acct-1', 'anon-B', '',       '',                                '{"fingerprint":"fp-F"}'),
    ('c-a1', 'page_view',    'web', '2026-07-01 09:00:00.000', '2026-07-01 09:00:00.100', 'acct-ctl', 'anon-CA', '',        'https://app.example.com/pricing', '{}'),
    ('c-a2', 'page_view',    'web', '2026-07-01 09:05:00.000', '2026-07-01 09:05:00.100', 'acct-ctl', 'anon-CA', '',        'https://app.example.com/signup',  '{}'),
    ('c-id', 'identify',     'web', '2026-07-01 09:10:00.000', '2026-07-01 09:10:00.100', 'acct-ctl', 'anon-CA', 'user-CU', '',                                '{}'),
    ('c-b1', 'page_view',    'web', '2026-07-01 10:00:00.000', '2026-07-01 10:00:00.100', 'acct-ctl', 'anon-CB', '',        'https://app.example.com/docs',    '{}'),
    ('c-b2', 'feature_used', 'app', '2026-07-01 10:05:00.000', '2026-07-01 10:05:00.100', 'acct-ctl', 'anon-CB', '',        '',                                '{}');
```

Phase 1 assertions (after `just ch-reset && just ch-migrate && just ch-fixtures-ep18`).
Evidence extracted — the identify event produced BOTH a cookie binding and a fingerprint
binding:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT signal_kind, signal_value, user_id FROM analytics.identity_signals
  WHERE account_id = 'acct-1' ORDER BY signal_kind"
```

```text
cookie	anon-A	user-U
fingerprint	fp-F	user-U
```

Per-event resolution — session A stitches through cookie A (confidence 0.90), session B
stitches through fingerprint F (confidence 0.50, the only path — cookie B has no
binding):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT event_id, canonical_user FROM analytics.events_resolved
  WHERE account_id = 'acct-1' ORDER BY event_id"
```

```text
s-a1	user-U
s-a2	user-U
s-b1	user-U
s-b2	user-U
s-id	user-U
```

The headline unique-users comparison — this is what the feature adds (the query is the
`uniqueUsersSQL` shape from `kansoku-core/src/Kansoku/Query.hs`, run for each account):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT account_id, uniqExact(canonical_user) FROM analytics.events_resolved
  WHERE canonical_user != '' AND toDate(occurred_at) = '2026-07-01'
  GROUP BY account_id ORDER BY account_id"
```

```text
acct-1	1
acct-ctl	2
```

`acct-1` counts one person (`user-U`); the fingerprint-free control counts two
(`user-CU` and the orphaned `anon-CB`) — the cookie-only model double-counts the same
human. No conflicts exist yet:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT count() FROM analytics.identity_conflicts WHERE account_id = 'acct-1'"
```

```text
0
```

Phase 2 — the conflict. `db/clickhouse/fixtures/ep18_conflict.sql`: a third session
(cookie C, same fingerprint — the shared-device case) identifies as a DIFFERENT user,
later:

```sql
-- EP-18 conflict fixture: fingerprint fp-F now also observed with user-V.
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, account_id, anonymous_id, user_id, url, identifiers)
VALUES
    ('s-v', 'identify', 'web', '2026-07-01 11:00:00.000', '2026-07-01 11:00:00.100', 'acct-1', 'anon-C', 'user-V', '', '{"fingerprint":"fp-F"}');
```

After `just ch-fixtures-ep18-conflict`, the conflict is queryable, not silently resolved:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT signal_kind, signal_value, arraySort(user_ids), user_count, observation_count
  FROM analytics.identity_conflicts WHERE account_id = 'acct-1'"
```

```text
fingerprint	fp-F	['user-U','user-V']	2	2
```

And resolution follows the documented ranking — equal confidence (both fingerprint,
0.50), so recency wins for session B, while session A is untouched because its cookie
binding (0.90) outranks any fingerprint:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT event_id, canonical_user FROM analytics.events_resolved
  WHERE account_id = 'acct-1' ORDER BY event_id"
```

```text
s-a1	user-U
s-a2	user-U
s-b1	user-V
s-b2	user-V
s-id	user-U
s-v	user-V
```

The unique-users count for `acct-1` is now `2` — honest: the evidence genuinely supports
two people on that shared fingerprint.

Implementation transcript (2026-07-19, fresh reset through migration `0012`):

```text
identity_signals acct-1
cookie       anon-A  user-U
fingerprint  fp-F    user-U

events_resolved acct-1 before conflict
s-a1  user-U
s-a2  user-U
s-b1  user-U
s-b2  user-U
s-id  user-U

unique users
acct-1    1
acct-ctl  2

identity_conflicts after conflict fixture
fingerprint  fp-F  ['user-U','user-V']  2  2

events_resolved acct-1 after conflict
s-a1  user-U
s-a2  user-U
s-b1  user-V
s-b2  user-V
s-id  user-U
s-v   user-V

DESCRIBE analytics.events_resolved
event_id String
event_name LowCardinality(String)
occurred_at DateTime64(3, 'UTC')
url String
account_id String
canonical_user String
properties_json JSON
```

### M3: TTL, runbook, stability

TTL demonstration (deterministic — pre-aged rows, forced merge):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  INSERT INTO analytics.identity_signals VALUES
    ('acct-ttl', 'fingerprint', 'fp-old', 'user-old', now64(3) - INTERVAL 200 DAY, 'ttl-1'),
    ('acct-ttl', 'cookie',      'anon-old', 'user-old', now64(3) - INTERVAL 200 DAY, 'ttl-2')"
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "OPTIMIZE TABLE analytics.identity_signals FINAL"
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT signal_kind, count() FROM analytics.identity_signals
  WHERE account_id = 'acct-ttl' GROUP BY signal_kind"
```

```text
cookie	1
```

The 200-day-old fingerprint row is gone; the equally old cookie row survives — the TTL's
`WHERE signal_kind = 'fingerprint'` scoping works. Runbook exercise: with the M2 fixtures
loaded, run the runbook's steps 1–3 and 5 for `ACCOUNT = 'acct-1'`, `USER = 'user-U'`,
wait for `system.mutations` to drain, then confirm: `identity_signals` has no `user-U`
rows; `s-a1`/`s-a2`/`s-id` read `identifiers = '{}'`; and `s-a1`'s `canonical_user` falls
back to `anon-A` (its evidence is gone — exactly what erasure means).

Stability battery: the ep5/ep6 queries and expected numbers are in Milestone 3 and
Concrete Steps step 3 (`3` stitched, `4` raw dau, empty `DESCRIBE` diff, `just test`
green before and after the retirement migration). Record all transcripts here when run.


## Idempotence and Recovery

Migrations: the EP-12 runner applies each file once (ledger
`analytics.schema_migrations`) and applied files are immutable — a botched migration is
fixed by a NEW file, never by editing. Every DDL statement in this plan's migrations uses
`IF NOT EXISTS`/`IF EXISTS`, so replaying a partially-applied file (crash between
statements) is safe: completed statements no-op. The one non-DDL statement — the M2
backfill `INSERT` — is safe to re-run because re-inserted rows are byte-identical and the
`identity_signals` ORDER BY tuple dedups them at merge (that is the same idempotence
argument `events_raw` uses for queue replays); at worst duplicates linger until a merge,
and `uniqExact`/`argMax`/`groupUniqArray` consumers are insensitive to them.

Rollback of the resolution swap (any time before the M3 retirement migration):
`identity_map`/`mv_identity_map` still exist and still fill, so recovery is a new
migration that recreates `analytics.events_resolved` from the pre-M2 definition (capture
`SHOW CREATE VIEW analytics.events_resolved` in step 0 alongside the `DESCRIBE`).
`identity_signals` can be left in place harmlessly. After M3's drop, rollback means
recreating `identity_map` + its MV from `0002_identity.sql`'s text (as amended by MP-2)
and backfilling it from `identify`/`alias` rows in `events_raw` — possible but a real
rewrite; hence the battery gate before the drop.

Fixtures: `ep18_fixtures.sql`/`ep18_conflict.sql` insert fixed `event_id`s into a
ReplacingMergeTree, so reloading them creates transient duplicates that collapse on
merge and never change any distinct-count assertion. `just ch-reset` is always available
for a pristine start. The TTL demo rows live under the throwaway account `acct-ttl`.

Mutations (runbook): `ALTER TABLE ... UPDATE/DELETE` are asynchronous and irreversible —
there is no undo; that is their purpose here (erasure). They are safe to re-issue (the
predicate matches nothing the second time). Always run step 1's SELECT and save its
output before step 5.

The two Haskell milestone commits each leave `just build`/`just test` green; if a step
fails midway, `git status` plus this plan's Progress section is enough to resume.


## Interfaces and Dependencies

No new Haskell dependencies. `containers` (`Data.Map.Strict`) is already a dependency of
`kansoku-api` and `kansoku-core`; add it to `kansoku-client.cabal` if absent. ClickHouse
features used: `ARRAY JOIN`, `JSONExtractKeysAndValues`, `argMax` over a tuple,
`groupUniqArray`, conditional `TTL ... DELETE WHERE`, and (runbook only)
`mapFromArrays`/`toJSONString` — all present in the ClickHouse shipped by this repo's nix
flake; the runbook flags its two functions for version verification.

End-state signatures that must exist:

After M1, in `kansoku-api/src/Kansoku/Event/Types.hs`:
`data IdentifierKind = Cookie | Device | Fingerprint | EmailSha256`;
`identifierKindToText :: IdentifierKind -> Text`;
`identifierKindFromText :: Text -> Maybe IdentifierKind`;
`allowedIdentifierKindNames :: [Text]`; field
`identifiers :: !(Maybe (Map Text Text))` on `AnalyticsEvent`. In
`kansoku-api/src/Kansoku/Event/Validation.hs`: `ValidationError` extended with
`UnknownIdentifierKind Text [Text]`, `EmptyIdentifierValue Text`,
`IdentifierValueTooLong Text Int Int`, `IdentifierValueBadCharset Text`;
`maxIdentifierValueLength :: Int`. In `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`:
`Column "identifiers" ChString` in `EventColumns`, `identifiers :: !ByteString` in
`EventRow`. In `kansoku-client/src/Kansoku/Client.hs`:
`identifiers :: !(Maybe (Map Text Text))` on `EventIds`.

After M2, in ClickHouse: table `analytics.identity_signals(account_id String,
signal_kind LowCardinality(String), signal_value String, user_id String, observed_at
DateTime64(3,'UTC'), event_id String)`; materialized view
`analytics.mv_identity_signals`; views `analytics.identity_bindings` (adds `confidence
Float64`), `analytics.identity_conflicts(account_id, signal_kind, signal_value,
user_ids, user_count, observation_count, last_observed_at)`,
`analytics.events_resolved_v3`, and `analytics.events_resolved` with the frozen columns
`event_id, event_name, occurred_at, url, account_id, canonical_user, properties_json`.

Contracts consumed (must hold before starting — verified in Concrete Steps step 0): MP-2
EP-12's migration ledger and post-0004 `events_raw` shape; EP-15's account stamping and
account-scoped `events_resolved`; plan 9 / EP-14's rule that `kansoku-api`,
`kansoku-client`, and the OpenAPI document change in the same commits.

Contracts provided (consumed by others): the frozen `events_resolved` output contract
(EP-19 rollups; every `Kansoku.Query` builder); the `identifiers` wire-field name claim
(EP-20 must pick a disjoint schema-version name — recorded in MasterPlan 3's
"AnalyticsEvent wire type" integration point); the `identifiers` storage representation
(String JSON aligned with today's `properties` — re-align if EP-17 changes the
properties representation first, per the Decision Log); the closed `IdentifierKind`
vocabulary (client SDKs and EP-19/EP-20 event schemas must use these strings).

---

Revision note (2026-07-19): implementation-start reconciliation updated the stale
six-column `events_resolved` assumption to EP-17's landed seven-column contract, assigned
the next free migration numbers (`0011`–`0013`), linked the active intention in
frontmatter, and recorded the successful baseline build/test evidence.

Revision note (2026-07-19, Milestones 1-2): recorded the completed wire, validation,
storage, client, OpenAPI, evidence-store, conflict, and resolution work; added live HTTP
and ClickHouse transcripts; documented the EP-17 fixture interaction; and linked ADR 0005
as the durable owner of the identity model and ranking policy.
