---
id: 2
slug: canonical-event-model-and-schema-registry
title: "Canonical event model and schema registry"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Canonical event model and schema registry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a first-party analytics service written in Haskell. It
ingests behavioral events from many different emitters — a browser, a product frontend, a
backend microservice, a background worker, an email/campaign system, or an automated agent —
and stores them in ClickHouse so that product and business metrics can be queried later. For
all of those emitters and for every part of Kansoku that touches an event, there must be one
agreed-upon shape for "an event": what fields it has, which are required, and exactly how it
looks as JSON on the wire. That shared shape is what this plan delivers.

After this plan is implemented, a developer working in this repository can:

- Import a Haskell type, `Kansoku.Event.AnalyticsEvent`, that models a single analytics event
  with all of the fields the product specification requires.
- Take a JSON document produced by any Kansoku client (the exact JSON shape defined in
  `docs/initial-spec.md`), decode it into that Haskell type, re-encode it, and get JSON back
  that is equivalent as a parsed JSON value — the same keys and values, with key order and
  whitespace immaterial (a "round trip"). This proves the Haskell type and the JSON contract
  agree.
- Reject malformed input with a clear error — for example, a `source` field that is not one of
  the six allowed values, or an event that is missing its identifier or name.
- Consult an in-process "schema registry" (an in-memory table, held in ordinary Haskell data,
  not a database) that records which named events (like `page_view` or `user_registered`)
  require which properties, and validate an event against it.

The user-visible proof is the test suite: running `cabal test` prints a passing group of
"Event" specifications, including a round-trip of a concrete sample event, rejection of a bad
`source`, and validation successes and failures. Nothing here starts a server or writes to a
database; this is a pure, in-memory, unit-tested foundation.

Why this matters to the wider project: this event type and its JSON encoding are the single
normative contract shared by five later plans. The HTTP ingestion API (plan EP-4) accepts this
JSON; the durable queue (plan EP-4) carries this JSON as each message body; the ClickHouse
storage layer (plan EP-3) maps this type to a database row; identity stitching (plan EP-5)
reads the special `identify`/`alias`/`group` events defined here; and the Haskell client SDK
(plan EP-7) constructs and serializes exactly this type. If a field name or its optionality
changed anywhere else without changing it here first, the whole system would silently drift.
This plan owns that contract.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — canonical type and JSON codec:

- [ ] Add `aeson`, `containers`, `text`, `time` to the `build-depends` of the
  `kansoku:kansoku-api` sub-library stanza in `kansoku.cabal` (created by EP-1), if not already
  present; the stanza already `import: common` and depends on `Kansoku.Prelude`.
- [ ] Add `Kansoku.Event.Types` and `Kansoku.Event` to the `kansoku:kansoku-api` sub-library
  `exposed-modules` in `kansoku.cabal`.
- [ ] Create `src/Kansoku/Event/Types.hs` (importing `Kansoku.Prelude`) with the `EventSource`
  closed sum type. Both JSON instances are hand-written: `ToJSON` as a one-liner over
  `eventSourceToText`, and `FromJSON` so an out-of-range source fails with the "unknown event
  source" message the acceptance test requires. Both wire mappings are the exact lowercase
  strings.
- [ ] Add the identifier newtypes (`EventId`, `EventName`, `AnonymousId`, `UserId`,
  `OrganizationId`, `AccountId`, `SessionId`, `CorrelationId`, `CausationId`, `SourceEventId`)
  to `Kansoku.Event.Types` with `deriving stock (Generic, Show)` +
  `deriving newtype (Eq, Ord, FromJSON, ToJSON)` over `Text` per the record-patterns standard.
- [ ] Add the `AnalyticsEvent` record to `Kansoku.Event.Types` with every field from the
  specification (strict `!` fields, entity id first, no field prefixes),
  `deriving stock (Generic, Eq, Show)`, with explicit `FromJSON`/`ToJSON` instances derived
  through the shared `analyticsEventOptions` (defined in the same module).
- [ ] Create `src/Kansoku/Event.hs` (importing and re-exporting `Kansoku.Event.Types`) with the
  identity-event smart constructors (`identifyEvent`, `aliasEvent`, `groupEvent`), and document
  the identity-event naming convention in the module haddock.
- [ ] Create the test module `test/Kansoku/EventSpec.hs` (wired into EP-1's test-suite) with
  the JSON round-trip test and the bad-`source` rejection test.
- [ ] Run `cabal build` and `cabal test`; confirm the Milestone 1 specs pass.

Milestone 2 — validation and schema registry:

- [ ] Add `Kansoku.Event.Registry` and `Kansoku.Event.Validation` to the
  `kansoku:kansoku-api` sub-library `exposed-modules`.
- [ ] Create `src/Kansoku/Event/Registry.hs` (importing `Kansoku.Prelude` and
  `Kansoku.Event.Types`) with `PropertyType`, `PropertySpec`,
  `EventSchema`, `EventRegistry`, `emptyRegistry`, `registerSchema`, `lookupSchema`, and
  `defaultRegistry` seeded with the spec event names.
- [ ] Create `src/Kansoku/Event/Validation.hs` (importing `Kansoku.Prelude`,
  `Kansoku.Event.Types`, and `Kansoku.Event.Registry`) with `ValidationError`,
  `validateEventWith`, and `validateEvent`.
- [ ] Extend `Kansoku.Event`'s export list to re-export `Kansoku.Event.Registry` and
  `Kansoku.Event.Validation` alongside `Kansoku.Event.Types`.
- [ ] Extend `test/Kansoku/EventSpec.hs` with registry-lookup, validation-success, and
  validation-failure specs.
- [ ] Run `cabal test`; confirm all Event specs pass and record the transcript in Concrete
  Steps.
- [ ] Run `fourmolu` on the new modules and commit with the required trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Model identifier fields (`eventId`, `userId`, `anonymousId`, etc.) as thin
  `newtype`s over `Text` (for example `newtype EventId = EventId Text`) with JSON instances
  derived directly from the underlying `Text`, rather than using a structured identifier
  library such as `mmzk-typeid` (the TypeID/KindID implementation at
  `mori://MMZK1526/mmzk-typeid`).
  Rationale: These identifiers arrive from many external, uncontrolled emitters — browsers,
  arbitrary backend services, email systems, third-party campaign tools. The wire contract must
  accept whatever string those emitters send (a UUID, a TypeID, an opaque token, a legacy
  numeric string). Imposing a TypeID format at the type boundary would reject valid inbound
  events and break the "decode any conforming JSON" guarantee. Newtypes give us compile-time
  protection against mixing up, say, a `UserId` and an `AccountId` in Kansoku's own code, at
  zero runtime cost and with no format constraint on the wire. If a future plan needs to mint
  Kansoku-internal identifiers with a structured format, it can adopt TypeID locally without
  changing this contract.
  Date: 2026-07-01

- Decision: Represent the open-ended `properties` and `context` fields as
  `Data.Aeson.Object` (aeson's `Object`, which is a `Data.Aeson.KeyMap.KeyMap Value`) rather
  than as `Data.Map.Map Text Data.Aeson.Value`.
  Rationale: A JSON object decodes natively into `Object` with no conversion step, and
  re-encodes back to the same JSON, which is exactly what the round-trip guarantee requires.
  `Object` is the type aeson already uses internally, so it composes directly with the rest of
  the codec and, later, with the ClickHouse JSON-column mapping in EP-3. A `Map Text Value`
  would force an extra conversion on every decode and encode and buys nothing, since callers
  that want key/value access can use aeson's `KeyMap` API. Both fields are required (not
  `Maybe`); an emitter that has no properties sends `{}`, which decodes to an empty `Object`.
  Date: 2026-07-01

- Decision: Derive `AnalyticsEvent`'s `FromJSON`/`ToJSON` from `Generic` through a single
  shared `Data.Aeson.Options` value (named `analyticsEventOptions`), rather than hand-writing
  the two instances field by field.
  Rationale: The record has twenty-four fields whose JSON keys are already exactly the
  camelCase Haskell record-field names, so leaving `fieldLabelModifier` at its default (`id`)
  makes the mapping exact with no per-field code, and hand-writing twenty-four `.:`/`.:?` lines
  is error-prone and easy to let drift from the record. Setting `omitNothingFields = True`
  makes optional (`Maybe`) fields serialize to *absent keys* rather than `null`, matching the
  TypeScript `?` optional semantics in the spec. `rejectUnknownFields = False` (aeson's default)
  keeps decoding tolerant of extra keys a newer client might add (forward compatibility).
  Alignment with the haskell-jitsurei/core standards: those standards prefer
  `deriving anyclass (FromJSON, ToJSON)` for records, which is exactly the generic path — but
  `deriving anyclass` uses aeson's *default* options, and this record needs the non-default
  `omitNothingFields = True`. The record-patterns guide's "Custom Options for Optional Fields"
  section covers precisely this case and prescribes explicit instances that call
  `genericParseJSON`/`genericToJSON` with a named `Options` value (mirroring the standards'
  shared `eventAesonOptions` prelude pattern). So `AnalyticsEvent` uses two one-line explicit
  instances over `analyticsEventOptions` (defined locally in `Kansoku.Event.Types` next to the
  record, built from the `Options`, `defaultOptions`, `genericParseJSON`, and `genericToJSON`
  that `Kansoku.Prelude` re-exports from aeson; promoted into `Kansoku.Prelude` only if a later
  plan needs the same options for another record) — still generic, no per-field code, just with
  the omit-nothing option the wire contract demands.
  The one place that genuinely still needs a *hand-written* instance is the closed `EventSource`
  enum: the acceptance test requires the decode of an out-of-range source to fail with an error
  message containing `unknown event source`, which generic deriving cannot produce (it emits a
  generic tag-mismatch error). See the `EventSource` decision below for the details.
  Date: 2026-07-01

- Decision: Parse and render the two timestamp fields (`occurredAt`, `receivedAt`) as
  `Data.Time.Clock.UTCTime`, relying on aeson's built-in `UTCTime` instances which read and
  write ISO-8601 / RFC 3339 strings.
  Rationale: The spec types these as ISO-8601 strings; `UTCTime` is the natural Haskell
  representation and aeson already parses ISO-8601 into it and renders it back as an ISO-8601
  string (with a trailing `Z` for UTC). This gives us timestamp *values* we can compare during
  validation (for example, "occurred at or before received at") instead of opaque strings.
  Date: 2026-07-01

- Decision: Type `sourceGlobalPosition` as `Maybe Int64` even though the spec writes its type
  as `number` (TypeScript has no dedicated integer type, so `number` is the loosest it can say).
  Rationale: A global position is a global sequence number assigned by an upstream event store —
  always an integer, never fractional. `Int64` matches the position type message-db uses (a
  Postgres `bigint`), so a position carried through Kansoku survives without loss and can be
  compared back against the origin store. aeson decodes a JSON number into `Int64` directly and
  rejects fractional values, which in this field could only ever indicate an emitter bug.
  Date: 2026-07-01

- Decision: Model `source` as a closed sum type
  `data EventSource = Web | App | Service | Worker | Email | Agent` mapping to the exact
  lowercase strings `"web"`, `"app"`, `"service"`, `"worker"`, `"email"`, `"agent"`, and reject
  any other string on decode.
  Rationale: The spec enumerates exactly these six sources. A closed sum type makes exhaustive
  handling of sources a compile-time guarantee for every downstream consumer.
  Why this is the documented exception to the standards' "prefer generic deriving" rule: the
  acceptance test in Validation and Acceptance requires that a bad source (e.g. `"telepathy"`)
  fail with a message containing `unknown event source` and the list of the six legal values,
  which aeson's generic sum decoder cannot emit (it reports a generic "expected one of …" tag
  error). So `FromJSON EventSource` must be hand-written. We keep `ToJSON` hand-written too, as a
  one-liner (`String . eventSourceToText`) that defers to the exported `eventSourceToText`
  helper — that helper is the single source of truth for an `EventSource`'s wire form and is
  itself consumed by EP-3's ClickHouse row mapping, so routing `ToJSON` through it keeps the two
  from ever diverging (a generic encoder via `constructorTagModifier = camelTo2 '_'` would
  produce the identical strings but introduce a second, separately-maintained rendering path).
  `EventSource` still `deriving stock (Generic, ...)` so it stays consistent with the other types
  and can opt into generic tooling later. This is the single deviation from generic deriving in
  the module, and it is confined to one small closed enum.
  Date: 2026-07-01

- Decision: Treat the identity events `identify`, `alias`, and `group` as ordinary
  `AnalyticsEvent` values whose `eventName` is the corresponding string, and provide optional
  smart constructors (`identifyEvent`, `aliasEvent`, `groupEvent`) that fill in that
  `eventName`. Do not introduce a separate identity-event type.
  Rationale: The spec (section "Identity Stitching") lists these as event names, and keeping
  them as normal events means they flow through the same ingestion, queue, storage, and query
  paths as everything else — EP-5 (identity stitching) simply filters on these names. A separate
  type would fork the pipeline for no benefit. The smart constructors document the convention in
  code and reduce the chance of a typo in the magic string.
  Date: 2026-07-01

- Decision: Place the code in four modules — `Kansoku.Event.Types` (the `AnalyticsEvent`
  record, the ten identifier newtypes, `EventSource`, `analyticsEventOptions`, and all of their
  JSON instances), `Kansoku.Event.Registry` (the schema registry), `Kansoku.Event.Validation`
  (validation), and `Kansoku.Event` (the identity-event smart constructors plus a re-export of
  the other three) — so a single `import Kansoku.Event` gives a consumer everything.
  Rationale: An earlier draft defined the core types directly in `Kansoku.Event` and had that
  module re-export `Kansoku.Event.Registry` and `Kansoku.Event.Validation`. That is an import
  cycle GHC rejects: re-exporting a module requires importing it, so `Kansoku.Event` would
  import Registry and Validation, while Registry needs `EventName` and Validation needs
  `AnalyticsEvent` and `EventName` — types that lived in `Kansoku.Event` itself. Moving the
  shared types down into the leaf module `Kansoku.Event.Types` breaks the cycle: Registry and
  Validation import Types, and `Kansoku.Event` sits at the top of the module graph importing
  all three. The concerns remain separable, registry/validation grow independently of the core
  type, and consumers never need to know about the internal split — `import Kansoku.Event`
  remains the single public entry point and the normative contract.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository before. Read it in full before making
any change.

Kansoku is a greenfield Haskell service. It uses GHC 9.12.4, a Nix flake for reproducible
builds, and the `effectful` effect system for its runtime. "Effect system" here just means the
library that structures side effects; nothing in *this* plan uses effects, because everything
here is pure data and pure functions — but you will see `effectful` referenced in EP-1's code.

This plan (EP-2) has one hard dependency: **EP-1**, the plan documented at
`docs/plans/1-project-skeleton-and-application-runtime.md`. EP-1 must be complete and green
before you begin. Concretely, EP-1 creates:

- `kansoku.cabal` — the build description file for the package named `kansoku`. A `.cabal` file
  has "stanzas": a `library` stanza (with `exposed-modules:` listing the modules the package
  offers and `build-depends:` listing the libraries it uses), an executable stanza
  (`kansoku-server`), and a `test-suite` stanza. This plan edits the `library` stanza (to add
  modules and dependencies) and adds a test module to whatever the `test-suite` stanza points
  at.
- `cabal.project` — the file that tells the `cabal` build tool which packages are in the build.
- The `Kansoku.*` module namespace, living under `src/Kansoku/`. For example EP-1 creates
  `src/Kansoku/Config.hs` exposing module `Kansoku.Config`. New modules in this plan follow the
  same pattern: module `Kansoku.Event` lives at `src/Kansoku/Event.hs`, module
  `Kansoku.Event.Types` at `src/Kansoku/Event/Types.hs`, module `Kansoku.Event.Registry` at
  `src/Kansoku/Event/Registry.hs`, and so on.
- A test-suite. Its exact test framework (for example `hspec` or `tasty`) is chosen by EP-1.
  This plan's example test code is written in `hspec` style (the most common choice for this
  kind of unit test). When you implement, open EP-1's test files first and match whatever
  framework and directory layout EP-1 actually established; if EP-1 chose `tasty`, translate the
  `describe`/`it`/`shouldBe` calls shown here into the equivalent `testGroup`/`testCase`/`@?=`
  calls. The *assertions* (what is being checked) do not change, only the surface syntax.

If EP-1 is not yet complete when you start, stop and complete EP-1 first; there is no buildable
package to add modules to otherwise.

Development commands, all run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`:

```bash
nix develop          # enter the dev shell with GHC 9.12.4, cabal, and fourmolu on PATH
cabal build          # compile the library, executable, and test-suite
cabal test           # build and run the test-suite, printing results
fourmolu -i src test # format the Haskell source in place (the project's formatter)
```

The authoritative product specification lives at `docs/initial-spec.md`. The section
"Canonical Event Model" gives the TypeScript type this plan translates to Haskell; "Identity
Stitching" defines the `identify`/`alias`/`group` events; "Event Sources" enumerates the six
sources; and "Initial Product Metrics" lists product event names some of which seed the schema
registry. The parent MasterPlan is `docs/masterplans/1-kansoku-analytics-service-mvp.md`; its
"Integration Points" section names "The `AnalyticsEvent` type and its JSON contract" as the
artifact this plan owns and five other plans consume.

Coding standards. All Haskell in this repository follows the shared standards documents under
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` — `standards.md` (GHC2024 language
edition; a `common` cabal stanza enabling `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`, and `MultilineStrings`; postpositive `qualified`
imports such as `import Data.Map.Strict qualified as Map`), `custom-prelude.md`,
`record-patterns.md`, and `multiline-strings.md`. Two consequences shape every code sketch
below. First, every module imports EP-1's shared prelude with `import Kansoku.Prelude`; that
prelude re-exports `Text`, `Generic`, aeson's `FromJSON`/`ToJSON`/`genericParseJSON`/
`genericToJSON`/`Options`/`SumEncoding(..)`/`defaultOptions`, aeson's `camelTo2` (which lives
in `Data.Aeson.Types`, not in a separate casing package),
`UTCTime`, `NonEmpty`, and a blanket `Control.Lens`, so the sketches do not re-import those.
Any module that reads fields with generic-lens `#label` syntax additionally writes
`import Data.Generics.Labels ()` (the prelude deliberately omits that orphan instance). Second,
records use strict `!` fields with no field-name prefixes, put the entity id first, and use
explicit deriving strategies: `deriving stock (Generic, Eq, Show)` for records with
`deriving anyclass (FromJSON, ToJSON)` (or explicit generic instances when non-default `Options`
are needed), and `deriving stock (Generic, Show)` + `deriving newtype (...)` for newtypes. These
modules live in EP-1's `kansoku:kansoku-api` sub-library (see Interfaces and Dependencies).

Terms defined for this plan:

- **Canonical event model**: the one Haskell type, `AnalyticsEvent`, that represents any
  analytics event regardless of which emitter produced it. "Canonical" means every other part of
  the system agrees to use this one shape.
- **JSON codec**: the pair of instances that convert the Haskell type to JSON (`ToJSON`,
  "encode") and back (`FromJSON`, "decode"). We use the `aeson` library, the standard Haskell
  JSON library.
- **Round trip**: decode a JSON document into the Haskell value, then encode that value back to
  JSON, and check the result equals the original JSON (compared as parsed JSON values, so key
  order and whitespace do not matter). A successful round trip proves the type and the wire
  contract agree.
- **Schema registry**: an ordinary in-memory Haskell value (a map from event name to a small
  schema description) that records, for known event names, which properties are expected and
  whether they are required. It is not a database and not a network service; it is plain data
  constructed in Haskell and passed to the validator.
- **Validation**: a pure function that inspects an `AnalyticsEvent` and returns either the event
  unchanged (valid) or a list of `ValidationError` values describing what is wrong.

The `aeson` API you will use (standard, stable across recent versions): the `FromJSON` class
with method `parseJSON`, the `ToJSON` class with method `toJSON`; the combinators `withText`
(parse a JSON string), `withObject` (parse a JSON object), `.:` (required field lookup), `.:?`
(optional field lookup), `object` (build a JSON object), `(.=)` (build a key/value pair);
`Data.Aeson.Value` (the JSON value type, with constructors `String`, `Number`, `Bool`,
`Object`, `Array`, `Null`); `Data.Aeson.Object` (a type alias for `Data.Aeson.KeyMap.KeyMap
Value`); `Data.Aeson.decode`/`eitherDecode`/`encode` over lazy `ByteString`; and the
`Data.Aeson.Options` record with fields `fieldLabelModifier`, `omitNothingFields`, and
`rejectUnknownFields`, used with `genericParseJSON`/`genericToJSON` and `deriving Generic`.
aeson already provides `FromJSON`/`ToJSON` for `UTCTime` (ISO-8601 strings), for `Int64`, for
`Text`, and for `Maybe a` (where `Nothing` maps to an absent field under `omitNothingFields`).


## Plan of Work

The work divides into two independently verifiable milestones. Milestone 1 delivers the type
and its JSON codec with a passing round-trip test — this alone is the normative contract other
plans need. Milestone 2 adds validation and the schema registry on top.

### Milestone 1 — the canonical `AnalyticsEvent` type and its JSON codec

Scope: define the event type and make it encode/decode to exactly the JSON in the spec, proven
by a round-trip test and a bad-`source` rejection test. At the end of this milestone,
`src/Kansoku/Event/Types.hs` and `src/Kansoku/Event.hs` exist and `cabal test` shows the
Milestone 1 specs passing.

First, edit `kansoku.cabal`. In the `kansoku:kansoku-api` sub-library stanza (the shared
internal library EP-1 carves out to hold the event model and, later, the servant API types),
add `Kansoku.Event.Types` and `Kansoku.Event` to `exposed-modules`, and ensure `build-depends`
includes `aeson`, `containers`, `text`, and `time` (some may already be present from EP-1; do
not duplicate — `Kansoku.Prelude` already pulls in `aeson`, `text`, and `time`, so
in practice only `containers` is likely new). The stanza already carries `import: common`, so
the GHC2024 edition and the shared extensions (`DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`) are on without per-file pragmas.
`containers` is needed in Milestone 2 for the registry's `Data.Map.Strict`; adding it now is
harmless.

Then create `src/Kansoku/Event/Types.hs`. Begin with the module header and
`import Kansoku.Prelude` (no per-file language pragmas — the `common` stanza supplies them).
This module holds the `EventSource` sum type, the ten identifier newtypes, the
`AnalyticsEvent` record, `analyticsEventOptions`, and all of their JSON instances, and it
exports all of them. It exists as a separate leaf module for one reason: `Kansoku.Event`
re-exports `Kansoku.Event.Registry` and `Kansoku.Event.Validation` (created in Milestone 2),
and re-exporting a module requires importing it — but Registry uses `EventName` and Validation
uses `AnalyticsEvent` and `EventName`. If those types were defined in `Kansoku.Event` itself,
Registry and Validation would have to import `Kansoku.Event` while `Kansoku.Event` imports
them back — an import cycle GHC rejects. Placing the shared types at the bottom of the module
graph in `Kansoku.Event.Types` breaks the cycle: Registry and Validation import Types, and
`Kansoku.Event` imports all three and re-exports everything, so `import Kansoku.Event` remains
the single public entry point and consumers never see the split.

`Kansoku.Event` itself (file `src/Kansoku/Event.hs`) is created at the end of this milestone:
it imports `Kansoku.Event.Types`, defines the identity-event smart constructors, and re-exports
all of `Kansoku.Event.Types`; the `Kansoku.Event.Registry` and `Kansoku.Event.Validation`
re-exports are added in Milestone 2 when those modules exist.

The `EventSource` type is a closed sum type and is the one documented exception to the
standards' "prefer generic deriving" rule: both its JSON instances are hand-written. `Text` and
`FromJSON`/`ToJSON` come from `Kansoku.Prelude`; `withText` and the `String` constructor are the
only extra aeson imports:

```haskell
import Kansoku.Prelude

import Data.Aeson (withText)
import Data.Aeson.Types (Value (String))

-- | The origin category of an event. Exactly the six values the spec allows.
data EventSource = Web | App | Service | Worker | Email | Agent
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | Render to the exact lowercase wire strings. This is the single source of truth
-- for an 'EventSource'\'s wire form; EP-3's ClickHouse row mapping reuses it.
eventSourceToText :: EventSource -> Text
eventSourceToText s = case s of
  Web -> "web"; App -> "app"; Service -> "service"
  Worker -> "worker"; Email -> "email"; Agent -> "agent"

-- ToJSON is trivial and defers to eventSourceToText so the two never diverge.
instance ToJSON EventSource where
  toJSON = String . eventSourceToText

-- FromJSON is hand-written because the acceptance test requires this precise error
-- wording, which the generic sum decoder cannot produce.
instance FromJSON EventSource where
  parseJSON = withText "EventSource" $ \t -> case t of
    "web" -> pure Web
    "app" -> pure App
    "service" -> pure Service
    "worker" -> pure Worker
    "email" -> pure Email
    "agent" -> pure Agent
    other -> fail ("unknown event source: " <> show other
                    <> " (expected one of web, app, service, worker, email, agent)")
```

Deriving `stock (Generic, ...)` on `EventSource` keeps it consistent with the other types and
lets a later plan opt into generic tooling; the JSON instances remain manual as justified above.

The identifier newtypes are thin wrappers over `Text` whose JSON is just the underlying text.
Per the record-patterns standard, use `deriving stock (Generic, Show)` for the standard classes
and `deriving newtype (...)` so the `Eq`, `Ord`, and JSON instances come straight from `Text`
(GHC2024 already enables both `DerivingStrategies` and `GeneralizedNewtypeDeriving`, so no
extra pragma is needed):

```haskell
newtype EventId = EventId Text
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype EventName = EventName Text
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

-- ...and identically for AnonymousId, UserId, OrganizationId, AccountId,
-- SessionId, CorrelationId, CausationId, SourceEventId.
```

Provide an accessor for each (for example `unEventId :: EventId -> Text`) so validation and the
registry can read the underlying text. `EventName` needs `Ord` because it is a `Data.Map` key
in the registry.

The `AnalyticsEvent` record lists every field from the spec in order, with the entity id
(`eventId`) first per the record-patterns standard, strict `!` fields, no field prefixes,
required fields as their type and optional fields as `Maybe`:

```haskell
import Kansoku.Prelude

import Data.Aeson (Object)         -- KeyMap Value
import Data.Int (Int64)

data AnalyticsEvent = AnalyticsEvent
  { eventId :: !EventId
  , eventName :: !EventName
  , source :: !EventSource
  , sourceService :: !(Maybe Text)
  , occurredAt :: !UTCTime
  , receivedAt :: !UTCTime
  , anonymousId :: !(Maybe AnonymousId)
  , userId :: !(Maybe UserId)
  , organizationId :: !(Maybe OrganizationId)
  , accountId :: !(Maybe AccountId)
  , sessionId :: !(Maybe SessionId)
  , url :: !(Maybe Text)
  , referrer :: !(Maybe Text)
  , utmSource :: !(Maybe Text)
  , utmMedium :: !(Maybe Text)
  , utmCampaign :: !(Maybe Text)
  , utmContent :: !(Maybe Text)
  , utmTerm :: !(Maybe Text)
  , correlationId :: !(Maybe CorrelationId)
  , causationId :: !(Maybe CausationId)
  , sourceEventId :: !(Maybe SourceEventId)
  , sourceGlobalPosition :: !(Maybe Int64)
  , properties :: !Object
  , context :: !Object
  }
  deriving stock (Generic, Eq, Show)
```

The record-field names are already exactly the camelCase JSON keys, so the default
`fieldLabelModifier` (`id`) is correct and only `omitNothingFields` needs changing from the
aeson default. The standards prefer `deriving anyclass (FromJSON, ToJSON)` for records, but
`deriving anyclass` would use aeson's *default* options and therefore emit `null` for absent
optional fields; the wire contract needs those keys omitted. So, following the record-patterns
"Custom Options for Optional Fields" pattern, define the shared `analyticsEventOptions` and
write two one-line explicit instances over it (`Options`, `defaultOptions`, `genericParseJSON`,
and `genericToJSON` all come from `Kansoku.Prelude`; the `Options { .. }` update needs the
record's field selectors from `Data.Aeson.Types`):

```haskell
import Kansoku.Prelude

import Data.Aeson.Types (Options (..))

analyticsEventOptions :: Options
analyticsEventOptions =
  defaultOptions
    { omitNothingFields = True      -- optional (?) fields become absent, not null
    , rejectUnknownFields = False   -- tolerate extra keys from newer clients (aeson default)
    }
    -- fieldLabelModifier left at its default 'id': record fields already match the wire keys.

instance ToJSON AnalyticsEvent where
  toJSON = genericToJSON analyticsEventOptions

instance FromJSON AnalyticsEvent where
  parseJSON = genericParseJSON analyticsEventOptions
```

`analyticsEventOptions` is a small project-wide serialization option value; if a later plan
needs the same omit-nothing camelCase options for another API record, promote it into
`Kansoku.Prelude` alongside the standards' `eventAesonOptions` example rather than duplicating
it.

Finally create `src/Kansoku/Event.hs`, which re-exports everything from `Kansoku.Event.Types`
and adds the identity-event smart constructors, documenting the convention. An identity
event is an ordinary `AnalyticsEvent` whose `eventName` is `"identify"`, `"alias"`, or
`"group"`; EP-5 recognizes events by these names. Provide constructors that take the fields an
emitter typically supplies and set the name:

```haskell
import Kansoku.Prelude

import Data.Generics.Labels ()   -- enables #label setters below
import Kansoku.Event.Types

-- | Build an @identify@ event: associates an anonymous visitor with a known user.
identifyEvent
  :: EventId -> EventSource -> UTCTime -> UTCTime
  -> Maybe AnonymousId -> Maybe UserId -> Object -> AnalyticsEvent
identifyEvent eid src occ recv anon usr traits =
  baseEvent eid (EventName "identify") src occ recv
    & #anonymousId .~ anon
    & #userId .~ usr
    & #properties .~ traits

-- aliasEvent and groupEvent follow the same shape with EventName "alias" / "group".
```

where `baseEvent` is a small helper that constructs an `AnalyticsEvent` with all optional
fields `Nothing` and both open maps empty (`mempty :: Object`). The updates use generic-lens
`#label` setters (`&`/`.~`) rather than record-update syntax, per the record-patterns standard;
the `import Data.Generics.Labels ()` line brings the `#label` orphan instance into this module
(the prelude deliberately omits it). Keep `baseEvent` unexported or exported as convenience;
document in the module haddock that these three names are reserved for identity stitching.

Then create the test module (see Concrete Steps for the exact sample) and run `cabal test`.

### Milestone 2 — validation and the schema registry

Scope: add a schema registry and a validator that consults it, with unit tests. At the end,
`src/Kansoku/Event/Registry.hs` and `src/Kansoku/Event/Validation.hs` exist, are re-exported
from `Kansoku.Event`, and the full Event spec group passes.

Add `Kansoku.Event.Registry` and `Kansoku.Event.Validation` to the `kansoku:kansoku-api`
sub-library `exposed-modules` in `kansoku.cabal`.

Create `src/Kansoku/Event/Registry.hs`, importing `Kansoku.Prelude`, `Kansoku.Event.Types`
(for `EventName`) and, postpositively, `import Data.Map.Strict qualified as Map` (containers).
Importing `Kansoku.Event.Types` — not `Kansoku.Event` — is what keeps the module graph
acyclic, as explained in Milestone 1. A schema describes, per event name,
which properties are expected and whether each is required; property types are described loosely
(we check presence strictly and type loosely, because analytics properties are intentionally
open). Records use strict `!` fields and explicit deriving strategies per the record-patterns
standard:

```haskell
import Kansoku.Prelude

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kansoku.Event.Types (EventName)

-- | A loose description of an expected property's JSON type.
data PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny
  deriving stock (Generic, Eq, Show)

data PropertySpec = PropertySpec
  { propName :: !Text
  , propType :: !PropertyType
  , propRequired :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data EventSchema = EventSchema
  { schemaEventName :: !EventName
  , schemaProperties :: ![PropertySpec]
  }
  deriving stock (Generic, Eq, Show)

newtype EventRegistry = EventRegistry (Map EventName EventSchema)
  deriving stock (Generic)

emptyRegistry :: EventRegistry
emptyRegistry = EventRegistry Map.empty

registerSchema :: EventSchema -> EventRegistry -> EventRegistry
registerSchema s (EventRegistry m) = EventRegistry (Map.insert (schemaEventName s) s m)

lookupSchema :: EventName -> EventRegistry -> Maybe EventSchema
lookupSchema n (EventRegistry m) = Map.lookup n m
```

Seed a `defaultRegistry` with a handful of event names drawn from the spec (`page_view` and
`session_start` from web analytics, `identify` from identity stitching, and `user_registered`
and `subscription_started` from the product-metrics/backend-events lists). Make each schema
reflect a plausible required property so the validator has something to check — for example
`page_view` requires a string `url` property, `user_registered` requires a string `userId`
property. Keep the registry extensible: `defaultRegistry` is just repeated `registerSchema`
calls over `emptyRegistry`, and any consumer can build its own.

```haskell
defaultRegistry :: EventRegistry
defaultRegistry =
  foldr registerSchema emptyRegistry
    [ EventSchema (EventName "page_view")
        [ PropertySpec "url" PTString True ]
    , EventSchema (EventName "session_start")
        [ PropertySpec "sessionId" PTString True ]
    , EventSchema (EventName "identify")
        []                                    -- traits are open; nothing required
    , EventSchema (EventName "user_registered")
        [ PropertySpec "userId" PTString True ]
    , EventSchema (EventName "subscription_started")
        [ PropertySpec "plan" PTString True
        , PropertySpec "amount" PTNumber False ]
    ]
```

Create `src/Kansoku/Event/Validation.hs`, importing `Kansoku.Prelude`, `Kansoku.Event.Types`
(for `AnalyticsEvent` and `EventName`), `Kansoku.Event.Registry` (for the registry types and
`defaultRegistry`) and, postpositively, `import Data.Aeson.KeyMap qualified as KeyMap` for the
`properties`-object presence checks.
Define the error type and two entry points: one that takes an explicit registry (so tests can
inject a custom one) and one that uses `defaultRegistry`:

```haskell
import Kansoku.Prelude

import Data.Aeson.KeyMap qualified as KeyMap
import Kansoku.Event.Registry
import Kansoku.Event.Types

data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime   -- receivedAt earlier than occurredAt
  | MissingRequiredProperty EventName Text   -- event name, missing property key
  | WrongPropertyType EventName Text PropertyType  -- event name, key, expected type
  deriving stock (Generic, Eq, Show)

-- | Validate against an explicit registry. Returns the event unchanged if valid,
--   or the full list of problems if not.
validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent

-- | Validate against 'defaultRegistry'.
validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEvent = validateEventWith defaultRegistry
```

`validateEventWith` accumulates *all* errors (rather than stopping at the first) so a caller
sees every problem at once. The checks are: `eventId` text is non-empty (else `EmptyEventId`);
`eventName` text is non-empty (else `EmptyEventName`); `receivedAt >= occurredAt` (else
`ReceivedBeforeOccurred`); and, if the event's name is found in the registry, for each required
`PropertySpec` the property key must be present in the event's `properties` object (else
`MissingRequiredProperty`) and, when present, its JSON value should match the declared
`PropertyType` unless the type is `PTAny` (else `WrongPropertyType`; a type mismatch is
reported but presence is the primary check). Presence is checked with aeson's
`Data.Aeson.KeyMap.lookup` against the `properties` `Object`. If the event name is not in the
registry, only the structural checks apply — unknown event names are allowed (the registry is a
known-events allowlist for extra validation, not a gate on all events). Return `Right event`
when the accumulated error list is empty, otherwise `Left errs`.

Extend `Kansoku.Event`'s export list so it re-exports both new modules (it now imports and
re-exports `Kansoku.Event.Types`, `Kansoku.Event.Registry`, and `Kansoku.Event.Validation`),
extend the test module with registry and
validation specs (see Concrete Steps), run `cabal test`, format with `fourmolu`, and commit.


## Concrete Steps

Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside the Nix dev shell.

Enter the dev shell:

```bash
nix develop
```

The concrete sample event used by the round-trip test. Save this JSON as a string literal in
the test module (or as a fixture file `test/fixtures/sample-event.json` and read it — either is
fine). It exercises required fields, several optional fields, both timestamp fields, the
`source` enum, and non-empty `properties` and `context`:

```json
{
  "eventId": "evt_01HZX8N2Qb",
  "eventName": "page_view",
  "source": "web",
  "sourceService": "marketing-site",
  "occurredAt": "2026-07-01T12:00:00Z",
  "receivedAt": "2026-07-01T12:00:01Z",
  "anonymousId": "anon_abc123",
  "userId": "user_42",
  "organizationId": "org_7",
  "accountId": "acct_9",
  "sessionId": "sess_xyz",
  "url": "https://example.com/pricing",
  "referrer": "https://google.com/",
  "utmSource": "google",
  "utmMedium": "cpc",
  "utmCampaign": "launch",
  "utmContent": "hero",
  "utmTerm": "analytics",
  "correlationId": "corr_1",
  "causationId": "cause_1",
  "sourceEventId": "src_evt_1",
  "sourceGlobalPosition": 12345,
  "properties": { "url": "https://example.com/pricing", "title": "Pricing" },
  "context": { "userAgent": "Mozilla/5.0", "ip": "203.0.113.7" }
}
```

The expected decoded Haskell value (what `eitherDecode` of the JSON above must produce):

```haskell
expectedSample :: AnalyticsEvent
expectedSample = AnalyticsEvent
  { eventId = EventId "evt_01HZX8N2Qb"
  , eventName = EventName "page_view"
  , source = Web
  , sourceService = Just "marketing-site"
  , occurredAt = read "2026-07-01 12:00:00 UTC"   -- UTCTime
  , receivedAt = read "2026-07-01 12:00:01 UTC"
  , anonymousId = Just (AnonymousId "anon_abc123")
  , userId = Just (UserId "user_42")
  , organizationId = Just (OrganizationId "org_7")
  , accountId = Just (AccountId "acct_9")
  , sessionId = Just (SessionId "sess_xyz")
  , url = Just "https://example.com/pricing"
  , referrer = Just "https://google.com/"
  , utmSource = Just "google"
  , utmMedium = Just "cpc"
  , utmCampaign = Just "launch"
  , utmContent = Just "hero"
  , utmTerm = Just "analytics"
  , correlationId = Just (CorrelationId "corr_1")
  , causationId = Just (CausationId "cause_1")
  , sourceEventId = Just (SourceEventId "src_evt_1")
  , sourceGlobalPosition = Just 12345
  , properties = -- KeyMap with keys "url" and "title"
      KeyMap.fromList [ ("url", String "https://example.com/pricing")
                      , ("title", String "Pricing") ]
  , context =
      KeyMap.fromList [ ("userAgent", String "Mozilla/5.0")
                      , ("ip", String "203.0.113.7") ]
  }
```

The test module. Adapt the framework to whatever EP-1 wired; this shows `hspec`. It lives at
`test/Kansoku/EventSpec.hs` and is referenced from the test-suite's `other-modules` (or
discovered automatically if EP-1 uses `hspec-discover`).

```haskell
module Kansoku.EventSpec (spec) where

-- The test-suite stanza also `import: common`, so GHC2024 and OverloadedStrings
-- are on without a per-file pragma. Qualified imports are postpositive per the standard.
-- The prelude's Control.Lens re-export supplies (&) and (.~); Data.Generics.Labels
-- brings the #label orphan instance into scope for the setters used below.
import Kansoku.Prelude

import Data.Aeson (Value, decode, eitherDecode, encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Kansoku.Event   -- re-exports Kansoku.Event.Types, .Registry, and .Validation
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Event" $ do

  describe "AnalyticsEvent JSON codec" $ do
    it "round-trips the sample event (decode then encode equals original JSON)" $ do
      let raw = sampleJson                    -- the JSON bytestring above
      case eitherDecode raw of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right ev -> do
          ev `shouldBe` expectedSample
          -- compare as parsed JSON so key order/whitespace do not matter
          decode (encode ev) `shouldBe` (decode raw :: Maybe Value)

    it "rejects an unknown source value" $ do
      let bad = "{\"source\":\"telepathy\", ...minimal valid rest... }"
      (eitherDecode bad :: Either String AnalyticsEvent)
        `shouldSatisfy` isLeftContaining "unknown event source"

  describe "schema registry" $ do
    it "finds a seeded schema" $
      lookupSchema (EventName "page_view") defaultRegistry `shouldSatisfy` isJust
    it "returns Nothing for an unregistered name" $
      lookupSchema (EventName "no_such_event") defaultRegistry `shouldBe` Nothing

  describe "validation" $ do
    it "accepts a well-formed registered event" $
      validateEvent expectedSample `shouldBe` Right expectedSample
    it "rejects an empty eventId" $
      validateEvent (expectedSample & #eventId .~ EventId "")
        `shouldSatisfy` hasError EmptyEventId
    it "rejects receivedAt before occurredAt" $
      validateEvent (swapTimes expectedSample)
        `shouldSatisfy` isLeft
    it "flags a missing required property for a registered event" $
      validateEvent (expectedSample & #properties .~ KeyMap.empty)
        `shouldSatisfy` hasError (MissingRequiredProperty (EventName "page_view") "url")
```

(`isLeftContaining`, `hasError`, `swapTimes`, `sampleJson`, and `isJust`/`isLeft` are small
local helpers to define in the test module.)

Build and test:

```bash
cabal build
cabal test
```

Expected `cabal test` transcript (abridged; exact wording depends on EP-1's framework):

```text
Kansoku.Event
  AnalyticsEvent JSON codec
    round-trips the sample event (decode then encode equals original JSON) [OK]
    rejects an unknown source value [OK]
  schema registry
    finds a seeded schema [OK]
    returns Nothing for an unregistered name [OK]
  validation
    accepts a well-formed registered event [OK]
    rejects an empty eventId [OK]
    rejects receivedAt before occurredAt [OK]
    flags a missing required property for a registered event [OK]

Finished in 0.01 seconds
8 examples, 0 failures
```

Format and commit:

```bash
fourmolu -i src test
git add kansoku.cabal src/Kansoku/Event.hs src/Kansoku/Event/Types.hs \
        src/Kansoku/Event/Registry.hs src/Kansoku/Event/Validation.hs \
        test/Kansoku/EventSpec.hs
git commit
```

Every commit on this plan must carry these three trailers (Conventional Commits subject; no
feature branch — commit on the current branch). Example commit message:

```text
feat(event): add canonical AnalyticsEvent model and JSON codec

Define Kansoku.Event with the AnalyticsEvent record, EventSource enum,
identifier newtypes, and aeson Generic codecs matching docs/initial-spec.md.

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/2-canonical-event-model-and-schema-registry.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```


## Validation and Acceptance

Acceptance is behavioral and observed through `cabal test`, run from the repository root inside
`nix develop`.

Milestone 1 is accepted when `cabal test` shows the "AnalyticsEvent JSON codec" specs passing:
specifically, decoding the concrete sample JSON in Concrete Steps yields exactly
`expectedSample` (equality of the full record), and re-encoding that value and re-parsing it
yields the same JSON value as parsing the original input (the round trip). It is further
accepted that decoding a document whose `source` is any string other than the six allowed
values fails with an error message containing `unknown event source`. This proves the Haskell
type and the wire contract agree and that out-of-range sources are rejected with a clear
message — not merely that the code compiles.

Milestone 2 is accepted when `cabal test` additionally shows the "schema registry" and
"validation" specs passing: `lookupSchema` finds a seeded event name and returns `Nothing` for
an unregistered one; `validateEvent` returns `Right` for the well-formed sample; and it returns
`Left` containing `EmptyEventId` for an event with an empty id, `Left` for an event whose
`receivedAt` precedes its `occurredAt`, and `Left` containing
`MissingRequiredProperty (EventName "page_view") "url"` for a `page_view` event with empty
properties. This proves validation actually consults the registry and reports precise problems.

If any spec fails, read the assertion output: a round-trip mismatch usually means a field name
in the record does not match its JSON key (check `fieldLabelModifier = id` and that the record
field is spelled exactly as the camelCase key), or that an optional field encoded as `null`
instead of being omitted (check `omitNothingFields = True`). A decode failure on the good
sample usually means a required field is spelled wrong or a newtype's JSON instance was not
derived from `Text`.


## Idempotence and Recovery

Every step in this plan is safe to repeat. Editing `kansoku.cabal` to add modules and
dependencies is idempotent as long as you do not add duplicate entries; if a dependency such as
`aeson` is already listed by EP-1, leave the existing entry and do not add a second. Creating
the source and test files is idempotent — re-running the plan overwrites them with the same
content. `cabal build`, `cabal test`, and `fourmolu -i` are all naturally repeatable and make
no destructive changes outside the build tree; `cabal clean` resets the build tree if a stale
artifact is suspected.

There is no database, migration, network call, or other stateful side effect anywhere in this
plan, so there is nothing to roll back beyond ordinary source control. If a commit needs
undoing, use `git revert` on the current branch (do not rewrite shared history). If the build
breaks midway — for example after adding the record but before adding the codec — the failure is
a compile error, which is self-correcting: fix the code and rebuild; no external state was
touched.


## Interfaces and Dependencies

Libraries used, and why: `aeson` (JSON encoding/decoding — the wire contract and the round-trip
proof; provides `FromJSON`/`ToJSON`, `Object`, `Value`, `Options`, and the ISO-8601 `UTCTime`
instances; also `camelTo2`, which lives in aeson's own `Data.Aeson.Types` — no separate casing
package is needed); `text` (the `Text` string type underlying every
identifier and string field); `time` (`Data.Time.Clock.UTCTime` for the two timestamps and
their comparison during validation); `containers` (`Data.Map.Strict` for the registry's
name→schema map). Most of these (`aeson`, `text`, `time`, plus `generic-lens`
and `lens`) are already in scope transitively via EP-1's `Kansoku.Prelude`, which every module
here imports; the stanza still lists them as direct `build-depends` so the dependency is
explicit. No other runtime libraries are required; `mmzk-typeid` is deliberately *not* used (see
Decision Log).

These are the exact names, module paths, and signatures other plans (EP-3, EP-4, EP-5, EP-6,
EP-7) import. They are the normative contract; do not rename them without updating this plan
first and cascading the change.

Module `Kansoku.Event` (file `src/Kansoku/Event.hs`) exports everything below. The types and
their JSON instances are *defined* in `Kansoku.Event.Types` (file `src/Kansoku/Event/Types.hs`)
and re-exported — an internal split that exists only to keep the module graph acyclic (see the
Decision Log); consumers import `Kansoku.Event` and never need to name `Kansoku.Event.Types`:

```haskell
-- The canonical record. Fields exactly as listed in Plan of Work.
data AnalyticsEvent = AnalyticsEvent { eventId :: EventId, eventName :: EventName
                                     , source :: EventSource, sourceService :: Maybe Text
                                     , occurredAt :: UTCTime, receivedAt :: UTCTime
                                     , anonymousId :: Maybe AnonymousId, userId :: Maybe UserId
                                     , organizationId :: Maybe OrganizationId
                                     , accountId :: Maybe AccountId, sessionId :: Maybe SessionId
                                     , url :: Maybe Text, referrer :: Maybe Text
                                     , utmSource :: Maybe Text, utmMedium :: Maybe Text
                                     , utmCampaign :: Maybe Text, utmContent :: Maybe Text
                                     , utmTerm :: Maybe Text, correlationId :: Maybe CorrelationId
                                     , causationId :: Maybe CausationId
                                     , sourceEventId :: Maybe SourceEventId
                                     , sourceGlobalPosition :: Maybe Int64
                                     , properties :: Object, context :: Object }
instance FromJSON AnalyticsEvent
instance ToJSON   AnalyticsEvent

data EventSource = Web | App | Service | Worker | Email | Agent
instance FromJSON EventSource
instance ToJSON   EventSource
eventSourceToText :: EventSource -> Text

newtype EventId        = EventId Text        ; unEventId        :: EventId -> Text
newtype EventName      = EventName Text      ; unEventName      :: EventName -> Text
newtype AnonymousId    = AnonymousId Text    ; unAnonymousId    :: AnonymousId -> Text
newtype UserId         = UserId Text         ; unUserId         :: UserId -> Text
newtype OrganizationId = OrganizationId Text ; unOrganizationId :: OrganizationId -> Text
newtype AccountId      = AccountId Text      ; unAccountId      :: AccountId -> Text
newtype SessionId      = SessionId Text      ; unSessionId      :: SessionId -> Text
newtype CorrelationId  = CorrelationId Text  ; unCorrelationId  :: CorrelationId -> Text
newtype CausationId    = CausationId Text    ; unCausationId    :: CausationId -> Text
newtype SourceEventId  = SourceEventId Text  ; unSourceEventId  :: SourceEventId -> Text
-- each newtype: instance FromJSON, instance ToJSON, deriving Eq, Ord over the Text

identifyEvent :: EventId -> EventSource -> UTCTime -> UTCTime
              -> Maybe AnonymousId -> Maybe UserId -> Object -> AnalyticsEvent
aliasEvent    :: EventId -> EventSource -> UTCTime -> UTCTime
              -> Maybe AnonymousId -> Maybe UserId -> Object -> AnalyticsEvent
groupEvent    :: EventId -> EventSource -> UTCTime -> UTCTime
              -> Maybe UserId -> Maybe OrganizationId -> Object -> AnalyticsEvent
-- Kansoku.Event re-exports all of Kansoku.Event.Types, Kansoku.Event.Registry, and
-- Kansoku.Event.Validation.
```

Module `Kansoku.Event.Registry` (file `src/Kansoku/Event/Registry.hs`) exports:

```haskell
data PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny
data PropertySpec = PropertySpec { propName :: Text, propType :: PropertyType, propRequired :: Bool }
data EventSchema  = EventSchema  { schemaEventName :: EventName, schemaProperties :: [PropertySpec] }
newtype EventRegistry = EventRegistry (Map EventName EventSchema)

emptyRegistry  :: EventRegistry
registerSchema :: EventSchema -> EventRegistry -> EventRegistry
lookupSchema   :: EventName -> EventRegistry -> Maybe EventSchema
defaultRegistry :: EventRegistry   -- seeded: page_view, session_start, identify,
                                   -- user_registered, subscription_started
```

Module `Kansoku.Event.Validation` (file `src/Kansoku/Event/Validation.hs`) exports:

```haskell
data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
  deriving stock (Generic, Eq, Show)

validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEvent     :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
```

Cabal edits (in `kansoku.cabal`, the `kansoku:kansoku-api` sub-library stanza — the shared
internal library EP-1 carves out to hold the event model and, later, the servant API types):
add to `exposed-modules` the four modules `Kansoku.Event`, `Kansoku.Event.Types`,
`Kansoku.Event.Registry`,
`Kansoku.Event.Validation`; add to `build-depends` (if not already present from EP-1) `aeson`,
`containers`, `text`, `time`. The stanza already carries `import: common`
(GHC2024 plus the shared extensions) and depends on the `Kansoku.Prelude`-providing library.
Add `test/Kansoku/EventSpec.hs` to the `test-suite` stanza's module list (or rely on
`hspec-discover` if EP-1 configured it); that stanza also `import: common`. No changes to
`cabal.project` are required by this plan.

The shared `kansoku:kansoku-api` sub-library: the `Kansoku.Event*` modules live in a shared
internal Cabal sub-library named `kansoku:kansoku-api` that EP-1 establishes (carved out of
`kansoku.cabal`) together with the `Kansoku.Prelude` module every module here imports, so the
client SDK (EP-7) and the OpenAPI generator (EP-8) can reuse the event type without the server's
heavy dependencies. This plan adds its four modules to that sub-library's `exposed-modules`; it
must not alter the module paths (`Kansoku.Event`, `Kansoku.Event.Types`,
`Kansoku.Event.Registry`,
`Kansoku.Event.Validation`) or the JSON contract this plan owns, so the names above remain stable
regardless of which Cabal component holds them. That same `kansoku:kansoku-api` sub-library also
holds the servant API *type declarations* added by later plans — `Kansoku.Api.Ingest` (EP-4),
`Kansoku.Api.Metrics` (EP-6), and the combined `Kansoku.Api` — depending only on `servant` plus
aeson/base/text/bytestring/time/containers/uuid (no servant-server, warp, ClickHaskell, or pgmq).
This plan does not create that sub-library; it owns only the event model within it.

Dependency on EP-1: this plan cannot build until EP-1 has created `kansoku.cabal`, the
`src/Kansoku/` source tree, and a working test-suite. Consumers of this plan: EP-3 maps
`AnalyticsEvent` to a ClickHouse `EventRow`; EP-4 decodes pgmq message bodies and HTTP request
bodies into `AnalyticsEvent` and calls `validateEvent`; EP-5 recognizes identity events by the
`identify`/`alias`/`group` names defined here; EP-6 reads the same field vocabulary; EP-7
constructs and encodes `AnalyticsEvent`. All of them import the exact names above.


## Revision Note

2026-07-01 — Adopted the shared haskell-jitsurei/core Haskell standards
(`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`: `standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`) throughout this plan. Concretely:

- **Prelude and imports.** Every code sketch now opens with `import Kansoku.Prelude` (EP-1's
  shared prelude, which re-exports `Text`, `Generic`, aeson's `FromJSON`/`ToJSON`/
  `genericParseJSON`/`genericToJSON`/`Options`/`defaultOptions`, `camelTo2`, `UTCTime`,
  `NonEmpty`, and a blanket `Control.Lens`) instead of ad-hoc per-file imports and pragmas.
  Per-file language pragmas were dropped in favour of the cabal `common` stanza (GHC2024 plus
  `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`,
  `MultilineStrings`). Qualified imports were made postpositive
  (`import Data.Map.Strict qualified as Map`, `import Data.Aeson.KeyMap qualified as KeyMap`).
  A "Coding standards" paragraph was added to Context and Orientation pointing at the standards
  directory and the prelude.
- **Deriving strategies.** Records now carry strict `!` fields, no field prefixes, the entity id
  first, and explicit `deriving stock (Generic, Eq, Show)`. `AnalyticsEvent` keeps explicit
  generic `FromJSON`/`ToJSON` instances over the shared `analyticsEventOptions` (the standards'
  "Custom Options for Optional Fields" pattern) because the wire contract needs the non-default
  `omitNothingFields = True`, which plain `deriving anyclass` cannot express. Identifier newtypes
  now use `deriving stock (Generic, Show)` + `deriving newtype (Eq, Ord, FromJSON, ToJSON)`. The
  identity-event smart constructors use generic-lens `#label` setters (with a per-module
  `import Data.Generics.Labels ()`) instead of record-update syntax.
- **`EventSource`.** Documented as the single deviation from generic deriving: `FromJSON` stays
  hand-written because the acceptance test requires the exact `unknown event source` error
  wording, and `ToJSON` stays a one-liner over the exported `eventSourceToText` helper (EP-3's
  ClickHouse mapping reuses it) so the wire form has one source of truth. The Decision Log
  entries for the `AnalyticsEvent` codec and for `EventSource` were rewritten to record this
  reasoning.
- **Component placement.** All modules are now stated to live in EP-1's shared
  `kansoku:kansoku-api` sub-library (not a monolithic `library` stanza). (This revision
  originally also added an `aeson-casing` dependency for `camelTo2`; that was mistaken —
  `camelTo2` lives in aeson itself — and was corrected in the later revision below.)

Why: the plan predated the codified standards; aligning it keeps EP-2 consistent with the rest
of the Kansoku codebase and prevents drift between this normative contract and the conventions
every consuming plan (EP-3…EP-8) will follow. Design intent — the field set, the JSON wire
contract, the reject-unknown-source guarantee, the round-trip proof, and the schema
registry/validation behavior — is unchanged.

2026-07-01 — Corrections from a pre-implementation validation pass. Before any code was
written, a validation review of this plan against GHC's module rules, aeson's actual API, and
the plan's own standards found one blocking defect and several smaller inaccuracies. All are
fixed in this revision; the JSON wire contract and the public API are unchanged.

- **Import cycle (the critical fix).** The previous structure defined the core types in
  `Kansoku.Event` and had that same module re-export `Kansoku.Event.Registry` and
  `Kansoku.Event.Validation` — but Registry uses `EventName` and Validation uses
  `AnalyticsEvent`/`EventName`, so those modules would import `Kansoku.Event` while it imported
  them back: an import cycle GHC rejects. The shared types (the `AnalyticsEvent` record, the
  ten identifier newtypes, `EventSource`, `analyticsEventOptions`, and their JSON instances)
  now live in a new leaf module `Kansoku.Event.Types` (`src/Kansoku/Event/Types.hs`, in the
  same `kansoku:kansoku-api` sub-library); Registry and Validation import Types; and
  `Kansoku.Event` imports all three, defines the identity-event smart constructors, and
  re-exports everything — so `import Kansoku.Event` remains the single public entry point.
  Every module sketch, file path, cabal `exposed-modules` list, Progress item, and the module
  placement Decision Log entry were updated to the four-module layout.
- **`camelTo2` attribution.** `camelTo2` lives in aeson itself (`Data.Aeson.Types`), not in the
  `aeson-casing` package; the attribution was corrected and `aeson-casing` removed from every
  dependency list (EP-1 is dropping that dependency as well).
- **Field count.** The `AnalyticsEvent` record has twenty-four fields, not twenty-five; the
  codec Decision Log entry was corrected.
- **Round-trip wording.** The Purpose section promised "byte-for-byte equivalent JSON" while
  the tests (correctly) compare parsed `Value`s; the promise now reads as parsed-JSON-value
  equivalence, with key order and whitespace immaterial.
- **Record updates in tests.** The sample test code used record-update syntax
  (`expectedSample { eventId = ... }`), contradicting the plan's own generic-lens standard; the
  snippets now use `#label` setters (for example `expectedSample & #eventId .~ EventId ""`)
  with the per-module `import Data.Generics.Labels ()` shown in the test module's imports.
- **Redundant extension.** The claim that `GeneralizedNewtypeDeriving` was an extra extension
  to add was wrong — GHC2024 already implies it; the pragma and the claim were removed.
- **`analyticsEventOptions` location.** One Decision Log sentence said the options value is
  imported from `Kansoku.Prelude`, contradicting the Plan of Work (defined locally next to the
  record, promoted to the prelude only if a later plan reuses it); the phrasing now matches the
  Plan of Work.
- **`sourceGlobalPosition` rationale.** Typing the field `Maybe Int64` deviates from the spec's
  `number` without a recorded reason; a new Decision Log entry records the rationale (global
  positions are integer sequence numbers; `Int64` matches message-db's `bigint` positions).

Why: catching the import cycle before implementation avoids a mid-milestone restructure of the
plan's central deliverable; the remaining fixes keep the plan internally consistent and
accurate so a novice can follow it end-to-end without hitting contradictions.
