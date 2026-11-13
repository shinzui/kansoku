---
id: 71
slug: filter-a-user-s-event-history-by-site
title: "Filter a user's event history by site"
kind: exec-plan
created_at: 2026-11-13T14:05:41Z
intention: "intention_01m7akmvr7ejes4hjc4jac1x33"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-11-13T14:05:41Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T14:50:45Z
      mode: "implement"
      note: "Implement canonical host history filters, exact host facets, and public acceptance coverage"
---

# Filter a user's event history by site

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture


One identified user often produces events on several websites that report to the same Kansoku
account, for example a marketing site, an application and a documentation site. Today
`GET /users/{userId}/events` (the resolved per-user event history) can narrow that history only
by event name and date range, so a consumer that wants "this user's activity on
`app.example.com`" must page through everything and filter client-side, and cannot show a
correct total.

After this change a consumer can:

1. Add a `host` filter term to `GET /users/{userId}/events`, with `eq` (one site) or `in`
   (several sites), alone or together with the existing `event_name` term. The two terms are
   ANDed. Relay pages, `hasNextPage`/`hasPreviousPage` and cursors then walk only the matching
   events.
2. Call a new `GET /users/{userId}/hosts` that lists every site the user has history on, with
   an exact event count per site (plus one entry for events that have no site), using the same
   date, bot and event-name selection as the history endpoint. A site picker can be built from
   it without guessing, and the sum of the selected entries' counts is the exact total of the
   filtered history, so a "Showing N of M events" summary stays correct under any combination
   of site, event-name and date selection.

The motivating adopter is the user profile page of
`mori://shinzui/kansoku-ui` (its Event history card in
`apps/web/src/features/users/profile/history.tsx`), which will add a "Site: All sites" control
beside its existing Events filter. That UI work is planned separately in kansoku-ui; this plan
delivers only the Kansoku API half, framed as a generic capability for any consumer.

To see it working: ingest events for one user on two hosts plus one server-side event without a
URL, then

```bash
curl -H "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" --get "$KANSOKU_URL/users/alice/hosts"
curl -H "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" --get "$KANSOKU_URL/users/alice/events" \
  --data-urlencode 'filter={"dimension":"host","op":"eq","value":"app.example"}'
```

The first returns the two hosts and a `null` host with their counts; the second returns only
`app.example` events, and its edge count over all pages equals the `app.example` count from the
first.


## Progress


- [x] Milestone 1 (2026-11-13): `GET /users/{userId}/events` accepts one `host` eq/in term alongside one
  `event_name` term; pages, both cursor directions and node `host` agree; invalid host terms
  return 400 `invalid_users_query`; unit tests and `just users-acceptance` pass. Native
  evidence: `.dev/acceptance/cohort-b603v6fh`, including trailing dots and ports, AND selection
  and both filtered cursor directions.
- [x] Milestone 2 (2026-11-13): `GET /users/{userId}/hosts` returns a complete, exactly counted host list
  under the history selection, with `user_not_found` 404 and a bounded-result error; the
  regenerated OpenAPI document and schema tests pass. Native acceptance proves exactly
  1000 entries succeeds, 1001 (including null) returns `user_hosts_too_large` without output,
  and query-memory exhaustion returns 503 on all five user routes. Code and generated
  OpenAPI are committed at this milestone boundary.
- [ ] Milestone 3: Endpoint Descriptions, `docs/guides/query-metrics.md` and ADR-25 publish the
  contract; `just check` passes and the users acceptance workflow proves the counted-total
  invariant end to end.


## Surprises & Discoveries


The shared MetricFilter parser rejects malformed operands (including 101-value arrays)
before users-specific validation. History and hosts parse failures therefore use
`invalid_users_query` in request middleware too; direct handler calls independently validate
selection before accessing a database.

ClickHouse 26.8.28.14's `domain()` returns an empty string for a trailing-dot authority,
so the original canonical-domain expression did not satisfy its stated contract. The native
fixture returned `host:null` for `https://APP.example./b`, and a direct `clickhouse-local`
query confirmed it. `canonicalDomain` now removes trailing dots from the URL authority
before parsing, preserving ports and path/query text. The shared query expression (including
metric host grouping) is corrected; stored URLs and enrichment classifications are unchanged.
The HTTP fixture covers both a trailing-dot host and a trailing dot before a port.

The existing users acceptance harness owns qualified macOS-native ClickHouse and PostgreSQL
processes, rather than containers. This execution retains that native coverage boundary;
no Linux or container behavior is claimed.


## Decision Log


- Decision: Add a dedicated `GET /users/{userId}/hosts` facet instead of telling consumers to
  use `/metrics/events?groupBy=host&filter=user_id:eq:<id>`.
  Rationale: The metric route already groups one resolved user's events by host (plan 68,
  [docs/plans/68-select-identified-users-in-metric-queries.md](68-select-identified-users-in-metric-queries.md)),
  but it is not the same population as history. It requires `from`/`to` spanning at most 366
  days while history defaults to all retained history, it has no `includeBots` parameter, and
  unknown users yield an empty result rather than `user_not_found`. Counts from it therefore
  cannot serve as the history total. A facet that reuses the history query's source, existence
  check and predicates is exact by construction and small to build.
  Date: 2026-11-13

- Decision: Deliver filtered totals through the facet's per-host counts rather than adding a
  `totalCount` to the history Relay connection.
  Rationale: The shared Relay connection type (`Relay.Pagination`) and every Relay page in
  Kansoku carry no total; adding one would change a shared wire shape and add a counting scan to
  every page request. The facet is requested once per selection change, and summing the
  selected hosts' `eventCount` (or all entries when no host is selected) yields the exact total
  for the same dates, bots and event names. Cursors need no change: the host predicate sits in
  the same `WHERE` clause as the keyset boundary, so `LIMIT n+1` and the boundary already
  respect it.
  Date: 2026-11-13

- Decision: `host` accepts only `eq` and `in`, matches only non-null canonical hosts, and values
  must already be canonical (lowercase, no trailing dot, no port, scheme or path). Events with
  no host (server-side events, events without a URL) are excluded whenever a host term is
  present; the facet reports them as one `host: null` entry so totals stay honest.
  Rationale: Rejecting non-canonical input with a message is better than silently matching
  nothing. `neq`, `unset` and OR would need a broader history grammar than the requested
  "narrow to one or several sites"; they remain rejected and can be added later without
  breaking the contract.
  Date: 2026-11-13

- Decision: Normalize authority trailing dots before calling ClickHouse `domain()` in the
  shared canonical-domain helper, rather than removing them only after parsing.
  Rationale: Native acceptance proves the existing expression loses such hosts entirely.
  Correcting the shared helper is required to meet the existing canonical-host acceptance
  criterion and keeps history, filters, facets and metric grouping consistent. It changes
  query-time extraction only, without rewriting URLs or stored enrichment.
  Date: 2026-11-13

- Decision: Bound `in` to 1..100 values (counted before deduplication) and each value to
  1..253 characters, mirroring the event-name bound of 1..100 names.
  Rationale: Symmetry with the existing history term; 253 is the DNS maximum host length.
  Date: 2026-11-13


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


Kansoku is a Haskell analytics service. Events are stored in ClickHouse; HTTP routes are Servant
records. The pieces this plan touches:

The route types live in `kansoku-api/src/Kansoku/Users/Api.hs`. The record `Users` now has five
fields: `activityCounts`, `hosts` (the counted history facet), `events` (the history route
`GET /users/{userId}/events`), `getProfile` (`GET /users/{userId}`) and `directory`
(`GET /users`). Each field carries a `Description "..."` string that becomes the operation
description in the generated OpenAPI document `docs/api/openapi.json`. Wire types such as
`UserEvent` (with a nullable `host`) live in `kansoku-api/src/Kansoku/Users/Types.hs`. The
OpenAPI document is built by `kansoku-api/src/Kansoku/Api/OpenApi.hs`, regenerated with
`just openapi` and checked with `just openapi-check`; `kansoku-core/test/Kansoku/OpenApiSpec.hs`
pins details of the users operations.

The handlers live in `kansoku-core/src/Kansoku/Users/Handler.hs` (`usersServer`). The `events`
handler decodes the Relay cursor with `History.historyBoundary`, then calls `History.history`.
`kansoku-core/src/Kansoku/Users/History.hs` builds the history SQL: it discovers the account's
retained date bounds (`retainedBounds` in `kansoku-core/src/Kansoku/Users/Query.hs`), shares its
source and selection scope with the hosts facet through `withHistoryScope`, opens an
identity-prepared query connection, checks that the user exists (any retained resolved fact
with `subject_kind='user'` and that `subject_id`), compiles request filters with
`QF.compileMetricFilters E.defaultRegistry [] filters` from
`kansoku-core/src/Kansoku/Metrics/Query/Filter.hs`, and selects rows ordered by occurrence,
receipt and event ID descending with `LIMIT pageSize+1`. The node's `host` uses `canonicalDomain "url"`.

A "filter term" is a JSON object `{"dimension":..., "op":..., "value":...}` parsed by
`Kansoku.Metrics.Filter` (`MetricFilter`); the request repeats `filter=` once per term and terms
are ANDed. The filter compiler already understands the dimension `host`: `resolveDimension` in
`kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` maps it to `GroupByHost`, whose SQL
expression is `canonicalDomain "url"`, defined there as
`nullIf(replaceRegexpOne(lowerUTF8(domain(normalized-url)), '[.]+$', ''), '')`, where the
URL authority loses trailing dots before parsing. This is the same canonical host as the
history node projection (lowercased, port and trailing dots removed,
empty becomes null). `canonicalDomain` is now exported from that module and reused by history
and the facet. `eq` compiles
to `coalesce((expr = {p}), false)` and `in` to `coalesce(expr IN (...), false)`, so a null host
never matches.

Request validation happens before the handler. `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`
whitelists query parameters per path in `allowedParameters` (the history path is
`["users", _, "events"]`) and, for that path, runs `validateDates lo hi >> validateHistory filters`
and maps a `Left message` to a 400 problem with code `invalid_users_query`. `validateHistory` in
`kansoku-core/src/Kansoku/Users/Validation.hs` allows one `event_name` and one canonical
`host` eq/in term; `validateHostFacet` permits only the event-name selection.
Its unit tests are in `kansoku-core/test/Kansoku/Users/HandlerSpec.hs` (the `Users request bounds`
spec).

The public behaviour is proven by `scripts/users_acceptance.py` (run with `just users-acceptance`),
which owns disposable native ClickHouse/PostgreSQL stores, ingests fixture events with the helper
`event()` from `scripts/enrichment_acceptance.py` (every fixture event defaults to
`url='https://shop.example/entry'`; history fixtures override it for multiple hosts and missing
URLs), and asserts history pages, both cursor directions, exact facet totals and filter errors. Per `AGENTS.md`, local container execution uses
Apple Container (`container`), never Colima. The consumer-facing guide section
"Identified users, profiles and history" is in `docs/guides/query-metrics.md`.

Relevant ADRs. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md)
owns the users resources: account scope from the principal, existence from retained resolved
user facts (unknown, foreign and erased users share `user_not_found` 404), whole-retained-history
discovery when dates are absent, complete keyset cursors in both directions without a
cross-request snapshot, and "exhaustion returns an error without partial output". This plan
extends that ADR's history contract and adds the hosts facet to its resource list.
[ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) establishes that aggregate answers
are complete or fail with a permanent problem instead of being truncated; the facet follows that
rule. [ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md) owns server
enrichment of URLs into hosts; this plan reuses its canonical host expression and does not change
enrichment. No other ADR is relevant.


## Plan of Work


### Milestone 1: host term on the history route

At the end of this milestone `GET /users/{userId}/events` accepts up to two filter terms, at most
one `event_name` term and at most one `host` term, and the history query applies both.

In `kansoku-core/src/Kansoku/Users/Validation.hs`, rewrite `validateHistory` so that: every term is
atomic (no `or`); at most two terms; at most one per dimension; every dimension is `event_name` or
`host`; the existing `event_name` checks stay byte-for-byte equivalent in effect; and a `host`
term must use `eq` (one JSON string) or `in` (a JSON array of 1..100 strings, counted before
deduplication). Each host value must be 1..253 characters, equal to `T.toLower` of itself, must
not end with `.`, and must not contain whitespace or any of `/ : ? # @`. Use distinct messages,
for example `"history accepts at most one event_name and one host term"`,
`"host requires eq/in"`, `"hosts require 1..100 values"` and
`"host values must be canonical lowercase hostnames without scheme, port, path or trailing dot"`.
These surface as 400 `invalid_users_query` through `RequestValidation`, unchanged.

In `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs`, export `canonicalDomain`. In
`kansoku-core/src/Kansoku/Users/History.hs`, replace the inline host projection with
`canonicalDomain "url"` so the node `host`, the filter predicate and (in Milestone 2) the facet
share one expression. `History.history` already compiles all filters through
`QF.compileMetricFilters`, which resolves `host`; no further SQL change is needed. Because the
history handler trusts the middleware, also call `validateHistory` at the top of the `events`
handler in `kansoku-core/src/Kansoku/Users/Handler.hs` and return
`PageBad (RelayPageError "invalid_users_query" message False Nothing)` on `Left`, so direct
callers of `usersServer` (tests, embedding) get the same guard. Leave the cursor format and
`historySort` unchanged.

Update the `events` Description in `kansoku-api/src/Kansoku/Users/Api.hs` to state the new
grammar in the existing terse style, for example: "At most one event_name eq/in term (1..100
names of 1..128 characters) and one host eq/in term (1..100 canonical lowercase hosts of 1..253
characters), ANDed. Host matches the node host; events with null host never match a host term."

Tests: extend `kansoku-core/test/Kansoku/Users/HandlerSpec.hs` with accepted cases (host eq,
host in, host plus event_name) and rejected cases (two host terms, host `neq`/`contains`/`unset`,
101 values, empty string, `App.Example`, `app.example.`, `app.example:443`,
`https://app.example`, an `or` group containing host). In `scripts/users_acceptance.py`, add to
the history fixture user two events with `url='https://app.example/a'`, one with
`url='https://APP.example./b'` (proves canonicalisation), one with `url='https://docs.example/'`
and one server event with `url=None`; adjust the existing total of 11 accordingly. Assert that
`host eq app.example` returns exactly the three app events, each node `host == 'app.example'`;
that `host in [app.example, docs.example]` together with `event_name eq page_view` returns only
matching rows; that forward `first=1/after` and backward `last=1/before` walks under the host
filter each equal the unpaged filtered list; and that invalid host terms return 400.

### Milestone 2: the hosts facet

At the end of this milestone `GET /users/{userId}/hosts` exists. Parameters: optional paired
`from`/`to` (same bounds as history), `includeBots` (default false), and at most one
`event_name` eq/in `filter` term. A `host` term is rejected on this route because a facet does
not filter by its own dimension. Response `200`:

```json
{"hosts":[
  {"host":"app.example","eventCount":3,"lastOccurredAt":"2026-07-02T10:00:00.000Z"},
  {"host":"docs.example","eventCount":1,"lastOccurredAt":"2026-07-01T09:00:00.000Z"},
  {"host":null,"eventCount":1,"lastOccurredAt":"2026-07-01T08:00:00.000Z"}]}
```

Entries are ordered by `eventCount` descending, then `host` ascending, with the `null` entry last
regardless of count. Hosts with zero matching events are absent. An existing user with no
matching events returns `{"hosts":[]}`. Unknown, foreign or erased users return 404
`user_not_found`, exactly like history. More than 1000 distinct entries returns 400 with problem
code `user_hosts_too_large` and no partial list (query `LIMIT 1001`). ClickHouse failure or
deadline returns the existing `clickhouse_unavailable` 503.

Add `UserHost { host :: Maybe Text, eventCount :: Integer, lastOccurredAt :: Text }` and
`UserHosts { hosts :: [UserHost] }` to `kansoku-api/src/Kansoku/Users/Types.hs` with explicit
`ToJSON`/`FromJSON` that always emit `host` (as `null` when absent), and an OpenAPI schema that
marks `host` required and nullable, following how `UserEvent.host` is handled (ADR-25 notes that
generated schemas need explicit overrides for nullable required fields). Add a `hosts` field to
the `Users` record: `"users" :> MetricsAuth :> Capture "userId" Text :> "hosts" :> Description
"..." :> Dates (QueryParam "includeBots" Bool :> QueryParams "filter" MetricFilter :>
MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "User hosts" UserHosts) (KansokuResult UserHosts))`.

Add `hosts` to `kansoku-core/src/Kansoku/Users/History.hs` (or a new
`kansoku-core/src/Kansoku/Users/Hosts.hs`, registered in `kansoku-core/kansoku-core.cabal`). It
reuses the history pattern: retained bounds, identity connection, existence check, compiled
`event_name` filter, `NOT is_bot` unless `includeBots`, optional date predicates, then
`SELECT toJSONString(tuple(h, count(), max-occurrence stamp)) FROM (SELECT canonicalDomain "url"
AS h, occurred_at ...) GROUP BY h ORDER BY isNull(h), count() DESC, h LIMIT 1001`. Factor the
shared scope (source, user predicate, bot and date predicates) out of `history` rather than
duplicating it, so the facet and the history route cannot drift. Wire the handler in
`kansoku-core/src/Kansoku/Users/Handler.hs`, add `["users", _, "hosts"] -> Just ["from", "to",
"includeBots", "filter"]` to `allowedParameters` and a matching validation branch in
`kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` that uses a `validateHostFacet` from
`Validation.hs` (dates plus at most one `event_name` term; any `host` term rejected with
`"hosts does not accept a host filter"`). Check that the `["users", _]` profile branch does not
shadow the new path.

Regenerate `docs/api/openapi.json` with `just openapi`. Add an `OpenApiSpec` case asserting the
`/users/{userId}/hosts` operation exists and that `UserHost.host` is required and nullable. In the
users acceptance workflow assert the facet for the fixture user, its ordering, the `null` entry,
404 for an absent user and another account, 400 for a host filter on the facet, and empty `hosts`
for a selection with no matches.

### Milestone 3: contract documentation and the totals invariant

Write the facet Description in `Api.hs` (parameters, ordering, null entry, 1000-entry bound and
error code, "sum of selected entries equals filtered history size for the same parameters").
Extend the "Identified users, profiles and history" section of `docs/guides/query-metrics.md`
with the host grammar, canonical-value rules, null-host treatment, the facet, and a short worked
example of computing "N of M". Update [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md)
following `agents/skills/exec-plan/ADR.md` (it is a profile-governed bundle; run `just adr-check`):
add the facet to the resource list and record that history filters are one event_name and one
host term, that totals come from the facet rather than a Relay count, and why
`/metrics/events?groupBy=host` is not equivalent.

The acceptance workflow gains the invariant check that motivates the facet: for several
selections (no filter; `event_name eq feature_used`; `from/to` covering one day; `includeBots=true`),
the sum of all facet `eventCount` values equals the number of history edges collected by paging
with the same parameters, and for each non-null facet entry the paged history with
`host eq <entry>` has exactly `eventCount` edges. With no dates and `includeBots=true` the sum
also equals the profile's `retainedEventCount` once ingestion has settled.


## Concrete Steps


All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`.

Build and run focused tests while developing:

```bash
just build-with-tests
just deterministic-test
```

Regenerate and check generated artifacts after Milestone 2 and 3 route or Description changes:

```bash
just openapi
just openapi-check
just openapi-lint
```

Run the public acceptance workflow (owns disposable native stores; any local container work must use Apple Container, never Colima):

```bash
just users-acceptance
```

A passing run ends without a Python traceback and exits 0. Run the full gate before declaring
Milestone 3 complete:

```bash
just check
just adr-check
```

Commit at each milestone with Conventional Commits and the trailers:

```text
feat(users): filter user event history by host

ExecPlan: docs/plans/71-filter-a-user-s-event-history-by-site.md
Intention: intention_01m7akmvr7ejes4hjc4jac1x33
```


## Validation and Acceptance


Milestone 1 is accepted when, against a server with the fixture user `alice` having events on
`app.example` (3, one sent with URL host `APP.example.`), `docs.example` (1), `shop.example`
(existing fixtures) and one event without a URL:

```bash
curl -s -H "Authorization: Bearer $TOKEN" --get "$URL/users/alice/events" \
  --data-urlencode 'filter={"dimension":"host","op":"eq","value":"app.example"}' \
  | jq '[.edges[].node.host] | unique'
```

prints `["app.example"]` with three edges in total; adding
`filter={"dimension":"event_name","op":"eq","value":"page_view"}` narrows to the app page views;
paging that selection with `first=1` and `last=1` in both directions reproduces the unpaged list;
and `filter={"dimension":"host","op":"eq","value":"App.Example"}` returns HTTP 400 with
`"code":"invalid_users_query"`. The new `HandlerSpec` cases fail before the validation change and
pass after.

Milestone 2 is accepted when `GET /users/alice/hosts` returns the entries above in the stated
order with the `null` entry last, `GET /users/absent/hosts` returns 404 `user_not_found`, a host
filter on the facet returns 400, `just openapi-check` passes with the regenerated document
committed, and the new `OpenApiSpec` case passes.

Milestone 3 is accepted when the totals invariant in the users acceptance workflow passes for
every listed selection, `just check` and `just adr-check` pass, and the guide and ADR describe the
contract a consumer needs to build a site picker and an exact "N of M" summary.


## Idempotence and Recovery


All changes are additive code, documentation and tests; no migration, storage projection or
configuration change is involved, so every step can be rerun. `just openapi` overwrites
`docs/api/openapi.json` deterministically; if `just openapi-check` fails, rerun `just openapi` and
review the diff. The acceptance workflow creates uniquely prefixed fixtures in disposable stores
and can be rerun after a failure. The working tree may contain unrelated uncommitted work from
other plans (for example plan 70's retention changes); stage only this plan's files when
committing.


## Interfaces and Dependencies


No new library or dependency. The interfaces other work depends on are:

The history filter grammar on `GET /users/{userId}/events`: repeatable `filter` with at most one
`{"dimension":"event_name","op":"eq"|"in",...}` term and at most one
`{"dimension":"host","op":"eq"|"in","value":...}` term, ANDed. Canonical host values only.

The facet `GET /users/{userId}/hosts` returning `UserHosts` (`kansoku-api/src/Kansoku/Users/Types.hs`):

```haskell
data UserHost = UserHost {host :: !(Maybe Text), eventCount :: !Integer, lastOccurredAt :: !Text}
newtype UserHosts = UserHosts {hosts :: [UserHost]}
```

`Kansoku.Metrics.Query.Dimension.canonicalDomain :: Text -> Text` becomes exported and is the
single definition of a canonical host for history nodes, the history host filter and the facet.

The downstream consumer is `mori://shinzui/kansoku-ui`, which consumes the contract published in
`docs/api/openapi.json`; it can begin its UI plan against the contract above before this plan is
implemented, and integrate once Milestone 2's OpenAPI document is committed.


Revision note (2026-11-13): Native acceptance required correcting the shared host extraction
for trailing-dot URL authorities, and the acceptance instructions now describe the harness's
actual native-store coverage. Scope and public acceptance remain unchanged.
