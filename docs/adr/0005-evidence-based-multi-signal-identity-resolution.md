# ADR 0005: Evidence-based multi-signal identity resolution

- Status: Accepted
- Date: 2026-07-19
- Deciders: Kansoku maintainers

## Context

Kansoku originally resolved identity through a latest-wins
`analytics.identity_map` from one cookie-like `anonymous_id` to one `user_id`. That
representation cannot distinguish cookies, device identifiers, hashed email addresses,
and probabilistic browser fingerprints. It also erases legitimate conflicts such as a
shared device being observed with two users.

ADR 0004 established that `analytics.events_resolved` is a shared analytics contract with
the ordered columns `event_id`, `event_name`, `occurred_at`, `url`, `account_id`,
`canonical_user`, and `properties_json`. Identity changes must preserve that projection
because metric queries and experiment analytics consume it.

## Decision

`AnalyticsEvent` accepts an optional `identifiers` object whose keys come from the closed
set `cookie`, `device`, `fingerprint`, and `email_sha256`. Values are non-empty printable
non-space ASCII strings of at most 256 characters. The existing `anonymousId` remains the
implicit cookie signal; clients do not need to duplicate it in `identifiers`.

ClickHouse stores binding evidence in the account-scoped
`analytics.identity_signals` table. A binding is one event-local observation that a
signal and an explicit `user_id` occurred together. Cookie bindings are created only by
`identify` and `alias` events to preserve established semantics; entries in the new map
bind on any event carrying a `user_id`. Resolution deliberately performs no transitive
closure across events.

Evidence rows retain every distinct observation. Their `ReplacingMergeTree` ordering key
contains account, kind, value, user, observation time, and event id, so only an exact
at-least-once replay can collapse. `analytics.identity_conflicts` exposes signals observed
with multiple users.

Confidence is view-time policy rather than stored data: hashed email is `0.95`, cookie is
`0.90`, device is `0.80`, and fingerprint is `0.50`; the current resolution threshold is
`0.50`. An explicit event `user_id` wins first. Otherwise, matching signal bindings are
ranked by confidence and then observation recency, with the event's cookie as the final
fallback.

Fingerprint evidence has a 180-day row-level TTL. Raw-event fingerprint scrubbing and
per-user erasure are operational mutations documented in
`docs/runbooks/identity-data-deletion.md`. Erasure clears both mapped identifiers and
the implicit `anonymous_id` cookie before deleting the user's evidence. It does not
automatically delete anonymous facts reached through probabilistic signals because those
signals can be shared.

The resolution implementation replaces the internals of
`analytics.events_resolved` while preserving ADR 0004's ordered seven-column contract.

## Alternatives considered

- Adding one fingerprint column to `identity_map` was rejected because each new
  identifier kind would require another schema slot and the latest-wins engine would
  still erase conflicts.
- Storing confidence on each evidence row was rejected because confidence is policy, not
  an observation. View-time scoring applies a policy revision consistently to history.
- Transitive graph closure was rejected because weak or shared signals would amplify
  across unrelated users and ClickHouse views cannot express safe bounded recursion.
- Requiring dedicated identify events for every mapped identifier was rejected because
  SDKs commonly attach the current identifier set to ordinary authenticated events.

## Consequences

Producers may attach multiple identity signals without overloading the cookie field.
Conflict evidence remains auditable, and account scoping prevents cross-tenant stitching.
Shared fingerprints can join sessions but remain explicitly lower-confidence and
shorter-lived than deterministic signals.

Resolution is query-time work over signal expansion and bindings. Consumers must continue
to aggregate distinct event or user identities rather than rely on raw joined row counts.
Adding an identifier kind is a coordinated policy change: extend the Haskell vocabulary,
validation, confidence view, and retention decision together.
