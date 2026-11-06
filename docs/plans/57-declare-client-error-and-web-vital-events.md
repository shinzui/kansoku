---
id: 57
slug: declare-client-error-and-web-vital-events
title: "Declare client error and web vital events"
kind: exec-plan
created_at: 2026-11-06T03:41:41Z
intention: "intention_01m6qf2482enbtg9rjf07zdvt7"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T03:41:41Z
---

# Declare client error and web vital events

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and `agents/skills/exec-plan/ADR.md` for durable architecture decisions.

## Purpose / Big Picture


Implement [IR-8](../improvement-requests/declare-client-error-and-web-vital-events.md): producers share validated `client_error` v1 and `web_vital` v1 contracts, and report authors can count errors by page and message, count affected users, and show the 75th percentile of each page-performance metric by page. A percentile summarizes an ordered set of measurements; p75 is the value at quantile 0.75. The event catalog, ingestion behavior, and documented queries must agree, demonstrated through the public HTTP API against owned test databases.

This work declares the server contracts and records an opt-in browser SDK capture follow-up. It does not implement browser capture, a dashboard, stack trace storage, source maps, issue grouping, alerts, session replay, rage clicks, or failed-request capture. Creating this plan does not implement these milestones.

## Progress


- [ ] Milestone 1: Published v1 contracts and ingestion enforce bounded error fields, the closed vital vocabulary, and nonnegative values while preserving existing event schemas.
- [ ] Milestone 2: Public report queries return independently calculated error counts, affected-user counts, and per-metric/per-route p75 values from accepted fixture events.
- [ ] Milestone 3: Sending/reporting documentation, generated contracts, durable contract decisions, and a linked opt-in SDK follow-up are complete and validated.

## Surprises & Discoveries


## Decision Log


Decision (2026-11-05): Require `message`, `type`, and `handled` on `client_error` v1. Bound message to 1–256 Unicode code points and type to 1–128. These are short sanitized report labels, not arbitrary exception dumps. A 256-code-point message fits the existing 1024-byte UTF-8 filter operand limit, so every accepted label remains usable as an equality filter. Producers normalize or truncate before submission; the server rejects violations instead of silently changing payloads.

Decision (2026-11-05): Publish bounded strings using optional `minLength`/`maxLength` constraints, and the vital vocabulary as the regular expression `^(LCP|INP|CLS|FCP|TTFB)$`. Add `maxLength` to the catalog property representation and advance its document version from 4 to 5, assuming no intervening catalog change. Existing event versions remain immutable.

Decision (2026-11-05): Treat percentile support from plan 55 as a prerequisite for report acceptance, not work to reimplement here. Registry publication can proceed independently; milestone 2 and overall completion require that dependency's public percentile contract to be implemented and verified.

Decision (2026-11-05): Keep current session engagement classification in this declaration-only change. These names currently fall under the generic engagement rule, so automatically collecting them can affect bounce and duration reports. State that consequence in the guide and SDK follow-up. Changing retained session semantics would require separate migration/rebuild work and an explicit scope decision.

## Outcomes & Retrospective


## Context and Orientation


The source request is `docs/improvement-requests/declare-client-error-and-web-vital-events.md`, handle IR-8. Its hard dependency IR-7 is planned in [plan 55](55-add-percentile-aggregation-to-custom-metrics.md), `docs/plans/55-add-percentile-aggregation-to-custom-metrics.md`. At plan creation, that work is unfinished and `GET /metrics/custom` does not yet accept percentile aggregation. Plan 55 specifies `aggregation=percentile`, `property=value`, and `quantile=0.75`, with exact inclusive interpolation: sorted samples 10, 20, 30, 40 yield 32.5. Do not mark this plan complete using average or client-side substitutes.

`kansoku-api/src/Kansoku/Event/Registry.hs` owns `defaultRegistry`, `EventSchema`, `PropertySpec`, and the closed Haskell `PropertyPattern` type. Neither requested event is declared. Existing patterns cover SQL-style names, nonempty strings, nonnegative numbers and nonnegative integers; they cannot currently express bounded free text or vital names. `kansoku-api/src/Kansoku/Event/Validation.hs` enforces those patterns in `propertyPatternMatches` after checking JSON types. Unknown names and undeclared extra properties remain permissive. Omitted `schemaVersion` means version 1; a declared name with an unavailable version fails validation.

`kansoku-api/src/Kansoku/Event/Contract.hs` converts the registry to `SchemaCatalog` and `ContractProperty`. Catalog version 4 currently publishes optional `pattern`, `minimum`, `minLength`, and `multipleOf`; it has no `maxLength`. Numeric predicates are published as numeric constraints, not regular expressions. `docs/contracts/events.json` and public `GET /v1/schemas` expose the same catalog. `kansoku-api/src/Kansoku/Api/OpenApi.hs` derives the catalog's public schema, with field-name mappings for `type` and `pattern`; regenerate `docs/api/openapi.json` when the catalog property type changes.

`kansoku-core/test/Kansoku/ContractSpec.hs` contains the registry/artifact golden comparison, metadata invariants, and catalog roundtrip tests. `kansoku-core/test/Kansoku/EventSpec.hs` tests schema validation. `kansoku-core/test/Kansoku/Ingest/HandlerSpec.hs` covers batch partitioning. `kansoku-core/src/Kansoku/Metrics/Query/Property.hs` governs which declared scalar properties can be grouped or filtered. A scalar is one string, number, or Boolean rather than an object or array. Declaring `message` and `metric` is what makes `prop:message` and `prop:metric` queryable without a new database column.

Relevant consulted decisions are [ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md), which requires immutable contiguous event versions and synchronized catalog publication; [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which owns typed declared-property queries and canonical events, meaning one accepted fact per event ID; [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md), which keeps custom metrics on shared filtering, grouping and account-isolation rules; [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), which requires owned disposable services for native acceptance; and [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md), which defines sessions and their engagement classification. Top-level `url` supplies the event route, and top-level `sessionId` associates a web event with its session. That association does not make session-only entry/exit dimensions available on arbitrary event queries.

`scripts/custom_metrics_acceptance.py` already sends public events, checks custom metrics, and runs on owned PostgreSQL/ClickHouse services through `scripts/cohorts_acceptance.py`. `scripts/acceptance.py` also imports its scenario for packaged acceptance. Reuse this integration point without changing saved-definition pagination expectations. `scripts/enrichment_acceptance.py` provides the `event`, `send`, and `eventually` helpers. Existing event fixtures include defaults; explicitly replace properties and URL for the new events.

Mori discovery locates the browser packages at `mori://shinzui/kansoku-ts/packages/kansoku-js` and `mori://shinzui/kansoku-ts/packages/kansoku-react`. The current SDK automatically captures page views/session starts and has no error/vital capture. Its privacy and delivery guide is `mori://shinzui/kansoku-ts/docs/delivery-and-privacy`. Work is currently tracked in numbered ExecPlans; its manifest has no improvement-request bundle. Use its local exec-plan skill to record the SDK follow-up during milestone 3, without implementing that follow-up here.

## Plan of Work


### Milestone 1: Declare and enforce the contracts


Extend `PropertyPattern` in `kansoku-api/src/Kansoku/Event/Registry.hs` with `BoundedStringPattern Int` and `WebVitalMetricPattern`. Define the former as nonempty text of at most the supplied number of Unicode code points; implement it using the existing text operations in `kansoku-api/src/Kansoku/Event/Validation.hs`. The latter accepts exactly the five uppercase names by equality membership. Its published pattern is `^(LCP|INP|CLS|FCP|TTFB)$`. Do not add a runtime regex dependency or change any existing pattern's behavior.

Declare `client_error` version 1 with required `message :: string` bounded to 256, required `type :: string` bounded to 128, and required `handled :: bool`. Describe `type` as a sanitized error class/category such as `TypeError` or `UnhandledRejection`; `handled=false` denotes an uncaught error or unhandled rejection, while explicit application reports may set true. The schema note and property descriptions must say not to send stack traces or personal data. This is producer guidance, not a server content-redaction guarantee: arbitrary extra properties are still accepted under the existing permissive policy.

Declare `web_vital` version 1 with required `metric :: string` using `WebVitalMetricPattern` and required `value :: number` using the existing `NonNegativeNumberPattern`. Define LCP (Largest Contentful Paint), INP (Interaction to Next Paint), CLS (Cumulative Layout Shift), FCP (First Contentful Paint), and TTFB (Time to First Byte) in descriptions or the guide. All values are milliseconds except CLS, which is unitless. CLS is not capped at one; zero is valid for every metric. There is no independently supplied unit field. This contract establishes names and units, not a browser measurement algorithm.

Both producers use the normal event envelope, `source=web`, top-level `url`, nonempty `sessionId`, source-service identifier, and available user/anonymous identity. Do not duplicate URL/session into new properties or add event-specific top-level requirements. Show these fields in examples so routes and sessions are useful; absent URL/session retain the existing generic behavior.

Add `maxLength :: Maybe Int` to `ContractProperty` in `kansoku-api/src/Kansoku/Event/Contract.hs`, omitted from JSON when absent and accepted as absent when decoding old catalogs. Map bounded strings to `minLength=1` and their maximum, the vital constraint to `pattern`, and the existing nonnegative constraint to `minimum=0`. Update all affected constructors and exhaustive matches. Advance `catalogVersion` for this shape addition and regenerate both artifacts. Add catalog assertions for exact fields, units, requiredness, and privacy descriptions, plus a legacy property payload decoding without `maxLength`.

Exercise valid error payloads at each length boundary, multi-byte Unicode and supplementary-plane characters, empty/oversized strings, missing/wrong-type fields, and Boolean false/true. For vitals, test every allowed name, zero, fractional CLS, CLS greater than one, negative numbers, null/string values, missing fields, lowercase/unknown names, and extra prefixes/suffixes or trailing newline. Preserve omitted-version behavior, unavailable-version rejection and undeclared-event acceptance. In batch tests, show invalid vitals rejected by index while valid siblings remain accepted. The golden contract and deterministic suites must pass; public ingestion acceptance is completed with milestone 2's fixture.

### Milestone 2: Prove the report queries


Before requiring percentile assertions, verify plan 55's implementation and passing public acceptance evidence. If it is still absent, keep this milestone unchecked and record the dependency; do not duplicate its compiler change. Once available, add `scripts/site_health_scenario.py` with `verify_site_health(base, write_key, token, other_token)` and invoke it from `verify_custom_metrics` in `scripts/custom_metrics_acceptance.py`. This makes both the standalone custom gate and packaged gate execute the proof. Use a unique source-service prefix, event IDs, sessions, and subject IDs per invocation so repeated scenarios do not collide. No saved resources are needed.

Start with one valid `web_vital` event sent through public ingestion and verify its route/metric group and percentile value. This proves the new registry declaration, numeric extraction, prerequisite aggregation, and native result decoding work together before expanding fixtures. Send an unknown metric through `POST /v1/events` and assert HTTP 400 `validation_failed`; send a mixed batch and assert HTTP 202 with the invalid index rejected and the valid sibling accepted. Use separate source prefixes for rejection checks to keep report populations exact.

For the main fixture on 2026-07-01, emit three error events at `/checkout`: two `TypeError` messages from user A and one `UnhandledRejection` message from user B. Emit one `TypeError` message at `/pricing` from user A. Use the same sanitized message label for the three TypeError occurrences, for example `Cannot read property`. Affected users are therefore 2 globally, 2 at checkout, and 1 at pricing; counts are 4 globally, 3 at checkout, and 1 at pricing; message counts are 3 and 1. Also put a non-error activity event in the fixture to prove the error filter excludes it. Use explicit user IDs for this report proof rather than introducing new identity-resolution semantics.

For each of LCP, INP, FCP and TTFB, emit four distinct page-view measurements at `/checkout` with values 10,20,30,40 and at `/pricing` with 100,200,300,400. CLS uses 0.01,0.02,0.03,0.04 at checkout and 0.1,0.2,0.3,0.4 at pricing. Each measurement has a unique event ID, an appropriate URL and session, and a matching page_view fixture; metrics for one view may share that view's session. Expected p75 values are 32.5/325 milliseconds and 0.0325/0.325 unitless. On 2026-07-02 use one measurement of each metric per route, values 50 milliseconds or 0.05 CLS, so daily grouping and singleton behavior are visible. Query both days and assert exact bucket/group keys and values with numeric tolerance 1e-9; never sum or average percentile points to establish correctness.

Replay the same accepted events and verify counts and p75 remain unchanged. Send matching extreme values and errors to the foreign account and verify no influence on the first account's results. Wait for the expected stored population using bounded `eventually` assertions before comparing results. Pair the percentile request with a count request using identical dates, source filter, groups and `prop:value:set`, expecting four samples per group on day one and one on day two. Do not sum affected-user counts across routes or days, since the same user can appear in several groups. Native acceptance must execute assertions with no skipped prerequisite.

### Milestone 3: Publish recipes and record browser work


Extend `docs/guides/send-events.md` with complete JSON examples for both new events, constraints, units, privacy instructions, and the authenticated query recipes below. Explain that no capture starts merely because the server declares these names. Link the metrics guide for time buckets, exact resolved-user semantics, filter limits, and percentile behavior. Keep `docs/event-schema-governance.md` current with catalog version 5 and `maxLength`; update ADR-7 with the new publication shape and immutable event contracts, keeping the plan's decisions self-contained. Maintain the guide/ADR bundle metadata and logs with repository tooling.

Record the SDK follow-up in `mori://shinzui/kansoku-ts` using its existing numbered ExecPlan convention and bundled initializer. First resolve that checkout with Mori and read its local skill/instructions. Reuse an existing equivalent follow-up if another contributor has created one. Otherwise create an unimplemented plan titled “Capture client errors and web vitals with explicit opt-in,” using the current implementer's verified model and this plan's Intention ID. Link its canonical plan URI here after allocation. The SDK document must cite both `mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-8` and `mori://shinzui/kansoku/plans/57-declare-client-error-and-web-vital-events`; do not use bare cross-repository paths.

The follow-up must cover independent opt-in capture flags disabled by default; uncaught errors and unhandled promise rejections with `handled=false`; bounded sanitized message/type values; no stack traces or personal data; deduplication and finite per-page/time rate limits; and the five supported vital names with correct units. Require at most one final event per metric per page view, with a documented policy for finalization, client-side navigation and unsupported browser measurements. It must preserve page URL/session attribution, shared queue/retries and event IDs, privacy suppression and `beforeSend`, listener teardown/restart behavior, and browser-global-free module import. Repeated callbacks and React lifecycle restarts must not duplicate reports. Record the current session-engagement consequence and require a deliberate decision before enabling automatic capture in a product. The follow-up is a planning deliverable, not completed browser functionality.

Run final checks, record their evidence, distill durable decisions into ADR-7, triage implementation friction, and fill the retrospective. Mark IR-8 delivered only when all four acceptance criteria below hold, including the actual SDK follow-up artifact.

## Concrete Steps


Run server commands from the Kansoku repository root with Nix, Bun and repository tools installed. Deterministic checks need no ambient database. Native acceptance starts and stops its own PostgreSQL and ClickHouse services; do not point it at development/production stores.

```bash
nix develop -c just contracts
nix develop -c just openapi
nix develop -c just build-with-tests
nix develop -c just deterministic-test
```

After plan 55 is implemented, run the public report proof:

```bash
nix develop -c just custom-metrics-acceptance
```

The scenario must exit zero after checking real accepted events and all expected points. Missing percentile support is a failed prerequisite, not a reason to skip assertions. For the completed candidate, format changed sources and run:

```bash
nix fmt
nix develop -c just check
nix develop -c just acceptance
git diff --check
```

`just check` includes generated-artifact drift, deterministic tests, API schema lint, and guide/ADR validation. The packaged acceptance gate must include the new scenario through `verify_custom_metrics`. Record concise evidence and preserve unrelated working-tree edits. Implementation commits use Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/57-declare-client-error-and-web-vital-events.md
Intention: intention_01m6qf2482enbtg9rjf07zdvt7
```

In an SDK commit, use its own local plan path for the ExecPlan trailer and the same Intention; use canonical Mori references for any mention of this repository's artifacts.

## Validation and Acceptance


IR-8 AC-1 passes when both the generated artifact and public catalog declare error v1 with required bounded strings, a required Boolean, and the privacy description; boundary tests prove enforcement and existing schemas are unchanged. AC-2 passes when the vital catalog publishes the exact regular expression, required numeric `value` with `minimum=0`, and metric-specific units, and public ingestion rejects an unknown metric name.

AC-3 passes when the following recipes run against milestone 2's fixture and return its expected results. Set `BASE_URL` to the owned server origin, `TOKEN` to its service token (never a browser-bundled credential), and `SOURCE` to the fixture's unique source-service value. The guide can use application-specific values for ordinary usage. Date bounds are inclusive `from` and exclusive `to` in UTC. Use URL encoding for all filters.

```bash
curl --get "$BASE_URL/metrics/events" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-07-03 \
  --data-urlencode timeGrain=day --data-urlencode groupBy=route \
  --data-urlencode 'filter=event_name:eq:client_error' \
  --data-urlencode "filter=source_service:eq:$SOURCE"

curl --get "$BASE_URL/metrics/events" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-07-03 \
  --data-urlencode timeGrain=day --data-urlencode groupBy=prop:message \
  --data-urlencode 'filter=event_name:eq:client_error' \
  --data-urlencode "filter=source_service:eq:$SOURCE"

curl --get "$BASE_URL/metrics/users" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-07-03 \
  --data-urlencode timeGrain=day --data-urlencode includeBots=true \
  --data-urlencode 'filter=event_name:eq:client_error' \
  --data-urlencode "filter=source_service:eq:$SOURCE"

curl --get "$BASE_URL/metrics/custom" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-07-03 \
  --data-urlencode events=web_vital --data-urlencode aggregation=percentile \
  --data-urlencode property=value --data-urlencode quantile=0.75 \
  --data-urlencode timeGrain=day --data-urlencode groupBy=prop:metric,route \
  --data-urlencode 'filter=prop:value:set' \
  --data-urlencode "filter=source_service:eq:$SOURCE"
```

Add `groupBy=route` to the users recipe to obtain affected users per page. Users means resolved user or anonymous subjects; missing identities do not count. `includeBots=true` explicitly aligns this report's population with the all-event error counts; document how to select a different bot policy consistently. The first two recipes can also use `groupBy=route,prop:message` for a two-dimensional breakdown. For p75 sample counts, repeat the custom recipe with `aggregation=count`, removing `property` and `quantile`, retaining the set filter and both groups. Add `filter=prop:metric:eq:LCP` to select only LCP for a slow-page report. Do not combine CLS with millisecond values or average page/bucket percentiles.

The scenario executes these parameter sets through its HTTP helper and compares results to explicit expected maps. It also checks typed property filtering, for example `prop:handled:eq:false` and `prop:metric:eq:LCP`, and the same-message error equality filter. The guide must describe unsupported/missing measurements as absent samples, not zero-valued performance. Existing bounded-result errors remain errors rather than silently truncated report groups.

AC-4 passes when an unimplemented SDK capture plan actually exists in the SDK checkout, includes the requirements in milestone 3, and links back to IR-8 using its canonical URI. Record the allocated canonical follow-up URI and verify it with `mori path` when supported. A link to this server plan alone does not satisfy AC-4.

## Idempotence and Recovery


Generators and checks are repeatable. Regenerate artifacts from Haskell source rather than hand-editing JSON, and inspect diffs so unrelated edits remain intact. No database migration or backfill is required for these new event declarations. Historical events under these formerly undeclared names can contain incompatible properties; existing typed extraction treats incompatible scalar values as missing. Do not claim retroactive sanitation or validation, and scope fixtures to new, valid accepted events.

Declaring a formerly permissive name tightens validation for new submissions, including versionless ones. Coordinate producers around the published v1 shape. Server validation does not truncate data or erase prior rows. Retry owned acceptance in a fresh harness after fixing failures; do not reset ambient stores. Follow-up creation uses the SDK initializer and must check for an existing equivalent artifact before allocating another. If percentile support remains unavailable, leave milestone 2 and overall completion open while retaining verified registry/documentation progress.

## Interfaces and Dependencies


The new public event contracts are `client_error` v1 (`message`, `type`, `handled`) and `web_vital` v1 (`metric`, `value`). The catalog adds optional `maxLength` and advances its document version; the normal event envelope and metrics result shape remain unchanged. Haskell changes are limited to registry/pattern validation, catalog publication and their tests, with documentation and acceptance integration alongside them. Reuse the existing numeric validation and property extraction rather than adding storage columns or a parallel reporting endpoint.

Plan 55 supplies percentile compilation and public query syntax; there is no parent MasterPlan. The browser SDK follow-up depends on the final published event artifact, and capture implementation stays in that separate plan. No new library, version bound, pin, or compatibility workaround is selected. If implementation discovers a dependency change is necessary, first locate source/docs through Mori and verify released versions against the authoritative registry and upstream tags before selecting it.
