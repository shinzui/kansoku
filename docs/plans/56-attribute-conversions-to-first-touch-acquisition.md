---
id: 56
slug: attribute-conversions-to-first-touch-acquisition
title: "Attribute conversions to first-touch acquisition"
kind: exec-plan
created_at: 2026-11-06T03:24:27Z
intention: "intention_01m6qe212geserbtd72wh0qvaz"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T03:24:27Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T13:10:03Z
      mode: "implement"
      note: "Implement first-session conversion measures, public validation and acceptance coverage"
---

# Attribute conversions to first-touch acquisition


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction through `agents/skills/exec-plan/record-friction.ts` following `agents/skills/exec-plan/FRICTION.md`. Promote durable decisions into the existing architecture records before completion.


## Purpose / Big Picture


Implement [IR-5](../improvement-requests/attribute-conversions-to-first-touch-acquisition.md): a caller can ask `/metrics/acquisition` which traffic sources brought people who later converted. Add `measure=converted_users` and `measure=conversion_rate`, with a comma-separated `conversionEvents` list of 1..20 event names. Attribute a person's conversion to their first selected web session in the requested range, including when an anonymous visit is later linked to a known user and the conversion arrives from a server without web attribution.

For example, two people first arrive through organic search and one through email; one organic visitor and the email visitor later emit `signup_completed`. The new queries return organic search: one converted user and rate 0.5; email: one converted user and rate 1. Existing session and user queries retain their meanings. This work creates the query feature, tests, generated API description, and usage documentation; it does not implement revenue attribution, saved metric references, new channel classification, or multi-touch attribution.


## Progress


- [x] Milestone 1 (2026-11-06): Native queries assign each canonical person to one selected first session; anonymous alias plus service conversion returns organic_search=1/email=1 and rates 0.5/1. `just acquisition-acceptance` passed at block sizes 65536 and 2: acquisition 5, sessions 4, traits 6 examples per size, all with zero failures/pending; replay and both conversion measures at 10,000/10,001 points passed.
- [x] Milestone 2 (2026-11-06): Authenticated HTTP passed the explicit acquisition counts/rates, distinct event names, 20-entry list, malformed/repeated/valueless inputs, whole-range mode and replay in all three telemetry modes. The generated Haskell client forwards the expanded route; `just check` passed 489 deterministic core examples, 21 client examples and 4 probes, OpenAPI generation/freshness/lint, strict metadata validation and telemetry. The packaged client passed all 22 examples, including live integration.
- [x] Milestone 3 (2026-11-06): Timing, namespace/account isolation, ambiguous aliases, deterministic full-row attribution, dimensions, filters, bots, traits/cohorts, replay and 10,000/10,001-point bounds passed. The owned normal/tiny-block runner passed 9 acquisition, 4 session and 6 trait examples per size, with zero failures/pending. `just check` and full packaged `just acceptance` exited zero; the latter passed 612 core examples including native cases, 22 client examples including live integration, acquisition HTTP in all three telemetry modes, 17 migration cases and 7 administrative scenario families. The guide and ADR-12/9 document the population and bounds; all implementation friction is triaged.

Implementation is complete. All required acceptance gates passed on 2026-11-06. The feature requires no migration or dependency change and composes with the existing whole-range acquisition mode. The intention was created with `mina ci --json 'Attribute conversions to first-touch acquisition'` and is recorded in frontmatter. No parent MasterPlan is required.


## Surprises & Discoveries


2026-11-06: IR-4 has landed: `TimeGrain.NoTimeBucket` and `timeGrain=none` already support acquisition. Both conversion measures compose with its existing constant-bucket/null response path; the native multi-day fixture passes in daily and whole-range mode.


2026-11-06: The new public acquisition scenario passed, but the global acceptance workflow subsequently failed in the existing percentile fixture: its final replay submitted every sample at once, exceeding the configured 4096-byte HTTP request cap. Preserve the cap, data and assertions, and replay in the same three-event batches as initial delivery (FRIC-8 in docs/friction-log/). This is a required acceptance-fixture repair, not a change to metric semantics.


## Decision Log


2026-11-05: Use the request's suggested user-level population: choose one first selected session per nonempty canonical subject across the full requested range, before grouping or bucketing. Conversion events may occur in another session or source service. This answers acquisition of converting people and prevents one person receiving credit in several channels.

2026-11-05: Preserve existing `sessions` and `users` semantics. Existing `users` is distinct primary subjects within each bucket/group and permits a person in multiple groups. The new rate uses the internally selected first-session population as its denominator; it is not generally `converted_users / measure=users` from a separate legacy query. Document and test this distinction explicitly instead of silently changing existing reports. A separately exposed first-touch denominator measure is outside this request.

2026-11-05: Apply session filters, current-trait/cohort selection, and any-bot session exclusion before choosing the first selected session. These predicates do not filter conversion-event attributes. Exclude individually bot-marked conversion events unless `includeBots=true`; eligible nonbot service events need no web session. This preserves the existing acquisition selection boundary while preventing a server conversion's `direct` classification from replacing the web source.

2026-11-05: Keep whole-range output from [IR-4](../improvement-requests/count-unique-users-over-a-whole-range.md) a soft dependency. This plan preserves daily default and the currently supported grains. The new measures assign each person to their selected session's bucket. If IR-4 has landed before implementation, compose with its established unbucketed acquisition mode; do not introduce a competing grain or implement the other routes here.


## Outcomes & Retrospective


All three milestones are implemented and verified. `/metrics/acquisition` now supports exact `converted_users` and `conversion_rate` with strict conversion-event validation, shared retained identity resolution, one selected session per person and complete bounded results. Daily and `timeGrain=none` examples pass through native execution and authenticated HTTP, including anonymous alias evidence and backend conversions. Legacy session/user meanings remain intact; no storage migration, dependency pin or external SDK/UI change was needed.

The final `nix develop --no-write-lock-file -c just check` exited zero, including formatting, 489 deterministic core examples, 21 client examples, 4 probes, fresh OpenAPI/contracts, OpenAPI lint, strict documentation/friction validation and telemetry lifecycle checks. `just acquisition-acceptance` passed all 19 examples at each of block sizes 65536 and 2. The final `just acceptance` run reached “Acceptance passed: required native/live tests, Hurl, packaged administration/startup and three telemetry modes.” It passed 612 core examples including native cases, 22 client examples including live integration, the EP-56 workflow three times, all 17 migration cases and all 7 required administrative scenario families. Private evidence is retained under `.dev/acceptance/run-7j10lrid/`, with sanitized output in its `sanitized/` directory.

Durable first-session selection, denominator compatibility, conversion timing/source/bot rules and whole-range semantics are distilled in [ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md); [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) records the raw event-list bound and storage-free validation. The query guide and generated API describe the same contract. No required work remains.

FRIC-6 in `docs/friction-log/` is accepted: the existing Cabal generation/check workflow incurs flag-related recompilation, and build-tool changes remain outside this feature. FRIC-7 is accepted: preserving the original log body around CLI appends retains existing adoption provenance. FRIC-8 is resolved: the pre-existing percentile replay fixture now uses bounded batches, preserving its population, assertions and packaged request cap; the full fixture-isolation and packaged acceptance workflows passed.


## Context and Orientation


The request is `docs/improvement-requests/attribute-conversions-to-first-touch-acquisition.md`, originating from `mori://shinzui/kansoku-ui`. The API is defined by Haskell Servant types in `kansoku-api/src/Kansoku/Metrics/Api.hs`. `AcquisitionMeasure` has `AcquisitionSessions`, `AcquisitionUsers`, `AcquisitionConvertedUsers` and `AcquisitionConversionRate`; `AcquisitionQuery` adds measure, conversionEvents and includeBots to the shared date/group/filter parameters. `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` maintains an explicit parameter allowlist and rejects repeated scalar parameters. `kansoku-core/src/Kansoku/Metrics/Handler.hs`, particularly `acquisitionHandler`, converts authenticated input into a `QueryRequest` and loads requested cohorts before execution.

The compiler and executor are `kansoku-core/src/Kansoku/Metrics/Query.hs`: `compileAcquisition`, `runAcquisition`, `buildAcquisitionSQL`, `retainedScope`, and `rawResolvedSource`. `QueryRequest` carries account, date range, grouping, grain, filters, cohort definitions, and bot policy. A canonical subject is the identity system's resolved person key, such as `user:alice` or `anonymous:cookie-a`; empty means no usable identity. The prefix prevents a user ID and an anonymous ID with the same text from colliding. Do not join raw user_id and anonymous_id values directly.

`kansoku-core/src/Kansoku/Metrics/Query/Session.hs` defines `sessionProjection` and `materializedSessionProjection`. A session is all retained canonical web events sharing account/source_service/nonempty session_id. Assemble that full session before applying dates or filters. Its start is the earliest retained event; its attribution is the earliest page_view, falling back to the earliest event, ordered by occurrence timestamp then event ID. Its primary subject is its first resolved user subject, otherwise its earliest anonymous subject. Its bot flag is true if any constituent event is a bot. The canonical projection provides the identity-aware session population; materialized session state alone cannot supply current resolved identities.

`kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` supplies `resolveSessionDimension`, including channel, referrer_host, UTM fields, entry_page, exit_page, and existing compatible dimensions. `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` supplies `mkSqlName`: 1..128 ASCII characters drawn from lowercase letters, digits, underscore, dot, colon, and hyphen. `kansoku-core/src/Kansoku/Metrics/Query/Traits.hs` joins current traits after session assembly. Reuse these resolution and validation paths rather than building another interpretation of acquisition fields.

`runSQLWith` acquires the shared identity snapshot when SQL refers to `analytics.events_resolved_http`, using identity bounds in `accountParameter`. It also enforces the native work limits and request deadline. Acquisition supplies the existing retained identity scope to avoid losing pre-range session facts. The final `boundedSQL BucketDimensions` wrapper transfers at most 10,001 rows: 10,000 succeeds and the extra row produces a complete-or-error rejection. Keep the existing three-column native result decoder, ordering repair, and nullable group representation.

Tests live in `kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs`, `kansoku-core/test/Kansoku/QuerySpec.hs`, `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs`, `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`, and `kansoku-core/test/Kansoku/OpenApiSpec.hs`. Existing session and trait regressions are in `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs` and `kansoku-core/test/Kansoku/Metrics/TraitsSpec.hs`. `scripts/enrichment_acceptance.py` exercises public ingest/acquisition and is called by `scripts/acceptance.py`. `scripts/isolated_clickhouse.py` owns disposable native instances; `scripts/test_support.py` rejects zero-example, failing, or pending required tests. Run commands through the repository's Nix development environment and `justfile` build targets.

Relevant decisions consulted are [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which requires canonical deduplication, shared identity projection, and typed parameterized selection; [ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md), which defines conservative account-scoped identity resolution and alias evidence; [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md), which requires bounded complete results and storage-free input rejection; [ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md), which defines immutable enrichment and acquisition attribution; and [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md), which requires whole-session selection and replay-safe retained facts. This plan adds first-session-per-person selection for the new measures without replacing those existing session contracts.


## Plan of Work


### Milestone 1: Implement and prove the native first-session population


Extend `AcquisitionMeasure` in `kansoku-api/src/Kansoku/Metrics/Api.hs` with `AcquisitionConvertedUsers` and `AcquisitionConversionRate`, including their URL parsing/rendering. Add the public limit `maxAcquisitionConversionEvents = 20` in `kansoku-api/src/Kansoku/Metrics/Limits.hs`. Add a pure validator in `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` that checks the raw supplied list's size, validates every name with `mkSqlName`, and then removes duplicates. Duplicate names have OR semantics, not repeated conversion counts. Reject empty elements; do not silently discard them. Well-formed names need not be registered events because matching event names does not depend on property declarations.

Keep existing `runAcquisition` and `buildAcquisitionSQL` entry points as wrappers with no supplied conversion list. Add `runAcquisitionWithConversions` and `buildAcquisitionSQLWithConversions` taking an explicit `Maybe [Text]` after the measure and before `QueryRequest`. This distinguishes a missing list from a present empty one, keeps conversion options local to acquisition, and avoids adding fields to every `QueryRequest` constructor. Both new measures require a present valid list; old measures reject a supplied list rather than ignore it. Validate before any query-pool acquisition. The old wrappers return a normal input error if passed a new measure without conversion names. Route all variants through shared compiler validation so native callers cannot bypass the bounds.

Build the new SQL path in `kansoku-core/src/Kansoku/Metrics/Query.hs`, extracting a focused acquisition helper module only if it improves clarity. First assemble resolved retained sessions with `sessionProjection (rawResolvedSource (retainedScope req)) True` and apply the same trait joins, account predicate, half-open session-start range, bot exclusion, and session filters as `users`. Exclude empty primary subjects. Then select exactly one row per primary subject with the minimum tuple `(session_start_at, source_service, session_id)`. The latter two fields make ties deterministic across distinct session keys. Carry the entire chosen row's attribution together; do not take independent minima of individual dimensions or group before choosing the row. Only then project grouping and the selected start's UTC time bucket.

Separately read canonical resolved conversion facts for the authenticated account with event occurrence in `[from,to)`, any listed event name, nonempty canonical subject, and the selected bot policy. This scan includes web, service, and other supported sources and does not require a session ID. Session filters, source-service filters, channel filters, and property-selection scope must not leak into this scan. Use the same retained identity snapshot as the session branch, with explicit request-time predicates on conversion facts. Bind event names through `namedParameters`/`eventNamePredicate` using a distinct `acquisition_conversion_event` prefix; never interpolate caller strings.

Reduce conversion facts to one row per canonical subject containing the latest eligible occurrence timestamp and an explicit match marker. Left-join this reduced relation onto the one-row-per-person selected population. A person is converted if the marker is present and latest conversion time is greater than or equal to their chosen session start, and still strictly less than `to`. The range filter ensures the latter. An explicit marker avoids treating the default timestamp of an unmatched ClickHouse join as a conversion. Counting people after this reduction prevents join multiplication and replay inflation. Sum converted flags for `converted_users`; divide by the number of selected people in the exact same bucket/group for `conversion_rate`, using a zero guard and a Float64 result. Rates are fractions in [0,1]. Existing population groups with no matching conversions return zero; absent groups produce no points, matching acquisition's existing sparse response.

Start native acceptance with an anonymous organic visit, alias evidence, and a later service-side `signup_completed` under the known user ID, plus an unconverted organic person and a converted email person. Exercise both new entry points through the real query pool, not only SQL string assertions. This early test must prove that the session and event branches share compatible canonical identities and that native SQL compilation/join defaults work. Keep the established snapshot and decoder boundaries if this test exposes a native issue; do not bypass them with an independent identity policy.

Milestone 1 is accepted when the focused native runner described below returns the example counts/rates, duplicate deliveries do not change them, and existing acquisition/session/trait cases still pass.


### Milestone 2: Expose a strict public acquisition contract


Add `QueryParam "conversionEvents" Text` to `AcquisitionQuery` in `kansoku-api/src/Kansoku/Metrics/Api.hs` and add the parameter only to acquisition's allowlist in `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`. It is a single comma-separated scalar parameter; repeating it remains an error. Update `acquisitionHandler` to preserve absence versus presence, split and trim entries without dropping empty entries, validate measure/list combinations before cohort loading or storage, and invoke `runAcquisitionWithConversions`. Keep the existing default measure, authentication, account selection, group validation, date limits, and unsupported parameter behavior.

Use HTTP 400 problem details with code `invalid_conversion_events` for missing, empty, malformed, over-20, or measure-incompatible lists. Repeated or valueless query parameters retain the existing `invalid_query_parameter` code. Expose safe details explaining the permitted combination and bounds. Add conversion validation through the existing query error mapping; never turn malformed input into a storage failure. Test a valid list of exactly 20 raw entries and an invalid list of 21 even if repeated names would normalize below 20. Preserve trim behavior consistently for HTTP and direct compiler callers.

Update route sentinel arity and parameter-forwarding assertions in `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`, and add storage-free failure cases to `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs`. Update `kansoku-api/src/Kansoku/Api/OpenApi.hs` with the new measure enum and route description; regenerate `docs/api/openapi.json`. Check `kansoku-core/test/Kansoku/OpenApiSpec.hs` for the two new enum values and conversionEvents description. Build `kansoku-client` as well as the server so the changed generated Haskell client route is exercised; update in-tree consumers if necessary.

Extend `scripts/enrichment_acceptance.py` with a uniquely prefixed account-local population selected by a source_service session filter. Give its conversion events a different service source, use real alias ingestion, and query the two new measures through authenticated HTTP. Use event names and property bodies already accepted by the registry (for example `signup_completed`); the SQL-level tests can use arbitrary valid names. Invoke this check in the existing `verify_enrichment` flow so `scripts/acceptance.py` exercises it in its owned environments. Assert the explicit expected response rather than only the sum of all rows.

Milestone 2 is accepted when authenticated HTTP returns the Milestone 1 example, malformed requests return documented 400 errors without evaluating storage, legacy requests still work, generated OpenAPI is current, and all local components compile.


### Milestone 3: Lock down boundaries and publish the population rules


Extend `kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs` with the cases in Validation and Acceptance. Keep compiler-only invalid input assertions in `kansoku-core/test/Kansoku/QuerySpec.hs` or the focused acquisition test module, and preserve the owned native runner's non-skipping test audit. Apply both 10,000-point success and 10,001-point overflow to each new measure, not just sessions. No query may truncate the population before final grouping to satisfy the cap.

Update `docs/guides/query-metrics.md` with an acquisition-conversions section, parameter matrix, example requests/responses, selection-before-attribution rules, current retained-history identity behavior, timing boundaries, and the legacy-users denominator distinction. Explain that "first touch" here means first selected session in this requested range, whose attributes themselves come from the session's first page view; it is not the person's lifetime first visit. Explain that narrowing filters may choose a different first session, conversion time does not determine the output bucket, and a ratio must not be summed across buckets. With the current grains, the new converted-user counts can be summed within one fixed query because each person has one assigned bucket, but separate date-window queries choose their own first sessions. Whole-period rates remain dependent on a supported whole-range mode, not averaging daily rates.

Update `docs/adr/0012-server-enrichment-and-first-touch-web-acquisition.md` to distinguish legacy users from the new first-session population and record conversion timing/source/bot policies. Update ADR-9 only if its documented input-limit inventory needs the new list bound; preserve its result and work-limit guarantees. Follow `docs/adr/profile.dhall` and existing generated metadata, preserve ADR handles, update bundle log entries when timestamps advance, and run strict validation. Update guide metadata/log entries according to `docs/guides/profile.dhall` as well. Mark this plan complete only after actual acceptance evidence is recorded, implementation friction is triaged, and durable decisions are distilled.


## Concrete Steps


Run all commands from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. These are implementation commands; they have not been run as acceptance during plan creation. The Nix shell supplies the compiler, native tools, Python, and check tools. Do not inspect or search `/nix/store`, and do not target an ambient database.

Establish the build and deterministic checks, and repeat them at the public-contract milestone:

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just deterministic-test
```

Add `scripts/acquisition-acceptance.py` using the ownership pattern in `scripts/paths-acceptance.py`. Its executable body should use the existing helpers and run the acquisition, session, and trait families in fresh instances, at both normal and tiny block sizes:

```python
from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary, hspec

for block_size in (65536, 2):
    with isolated_clickhouse(block_size=block_size) as env:
        apply_migrations(env)
        for family in ('Kansoku.Acquisition native', 'Kansoku.Sessions native',
                       'Kansoku.Traits native'):
            hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=' + family],
                  env=env, timeout=300)
```

Add `acquisition-acceptance: build-with-tests` to `justfile`, running that script. Acceptance requires a positive example count, zero failures, and zero pending cases from each invocation, including the new conversion examples.

```bash
nix develop --no-write-lock-file -c just acquisition-acceptance
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just openapi-check openapi-lint
```

Before final acceptance, format the changed source with the project's formatter, maintain guide/ADR logs, and run the existing check and owned packaged acceptance targets:

```bash
nix fmt
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just acceptance
```

`just check` must finish with exit status zero, including strict ADR validation. `just acceptance` uses `scripts/acceptance.sh` and the existing packaged fixtures; it must reach its success summary and the new public acquisition-conversion assertion. These scripts own disposable services and require the existing local native/container prerequisites. Missing prerequisites, skipped cases, or zero examples are not acceptance evidence. Record actual results and any environmental blocker rather than weakening the tests. Do not add new unrelated long-running benchmark gates.

For ADR/guide metadata validation after documentation edits:

```bash
nix develop --no-write-lock-file -c dhall type --file docs/adr/profile.dhall
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just guides-check
git diff --check
```

Use Conventional Commit messages for implementation checkpoints with both trailers:

```text
feat(metrics): attribute conversions to first acquisition touch

ExecPlan: docs/plans/56-attribute-conversions-to-first-touch-acquisition.md
Intention: intention_01m6qe212geserbtd72wh0qvaz
```


## Validation and Acceptance


The core fixture uses range `2026-07-01` through exclusive `2026-07-03`, daily buckets, and default grouping by channel. Person A arrives anonymously through organic search on July 1 at 09:00, aliases to user A, and has a service-side `signup_completed` on July 2. Person B arrives through organic search at 10:00 and has no conversion. Person C arrives through email at 11:00 and has a listed conversion later that day. A also returns through email on July 2. Expected converted-user points are July 1 organic_search=1 and email=1; rate points are July 1 organic_search=0.5 and email=1. A's later email session and later conversion date do not create another point. Compare this with unchanged legacy users behavior to prove that its multi-session grouping was not silently altered.

A conversion timestamp equal to the chosen session start counts; one before it does not; one at exclusive `to` does not. A conversion on the following day within the range counts in the selected session's earlier bucket. A session starting before `from` is excluded even if it contains in-range pages. A person may still qualify through a later session starting within the range. Two selected sessions with equal start times choose the lower source_service/session_id tuple regardless of insertion order. Blank session IDs do not produce acquisition population, but blank conversion session IDs are allowed. Empty primary identities are excluded from both denominator and numerator.

Several listed event names are OR-combined and any number of matching occurrences still converts the person once. Immutable replay before background merges leaves the answer unchanged. A well-formed nonexistent event name produces zero counts/rates for existing population groups. A person with no matching conversions must survive the left join. Anonymous and explicit subjects with the same raw identifier text remain distinct unless the established identity policy actually resolves them; ambiguous aliases must not be forced into a known user. Identical IDs in another account cannot affect either branch.

Exercise channel, referrer_host, utm_source, utm_medium, utm_campaign, and entry_page independently, plus one two-dimension request, using attribution values from the chosen session. The conversion event may have missing/referrer/direct or different campaign data without changing those groups. A filter selecting a later eligible session changes ownership to that session; a conversion before that newly selected start no longer qualifies. Repeat representative current-user trait and cohort selection cases using the existing fixtures, ensuring selection governs the population and server conversions still join. Retain current rejection rules for unsupported dimensions/property scopes and for more than two or duplicate group dimensions.

A bot-marked event anywhere in the retained acquisition session excludes that session by default, including a bot event outside the requested time range. It can cause the person's later clean selected session to become first. `includeBots=true` restores the bot session and its timing. A bot-only conversion does not convert an otherwise eligible person by default, but does with `includeBots=true`. Session filters never demand that the conversion event have a matching channel, source service, entry page, or session ID.

HTTP tests cover missing conversionEvents, empty string, leading/trailing comma, empty interior element, invalid characters, overlong names, 20 versus 21 raw entries, repeated conversionEvents parameters, and lists on legacy measures. All return their documented outcomes before storage. Positive requests preserve parameter order independence and trim comma-separated names consistently. One name and multiple names work through the real authenticated API. Existing default sessions and explicit users responses remain unchanged.

Both new measures succeed with exactly 10,000 final population groups, including zero-conversion groups, and reject 10,001 with `metric_result_too_large` and no partial metric response. Native resource-limit behavior continues through the common executor. The focused native runner tests tiny blocks so count/rate values cannot become associated with the wrong bucket/group during decoding. The guide and generated API must match the implementation on denominator, timing, default grain, bot policy, event list grammar, and limits.

If IR-4's whole-range mode exists by implementation time, additionally run this same multi-day fixture in that mode and require null buckets, one first-session attribution per person, and the ratio computed over the same whole-range population. Without that prerequisite, explicitly document the available bucketed behavior rather than claiming an unbucketed rate has shipped.


## Idempotence and Recovery


The feature requires no storage migration, backfill, new identity tables, or session-state rebuild. It reads existing canonical retained facts. Rerunning the owned acceptance scripts creates fresh disposable stores; fixture event IDs and source-service selectors must be unique within each public scenario. Never clean or mutate a developer's shared analytics data to make tests pass. Late evidence, erasure, or retention can change results through the existing identity/session contract, so tests should await the expected ingested facts and identity snapshot instead of assuming immediate publication.

OpenAPI regeneration is repeatable. Keep generator changes and regenerated JSON together, and regenerate after any route edit. If implementation fails partway, keep partial work and failing evidence in Progress and resume at the unfinished milestone. Preserve unrelated working-tree changes. Rollback consists of reverting this feature's code/API/docs together; no persistent data recovery is necessary. Do not remove existing result bounds or native work limits to repair a query failure.


## Interfaces and Dependencies


The wire result remains `MetricResult { metric = "acquisition", points }`, where each point has a nullable text bucket, nullable string-valued group map, and numeric value. No measure field is added to each point; one request selects one measure. Omitting groupBy still means channel, omitting timeGrain still means daily buckets, and omitting includeBots still means false.

The new internal interfaces in `kansoku-core/src/Kansoku/Metrics/Query.hs` are:

```haskell
runAcquisitionWithConversions :: (IOE :> es)
  => EventRegistry -> QueryPool -> AcquisitionMeasure -> Maybe [Text]
  -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)

buildAcquisitionSQLWithConversions :: EventRegistry -> AcquisitionMeasure
  -> Maybe [Text] -> QueryRequest -> Either QueryCompileError Text
```

Represent invalid event-list combinations as an ordinary compile/input error with the public code specified above. The validator in `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` returns validated names for native parameter binding; define the concrete error constructor consistently with the existing QueryCompileError and query error renderer. Both the SQL-builder and executor use the same validation path. Keep `runAcquisition` and `buildAcquisitionSQL` as compatibility wrappers passing `Nothing`.

No dependency version changes are planned. The existing driver is `mori://KovalevDima/ClickHaskell/packages/ClickHaskell`; query documentation was discovered through Mori at `mori://KovalevDima/ClickHaskell/docs/queries`. Follow the repository's existing `aggSelect`, `namedParameters`, and query-pool execution patterns. If implementation reveals a dependency API question, locate its source through `mori registry search`, `mori registry show --full`, and `mori registry docs` before relying on memory. Any proposed version pin or workaround requires checking the authoritative registry and upstream release tags first. IR-4 is the only soft feature dependency; no external SDK or UI repository changes are required for this backend plan.
