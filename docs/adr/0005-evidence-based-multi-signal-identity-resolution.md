---
type: Architecture Decision Record
title: Evidence-based multi-signal identity resolution
description: Resolve identity at query time from evidence-based multi-signal identifier bindings instead of a latest-wins cookie-to-user map.
timestamp: 2026-10-15T19:38:22Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-5
status: Accepted
date: 2026-07-19
---

# ADR 0005: Evidence-based multi-signal identity resolution

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
set `cookie`, `device`, `fingerprint`, `email_sha256` and `email_hmac`. Values are non-empty printable
non-space ASCII strings of at most 256 characters. The existing `anonymousId` remains the
implicit cookie signal; clients do not need to duplicate it in `identifiers`.

ClickHouse stores binding evidence in the account-scoped
`analytics.identity_signals` table. A binding is one event-local observation that a
signal and an explicit `user_id` occurred together. Cookie bindings are created only by
`identify`, `identify_once` and `alias` events to preserve established semantics; entries in the new map
bind on any event carrying a `user_id`. Resolution deliberately performs no transitive
closure across events.

Evidence rows retain every distinct observation. Their `ReplacingMergeTree` ordering key
contains account, kind, value, user, observation time, and event id, so only an exact
at-least-once replay can collapse. `analytics.identity_conflicts` exposes signals observed
with multiple users.

Explicit user IDs win. Anonymous cookie evidence first uses a nonempty
`(account_id,source_service,session_id)` with the same cookie: exactly one observed user
resolves the session, including pre-login facts. Multiple session users stay ambiguous for
that cookie. Without session evidence, a cookie must identify exactly one user across retained
history. Other signals also require uniqueness before ranking. Confidence is email 0.95,
cookie 0.90, device 0.80 and fingerprint 0.50; different users tied at the strongest confidence
stay anonymous. This deliberately replaces latest-wins/nearest-login guessing. No transitive
user merge or unrecorded logout boundary is inferred.

Evidence records corrected occurrence time separately from receive time, plus event ID, source
service and session ID. Fingerprint expiry uses occurrence time in query predicates as well as
physical TTL. Relevant bindings may be outside the selected candidate-event window. Subjects
are `user:<original id>` or `anonymous:<original id>`; no identity remains empty. Prefixing is
unambiguous even when the original ID contains colons or an existing prefix. Private rich
relations also expose subject_kind and subject_id; trait consumers join user subjects only.

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

## Exact lookup ownership and bounded candidates

Canonical raw rows remain the immutable facts. Replay-safe max-timestamp indexes retain one
signal/user and cookie/session/user observation, and a per-day context/signal index supports the
direct SQL resolver. Index construction and verified replacement use explicit writer-stopped
migration 0018. A context is source_service,session_id,anonymous_id and the original identifiers
object; resolving that context does not depend on unrelated event properties. Canonical raw
facts expose a materialized `identity_context_key` with byte-length-prefixed components,
including the account. This lossless encoding avoids hash collisions and lets the HTTP
lookup read/hash one key vector. The writer-stopped migration materializes existing rows;
raw identifier scrubbing must recompute this derived column as part of the fenced lifecycle.

HTTP's `resolvedSource` uses a rich parameterized relation with account and requested occurrence
bounds applied to canonical facts. Its explicit all-account flag is always zero for HTTP; an
empty account is not a bypass. The public seven-column SQL view delegates to a direct relation,
so it does not depend on an application connection lifetime.

Each metrics connection may hold session-local Join tables of exact evidence observations
and resolved contexts for its most recently queried account/date window. Switching account
or window rebuilds them. The context index is filtered by account and candidate dates before
signal expansion; evidence observations remain available across retained account history.
Before reuse, Kansoku checks all three index table UUIDs and active part names, including
empty tables. Inserts, merges, mutations and replacement invalidate the snapshot; missing
indexes fail closed. Snapshot construction retains the before-build revision so concurrent
changes trigger another refresh next time. There is no periodic refresh lag. Fingerprint
expiry sets the earliest refresh deadline from current evidence. Every resolved SELECT also
checks that deadline against the engine clock and fails closed if it elapsed between
preparation and execution. Context resolution is rebuilt when that deadline passes. As with direct
ClickHouse queries over synchronous materialized views, concurrent writes may become visible
on the next query; this is not a cross-table transactional snapshot claim.

These temporary objects belong to the physical connection and disappear on disposal, idle
expiry or shutdown. Construction throws rather than truncates: signal and session Join tables each allow 64 MiB,
the resolved-context Join table allows 128 MiB, and each preparation query allows 256 MiB.
A one-row Join table holds the expiry deadline. A failed build disposes the connection. The pool size bounds
resident snapshots. The shared query-budget owner must apply its configured limits to cold
preparation as well as the final SELECT. This optimization needs the owning lifecycle and
must not be called as a public standalone SQL relation.

Erasure/retention must cover identity_signals, identity_signal_users, identity_session_users and
identity_context_signals as well as raw/replayable inputs. Mutations or verified rebuilds change
the part/UUID revision before a subsequent HTTP query can reuse evidence. The administrative
child owns the complete fenced workflow; deleting only the observation table is insufficient.

Catalog version 3 publishes identifierKinds. HMAC email identifiers use a backend secret pepper,
ASCII whitespace trimming, Unicode default lowercase, UTF-8 and version-prefixed lowercase
HMAC-SHA-256 hex; no Unicode normalization/provider rewriting. Browsers receive opaque values,
never the pepper. Legacy unkeyed hashes remain accepted but discouraged. See the ingest guide
for the normalization/rotation contract and SDK vocabulary generation.
