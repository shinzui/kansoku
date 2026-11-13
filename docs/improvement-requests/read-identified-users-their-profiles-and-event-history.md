---
type: Improvement Request
title: Read identified users, their profiles and their event history
description: Add an account-scoped, read-only users resource that lists identified users with their current traits and first and last activity, reads one user's profile and identity evidence summary, pages through one user's resolved events newest first, and counts identified and anonymous subjects active in a range, so a consumer can show a user directory and a per-user drill-down.
generated:
  by: process:claude-code
  at: "2026-11-12T23:39:58Z"
requestId: IR-17
status: accepted
targetPlan: docs/plans/67-read-identified-users-profiles-and-event-history.md
timestamp: "2026-11-13T00:16:19Z"
origin: mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages
acceptanceCriteria:
  - id: AC-1
    statement: A service token can list the identified users of its account as a Relay connection, ordered by most recent activity by default and by first activity on request, optionally restricted to users active in a closed date range, to a case-insensitive user-ID substring, to governed `user:` trait filters in the existing filter grammar, and to saved cohort inclusion or exclusion; each row carries the user ID, current governed traits, and first and last activity times over retained history.
    verification: Public HTTP tests over two accounts seed identified, anonymous-only and stitched pre-login activity; assert account isolation, write-key rejection, both orderings with stable cursors across pages, each filter alone and combined, that anonymous-only subjects never appear, that identity and profile-only events do not move first or last activity, and that erased users disappear.
  - id: AC-2
    statement: A service token can read one identified user's profile, returning current governed traits with the time and kind (set or set-once) of the observation that won, first and last activity, the number of retained events, counts of linked identifier evidence by kind without any identifier value, the number of anonymous subjects resolved to this user, and current organisation membership with governed organisation traits; an unknown, foreign-account or erased user is a 404 problem.
    verification: Public tests assert set over set-once precedence and its reported origin, evidence counts for cookie, device, fingerprint and email_hmac without values in the body, fingerprint expiry reflected in the counts, organisation membership after group v2, and 404 for an unknown ID, another account's user and an erased user.
  - id: AC-3
    statement: A service token can page through one identified user's resolved events newest first as a Relay connection over an optional date range and optional event-name selection; each row has the event ID, event name, occurrence time, source, source service, session ID, nullable host and path, whether it is a canonical page view, and only those scalar properties declared by the registered schema at the event's schema version, never undeclared properties, context, raw identifiers or identity payloads.
    verification: Public tests include stitched pre-login anonymous events in the user's history, ties on occurrence time with a deterministic order, an event-name filter, a page boundary falling between equal timestamps, an undeclared property and an identifier that must not appear, and an identify event whose traits appear only as declared trait properties.
  - id: AC-4
    statement: A consumer can obtain, for a closed date range, the exact number of distinct identified users and the exact number of distinct anonymous-only subjects active in it, consistent with `/metrics/users` over the same range and bot selection.
    verification: A public test compares the identified plus anonymous counts with an ungrouped whole-range `/metrics/users` answer for the same seed and range, with and without includeBots, including a subject that resolves from anonymous to identified inside the range.
  - id: AC-5
    statement: The routes, their bounds (page sizes, search length, filter count, range length), ordering, consistency across pages while events arrive, retention and erasure effects, and the statement that identity is an analytical inference and not authentication are documented in the OpenAPI document and the query guide.
    verification: Review the served OpenAPI document and the query guide; the documented bounds are each exercised by a rejection test.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-12T23:39:58Z"
    document_timestamp: "2026-11-12T23:39:58Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author consistency review against kansoku 2975714 (docs/api/openapi.json paths, the query guide's current person
      traits and cohort sections, ADR-5, ADR-16 and ADR-19). No implementation, runtime evidence or independent review
      is claimed.
---

# Read identified users, their profiles and their event history

Requested by `mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages` under intention `intention_01m79211k6exp96qd67t2b3zmx`. The consumer handoff is `mori://shinzui/kansoku-ui/plans/29-integrate-kansoku-s-users-resource-through-the-server-boundary`; the screens are `mori://shinzui/kansoku-ui/plans/30-build-the-users-directory-page` and `mori://shinzui/kansoku-ui/plans/31-build-the-user-profile-page-with-identity-and-event-history`.

**Implementation plan:** [ExecPlan 67: Read identified users, profiles, and event history](../plans/67-read-identified-users-profiles-and-event-history.md). Accepted for implementation; implementation has not started.

## Why

Kansoku UI wants a Users screen: a directory of identified users with their traits and when they were first and last active, how much traffic is still anonymous, and a page per user that shows who they are and what they did. Kansoku already knows all of this. Conservative identity resolution ([ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md)) resolves subjects, governed current traits ([ADR-16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md)) give each user a current profile, and saved cohorts ([ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md)) already return identified users as a Relay connection. But the API at 2975714 has no way to read any of it per user: `/cohorts/{id}/members` returns bare IDs for one cohort, every `/metrics/*` route returns aggregates, and no route returns an individual event. A consumer cannot list users, read one user's traits, or show one user's events without trusted SQL, which [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) reserves for other consumers and the UI's own rules forbid.

## Requested behavior

Kansoku owns the paths, names and exact wire shapes. The request is one resource family because the list, the profile and the history must agree on who counts as an identified user, which events count as activity, and what erasure hides.

**Directory.** List identified users (subjects of kind user after resolution) in the token's account as a Relay connection following `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`, with page sizes up to 100. Order by last activity descending by default, with first activity descending as the other choice, and a user-ID tiebreak so cursors are stable. Activity means a retained event that resolved to the user, excluding identity and profile-only events in the same way `/metrics/users` excludes them, and including pre-login events that conservative resolution stitched to the user. Optional selection: a closed date range meaning "active in this range"; a case-insensitive substring of the user ID with a documented length bound; up to eight governed `user:` trait filters in the existing typed filter grammar; and `cohort` eq or neq with a saved cohort ID. Each row returns the user ID, the current governed traits (absent traits omitted or null, documented either way) and first and last activity timestamps over retained history. A count of the selected users is welcome but optional, and if offered must be exact or labelled as an estimate.

**Profile.** Read one identified user by ID. Return current governed traits, each with the timestamp of the winning observation and whether it came from set or set-once, so a consumer can say "plan: pro, set 3 days ago". Return first and last activity, the number of retained events attributed to the user, counts of identity evidence by kind (cookie, device, fingerprint, email_hmac, legacy email_sha256), and the number of distinct anonymous subjects resolved to this user, but never an identifier value. Return current organisation membership from group v2 with governed organisation traits, when present. Unknown IDs, other accounts' users and erased users are the same 404 problem, as cohorts already do for foreign IDs.

**Event history.** Page through one user's resolved events newest first as a Relay connection, with page sizes up to 100, an optional closed date range, and an optional event-name `eq` or `in` selection. Order by occurrence time, then by a documented stable tiebreak (for example the stored order ADR-16 already uses), so equal timestamps never drop or repeat a row across pages. Each row carries the event ID, event name, occurrence time, source, source service, session ID, nullable host and path, whether it is a canonical page view, and its scalar properties as declared by the registered schema at the event's schema version. Undeclared properties, `context`, raw identifiers and identity payloads stay out, which keeps this route no more revealing than what `prop:` dimensions already expose. Identify events may show their declared trait properties.

**Identified and anonymous counts.** For a closed range, return the exact number of distinct identified users and of distinct anonymous-only subjects active in it, with the same bot selection as `/metrics/users`. Kansoku may choose to add this as a grouping dimension of `/metrics/users` (for example a subject-kind dimension with `timeGrain=none`), as a measure, or as a field of the directory; the consumer only needs both numbers to agree with an ungrouped `/metrics/users` answer for the same range.

Authenticate as every metrics read does under [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md): service tokens with metrics-read permission, tenancy from the principal, write keys rejected. Document how retention and erasure change answers, and that identity is an analytical inference, not authentication. These are resource reads, not aggregates, so [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md)'s complete-answer rule does not apply; follow the collection pagination standard it names instead, and bound execution with the existing query budgets.

## Out of scope

Writing, merging or deleting users through this resource; exposing identifier values, raw payloads or undeclared properties; a per-user aggregate filter on `/metrics/*` routes, which is a separate request (IR-18); session replay; and any guarantee about events not yet visible to queries.

## Acceptance and ownership

AC-1 through AC-5 are required. AC-4 may be delivered separately from AC-1 to AC-3 if Kansoku prefers, since the consumer's directory shows the counts above the list but can render the list without them. Implementation remains in this repository; the consumer validates its own wire schemas against the served OpenAPI document and runs a real-service session before release.
