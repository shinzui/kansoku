---
id: 67
slug: read-identified-users-profiles-and-event-history
title: "Read identified users, profiles, and event history"
kind: exec-plan
created_at: 2026-11-12T23:45:07Z
intention: "intention_01m792c74zedbr8236cpzmz5bp"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-12T23:45:07Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T00:32:25Z
      mode: "implement"
      note: "Implement authenticated users resource and verify public owned-store acceptance."
---

# Read identified users, profiles, and event history


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation.

## Purpose / Big Picture


A service-token consumer will be able to display an account's identified-user directory, open a user's current profile and identity-evidence summary, and walk their retained resolved events. A separate read returns exact identified and anonymous activity counts. This implements AC-1 through AC-5 of `docs/improvement-requests/read-identified-users-their-profiles-and-event-history.md` (IR-17). Success is demonstrated through public HTTP calls against disposable real stores, including pre-login stitching, account isolation, erasure, and safe event properties. User writes and the separate per-user metric selector in IR-18 are outside scope.

## Progress


- [x] Milestone 1 (2026-11-13): Authenticated directory and exact counts pass owned real HTTP acceptance, including stitched activity, both orders/directions, nullable extrema, literal search, typed filters, static/behavioural cohorts and bot/count parity. Evidence: `nix develop --no-write-lock-file -c python3 scripts/users_acceptance.py`, private run `.dev/acceptance/cohort-1w5b3kjz`.
- [x] Milestone 2 (2026-11-13): Profiles pass eligible set/set-once, equal occurrence/receipt event-ID tie, replay, legacy exclusion, evidence/anonymous counts, organisation moves, actual deletion and physical pre-TTL fingerprint expiry checks in the same owned run.
- [x] Milestone 3 (2026-11-13): History passes stitched uniqueness, complete tied-key forward/backward walks, name filters, schema-version and alias/privacy projection, and newer-arrival continuation/refresh checks. Pure exact-version/type/privacy tests also pass in the deterministic suite.
- [ ] Milestone 4: Full public acceptance, served OpenAPI, query guide, and durable architecture documentation agree on all five request criteria.

Current validation: the final local build and deterministic suite pass (521 core examples, 22 client examples, four probe checks), as do generated OpenAPI/contract freshness, OpenAPI lint, formatting and strict ADR/guide/friction validation. The focused run `.dev/acceptance/cohort-gojfbi5a` additionally compares served/committed OpenAPI, applies actual retention and forces native memory exhaustion on all four routes; each returns a complete 503 problem without partial data. Cohort regression passed in `.dev/acceptance/cohort-fkfm2951`. Aggregate packaged acceptance is running with the local checkout of `mori://shinzui/kansoku-ts` as its required SDK prerequisite; both package builds and all 18 native migration cases have passed; service integration is in progress.

## Surprises & Discoveries

2026-11-13: The administrative erase command defaults to identity unlinking and deliberately retains explicit user facts. The users lifecycle proof must invoke `erase-user --delete-events` to prove disappearance; changing existing unlinking semantics is outside this resource plan. The owned cohort helper now accepts an opt-in deletion flag, preserving its existing default. The initial HTTP run verified identity unlinking removes evidence/traits while explicit retained events still establish a profile.

2026-11-13: Relay accepts a zero page size; users handlers and the generated OpenAPI parameter schemas explicitly enforce the required minimum of one. ClickHouse comparison expressions serialize as integers unless cast to Bool; history existence/page-view projections explicitly cast them before JSON decoding.


## Decision Log


2026-11-12: Deliver a `/users` resource family and `/users/activity-counts` rather than expanding aggregate grouping. This keeps exact split counts available independently of pagination and leaves `/metrics/users` unchanged as the comparison oracle.

2026-11-12: Follow existing current-read Relay pagination, with no cross-request snapshot guarantee. Stable ordering resolves ties in unchanged data; activity updates, retention, and current identity/trait changes can move rows between pages. Document that consumers must refresh and deduplicate after concurrent changes rather than promise a frozen directory.

2026-11-12: Use the existing UTC `from` inclusive, `to` exclusive date convention. In this plan a closed range means both bounds supplied, not an inclusive upper timestamp. This preserves exact comparison with `/metrics/users` and avoids an off-by-one day change.

2026-11-12: Calculate profile provenance from eligible canonical trait observations, rather than changing aggregate state types. Existing `user_properties` states retain values but do not return the winning observation's ordering tuple. A bounded single-user reduction over `analytics.user_trait_events` can recover the winner without a schema migration.

## Outcomes & Retrospective


## Context and Orientation


Kansoku has a shared Haskell API package, an implementation package, and server executables. `kansoku-api/src/Kansoku/Api.hs` composes named route records; `kansoku-core/src/Kansoku/Server.hs` assembles their handlers. `kansoku-api/src/Kansoku/Api/OpenApi.hs` generates the served contract and `docs/api/openapi.json`. New modules must be registered in `kansoku-api/kansoku-api.cabal` and `kansoku-core/kansoku-core.cabal`.

Identity resolution assigns an event a subject kind and ID: a known person is `user`, otherwise an identified anonymous browser/device subject is `anonymous`; an empty identity is not a countable subject. `kansoku-core/src/Kansoku/Metrics/Query.hs` exports `resolvedSource`, which uses the private rich `analytics.events_resolved_http` relation. `kansoku-core/src/Kansoku/Identity/Cache.hs` and `kansoku-core/src/Kansoku/ClickHouse.hs` own per-connection evidence preparation and expiry. A query must use `withIdentityQueryConnection` for the complete candidate time scope on the same physical connection as its SELECT. A direct `user_id` lookup on raw events misses pre-login events and is not a substitute.

`kansoku-core/src/Kansoku/Cohort/Handler.hs`, `kansoku-core/src/Kansoku/Cohort/Members.hs`, and `kansoku-api/src/Kansoku/Cohort/Api.hs` demonstrate service-token auth, native parameter binding, deadlines, Relay page decoding, and `pageSize + 1` fetching. Relay connections contain edges with opaque cursors and pageInfo; keyset pagination selects rows after or before a complete ordered key instead of using an offset. `kansoku-core/src/Kansoku/Cohort/Query.hs` compiles saved membership; `kansoku-core/src/Kansoku/Cohort/Store.hs` loads account-scoped definitions. `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` and `kansoku-api/src/Kansoku/Metrics/Filter.hs` establish the existing strict query/filter grammar. `kansoku-core/src/Kansoku/Metrics/Query/Traits.hs` joins current governed traits: registered, typed attributes accepted through eligible schema versions, not arbitrary event properties.

`kansoku-server/migrations/clickhouse/original/0021_governed_current_user_traits.sql` documents trait source and aggregate definitions; executable migrations live under `kansoku-server/migrations/clickhouse/steps/` with a manifest. Do not edit historical migrations. `analytics.user_trait_events` retains eligible observations and excludes trait-erasure tombstones. A latest set overrides any set-once; absent a set, the earliest set-once wins. The total stored order is occurrence milliseconds, receipt milliseconds, event ID. `analytics.user_organizations` stores latest explicit membership, and `analytics.organization_traits` supplies governed organisation values.

Relevant ADRs were discovered by scanning filenames/headings and reading the applicable records. [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires metrics-read service tokens and principal-derived tenancy. [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) requires replay-safe canonical facts and keeps the public eight-column SQL view stable. [ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md) requires conservative nontransitive stitching, retained evidence outside selected event windows, and query-time fingerprint expiry. [ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md) makes event schema versions immutable, and declares alias properties that themselves contain identifiers: declaration alone is therefore insufficient to authorize their disclosure. [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) supplies execution budgets; resource collections may paginate but may not truncate their input populations. [ADR-16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md) defines trait eligibility, winners, and replay-safe erasure. [ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md) defines identified cohort membership and current-read pagination. [ADR-21](../adr/0021-organization-aggregation-and-current-membership.md) defines latest explicit membership, including group v1 membership and governed group v2 traits.

The requesting consumer is `mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages`; the integration handoff is `mori://shinzui/kansoku-ui/plans/29-integrate-kansoku-s-users-resource-through-the-server-boundary`. This plan is independently executable and is not a child of that repository's MasterPlan. Mori registry discovery was attempted during creation but its PostgreSQL notification service refused the local socket connection. Repository examples establish existing use of Relay; dependency internals and cross-repository URI resolution were not verified. Restore registry access before changing dependency usage. No dependency upgrades are proposed.

## Plan of Work


### Milestone 1: Directory and exact counts through public HTTP


Create `kansoku-api/src/Kansoku/Users/Types.hs` and `kansoku-api/src/Kansoku/Users/Api.hs`, and implementation modules `kansoku-core/src/Kansoku/Users/Query.hs`, `kansoku-core/src/Kansoku/Users/Handler.hs`, and `kansoku-core/src/Kansoku/Users/Validation.hs`. Wire a Users named-route record into the API and server. Use MetricsAuth on each leaf. Extend strict query-parameter validation for these routes after authentication; reject unknown or repeated scalar parameters and invalid combinations before definition loading or query checkout. Reuse native parameter binding, cancellation, and memory/time limits; return complete errors on exhaustion.

Implement `GET /users` with optional paired `from`/`to`, `search`, `order=lastActivity|firstActivity` (default lastActivity), `includeBots` (default false), repeated `filter`, and Relay first/after or last/before. Default page size is 20, maximum 100, minimum 1. Search is a literal case-insensitive substring of user ID, 1..256 Unicode code points; percent and underscore are literal characters. Explicit ranges span 1..366 UTC days. Filters allow at most eight `user:` predicates plus one cohort eq/neq UUID predicate; use existing typed operators and operand bounds, AND semantics, and reject other dimensions/OR groups. Missing or foreign cohorts return the existing cohort-not-found problem. Behavioural membership anchors to explicit `to`, or a single captured next UTC midnight when no range is supplied, with its full lookback prepared in the identity connection.

Start from all retained resolved subjects of kind user, including users observed only in identity/profile events. Compute activity over canonical events excluding identify, identify_once, alias, and group, using the same bot predicate as `/metrics/users`. First/last activity are retained-history values, not extrema of the selected window. With a date selection require at least one qualifying activity event in that window; without it, users without activity remain with null extrema. Current traits come from the shared governed catalog and missing traits are omitted. Sort selected activity timestamp descending, null last, then userId ascending. Encode the null marker, timestamp, and userId in the complete cursor key; reverse comparison and fetch order for backward pages, then restore canonical output order. Reject cursors for a different order. Document that clients must keep all selection parameters unchanged across a walk.

Whole-retained-history extrema must not be clipped to 366 days. Discover actual retained account bounds from canonical facts, including the last day's exclusive upper boundary, and prepare identity for that scope (union cohort lookback). Empty accounts return empty connections. Do not invent an epoch cutoff or silently limit candidate events. Explicit user-selected ranges still have the 366-day bound; broad retained reads can fail with a complete resource-limit error.

Implement `GET /users/activity-counts?from=...&to=...&includeBots=...` with required paired dates and exact UInt64 counts, returned as JSON integers `identified` and `anonymous`. Use one resolved activity population and exact distinct subjects per kind. Exclude empty subjects and the same four nonactivity names. This endpoint accepts no directory search, trait, or cohort filters. Static route matching must precede the user-ID capture.

Add `kansoku-core/test/Kansoku/Users/QuerySpec.hs` and `kansoku-core/test/Kansoku/Users/HandlerSpec.hs`. Begin `scripts/users_acceptance.py` using `scripts/cohorts_acceptance.py`'s owned-store main helper. Its first proof ingests a pre-login event and identify plus an action, waits for visibility, and confirms one directory user and split counts equal to `/metrics/users?timeGrain=none`. This public path must pass before expanding profile/history work. Then exercise filters, tied extrema, backward pages, nullable extrema, two accounts, and failures. The milestone is accepted when those real HTTP results and deterministic validation tests pass.

### Milestone 2: Profile and evidence summary


Implement `GET /users/{userId}` returning `userId`, `traits`, `firstActivityAt`, `lastActivityAt`, `retainedEventCount`, `identityEvidence`, `resolvedAnonymousCount`, and nullable `organization`. Decode captured IDs as text and compare via bound native parameters. Do not interpret colons or prefixes in the original ID. Determine existence from retained resolved user subjects, not a static cohort upload or an arbitrary lookup string. Unknown, foreign-account, and erased users receive the same 404 `user_not_found` problem. A user with retained identity events only exists but has null activity extrema. This read includes all bots and all retained event kinds in retainedEventCount; activity extrema use the default nonbot activity definition. State that distinction explicitly in the schema.

Each trait is `{value, observedAt, operation}`, where operation is `set` or `set_once`, and observedAt is the winning occurrence time in UTC milliseconds. Reduce `analytics.user_trait_events` by account/user/name using the exact total order and set precedence above. Share catalog/type handling with current-trait queries; test that these values equal directory traits. Do not infer winning time from max occurrence across both operations or from raw ineligible legacy rows.

Return all five evidence-kind keys (cookie, device, fingerprint, email_hmac, email_sha256), including zeros. Each value counts distinct retained identifier values bound to this explicit user for that kind, rather than duplicate observations. Shared/conflicted bindings may count as evidence but do not assert a resolved identity. Apply fingerprint's 180-day occurrence-time validity predicate even before TTL cleanup, captured at query time. Use canonical/finalized evidence, account scope, and post-erasure sources. No value or hash is returned. Count distinct nonempty original anonymous IDs among retained events currently resolved to this user for resolvedAnonymousCount; do not count explicit-user events with unrelated anonymous identifiers as additional resolved anonymous subjects. Define this as original anonymous events (no explicit user ID) resolved by the common resolver, so the count reflects stitching rather than the size of an identifier bag.

Read current explicit membership with argMaxMerge from `analytics.user_organizations` and join only that organisation's governed current traits by account. Return `{organizationId, traits}` or null. Preserve group v1 membership while testing group v2 trait updates. Execute the profile's component queries on one owned connection within one overall deadline; document eventual cross-table consistency rather than claiming an atomic snapshot. Extend public fixtures for competing set/set-once writes, ordering ties, replay, legacy ineligibility, multiple evidence kinds, fingerprint expiry, membership moves, and erasure. This milestone requires the actual administrative erase command, not a mocked missing row.

### Milestone 3: Safe resolved event history


Implement `GET /users/{userId}/events` with optional paired dates, includeBots default false, Relay pagination, and at most one repeated-filter grammar predicate selecting `event_name` by eq or in (1..100 raw names, each 1..128 characters under the existing name grammar, bounded before deduplication). Unknown valid names yield empty pages. Require the same user existence check as profiles. Include identity/profile events in history; only the extrema/count activity population excludes them. Filter resolved subjects after common identity resolution so pre-login events appear.

Each edge node exposes `eventId`, `eventName`, `occurredAt`, `source`, `sourceService`, `sessionId`, nullable `host` and `path`, `isPageView`, and `properties`. Sort by occurredAt descending, receivedAt descending, eventId descending; the opaque cursor carries all three stored keys. Use canonical event-ID uniqueness, fetch one extra row, and support both Relay directions. Host/path and isPageView use existing enrichment/canonical page-view rules, not a fresh URL interpretation or a name-only shortcut. Empty optional host/path values become null.

Use `kansoku-api/src/Kansoku/Event/Registry.hs` to select declarations for each row's exact stored schema version. Explicitly construct a new response object from typed declared string/number/Boolean scalars; omit absent, null, incompatible, nonfinite, PTAny, array, and object values. An unknown event/version returns an empty properties object. Never serialize AnalyticsEvent or raw property/context blobs directly. Alias previousId/newId are declared identifier payloads and must still be excluded. Identity-event properties are restricted to governed trait catalog names declared at that version; group-event properties are restricted to declared organisation traits. Exclude raw identifier fields in all envelopes. Keep private extraction results out of logs and exception text. Add a small dedicated property projection helper in `Kansoku.Users.Query` or a new Users module, with pure tests proving version selection and privacy exclusions.

The milestone passes when stitched events appear once, equal timestamps straddle page boundaries without loss in unchanged data, both directions agree, name/date filters work, and serialized public bodies omit seeded undeclared secrets, identifiers, alias payloads, and context. Declared identify traits must remain visible. Prove an arrival between requests follows the documented current-read behavior; do not assert immutable pagination under identity changes.

### Milestone 4: Contract, lifecycle, and complete acceptance


Integrate `verify_users` into `scripts/acceptance.py` with the owned two-account fixtures and real erasure callback. Add a focused `users-acceptance` recipe to `justfile`. Ensure expiry/retention cases operate only on disposable owned stores. Retention must update activity extrema, event counts, evidence, and current traits consistently; a user with no retained resolved events disappears. Replaying erased source IDs must not resurrect the user. Existing cohort and whole-range user metrics acceptance must continue to pass.

Update `kansoku-api/src/Kansoku/Api/OpenApi.hs`, regenerate `docs/api/openapi.json`, and update `docs/guides/query-metrics.md` with its guide metadata/log. Document every request bound, error media type, nullable field, ordering key, bot default, all-event versus activity counts, privacy projection, schema-version behavior, retention, erasure, and current-read pagination caveat. Pagination errors retain the existing Relay wire exception; other input/not-found/storage errors use project problem details. Identity and traits are analytical inference, never authentication or authorization. Update/create the applicable ADR through the profile-aware ADR workflow, recording the resource contract and per-version safe projection. Do not hand-allocate ADR handles.

## Concrete Steps


All commands run at the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Before using new dependency APIs, retry discovery; inspect the returned source locations and docs. If selecting new bounds or pins becomes necessary, verify authoritative registry releases and upstream tags first. Keep current dependencies otherwise.

```bash
mori registry list
mori registry search relay-pagination
mori registry show shinzui/relay-pagination --full
mori registry docs shinzui/haskell-jitsurei
```

Implement and register each milestone's modules/tests, then run the existing build wrapper and deterministic test selection. These commands should exit zero; the new Users tests must run, not be silently skipped.

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just deterministic-test
```

After creating the focused fixture, run it as the early public path and again after relevant milestone changes. The script must print a concise users acceptance success summary only after every assertion passes and report its private evidence directory. It starts and stops its own server and stores, issues its own credentials, applies migrations, and exercises actual HTTP; no ambient database setup is needed.

```bash
nix develop --no-write-lock-file -c python3 scripts/users_acceptance.py
nix develop --no-write-lock-file -c python3 scripts/cohorts_acceptance.py
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just openapi-check
nix develop --no-write-lock-file -c just openapi-lint
nix develop --no-write-lock-file -c just guides-check
nix develop --no-write-lock-file -c just adr-check
git diff --check
```

Use native owned processes when supported. If Linux is required, use Apple Container and the repository's isolated ClickHouse helper; never Colima. Preserve failures and actual coverage boundaries. Do not label an unavailable native fixture as passing. Run the existing aggregate acceptance gate with its configured SDK prerequisite when validating integration into `scripts/acceptance.py`; `scripts/acceptance.sh` and `docs/guides/development.md` describe that gate's environment. Record exact final commands and results in Progress rather than claiming unexecuted checks.

## Validation and Acceptance


AC-1 is proved by an account A directory with two users having tied activity timestamps, a profile-only user, a stitched pre-login action, and an anonymous-only subject, plus account B containing colliding IDs. Default and first-activity sorting must produce complete deterministic forward/backward walks at page size one. Test literal mixed-case substring search, every supported typed trait operation, cohort inclusion/exclusion, combined selection, retained-history extrema outside the selection window, null extrema, bots, and erasure. A write key returns 403 and missing/revoked credentials return 401.

AC-2 is proved by a later set-once losing to an earlier set, equal occurrence times resolved by receipt/event ID, an ungoverned legacy write losing eligibility, exact evidence counts unchanged by replay, expired fingerprint exclusion, organisation moves and group v2 values, and indistinguishable 404s. Assert identifier sentinel strings are absent from the complete response serialization, including errors.

AC-3 is proved with occurrence ties split across cursors, pre-login events, both pagination directions, name eq/in, date boundaries, schema version differences, absent schemas, typed scalars, undeclared/context secrets, and declared alias identifiers that remain hidden. Current-read tests insert a newer event after page one and verify that continuation uses its saved key and refresh exposes the new row; changes to a user's sort key may require refreshing a directory walk.

AC-4 requires `identified + anonymous` to equal one ungrouped `/metrics/users` whole-range exact value with `timeGrain=none`, never the sum of daily distinct counts. Test both bot selections, a subject resolving inside the range, shared conflicting signals, namespace text collisions, identity-only events, and an empty population returning two zeroes.

AC-5 requires served and generated OpenAPI agreement and an executable rejection test for zero/oversized pages, malformed/incompatible cursors, unsupported sort, empty/oversized search, lone/reversed/overlong dates, excessive trait/cohort filters, wrong trait operand types, unsupported dimensions/operators, empty/oversized event lists, unknown/repeated scalar parameters, and resource exhaustion without partial success. Native SQL tests must assert principal account parameters and complete key comparisons, and the public fixture must verify effects rather than SQL text alone.

## Idempotence and Recovery


This feature is additive and initially requires no migration, index, or materialized state. Never edit old migrations to obtain profile provenance. If measurement proves canonical scans cannot meet budgets, record evidence and revise the plan before introducing an additive indexed projection and its fenced rebuild/erasure requirements. Never silently truncate retained inputs to force a query to pass.

Fixtures use unique prefixes, private ports/directories, and OwnedResources cleanup. Failed runs retain diagnostic evidence but must stop their own children; reruns create fresh owned stores. Do not run test retention or erasure against shared data. Rollback removes the new route wiring with no data rollback. Preserve existing user changes to improvement-request documents. During implementation record friction through the skill script and triage it at completion; commits use Conventional Commits with this plan's ExecPlan trailer and the frontmatter Intention ID.

## Interfaces and Dependencies


`Kansoku.Users.Types` owns UserSummary, UserProfile, UserEvent, and UserActivityCounts JSON/OpenAPI types. Summaries carry `userId`, scalar `traits`, and nullable UTC-millisecond `firstActivityAt`/`lastActivityAt`. Profile traits additionally carry provenance. `Kansoku.Users.Api` owns MetricsAuth leaf routes and typed success/problem/page responses. `Kansoku.Users.Validation` produces validated bounded request values before storage; `Kansoku.Users.Query` compiles account-bound native SQL and safely decodes/project rows; `Kansoku.Users.Handler` loads cohort definitions, acquires the proper connection, and maps results to public responses.

Use the existing Relay, Servant, ClickHaskell, registry, authentication, and query-pool dependencies. No arbitrary SQL identifiers come from request text. Do not alter the public resolved SQL view's ordered eight columns or metric response shapes. Any extraction of shared subject/activity helpers from `Kansoku.Metrics.Query` must preserve existing metric tests. Consumer delivery consists of the served OpenAPI contract and examples in this repository; implementing or publishing the separate UI is outside this plan.
