---
id: 37
slug: administrative-executable-for-keys-erasure-retention-and-replay
title: "Administrative executable for keys, erasure, retention, and replay"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:24:22Z
      mode: "update"
      note: "Promote beacon route (EP-39), rejection quarantine (EP-29 M4, EP-37 M5) and person properties (EP-40) into scope after owner discussion."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T01:49:19Z
      mode: "implement"
      note: "Begin packaged administration, persisted maintenance fencing, resumable cross-store erasure/retention and transactional replay after EP-40 acceptance."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
---

# Administrative executable for keys, erasure, retention, and replay


## Purpose / Big Picture


Provide one administrative executable for credentials, identity unlinking, explicit event deletion,
retention and archive recovery. Commands must report their actual guarantees, survive retries,
and prevent queue/archive replay from undoing deletion.

## Progress


- [x] M1: Key issue/list/revoke works through the packaged kansoku-admin executable.
- [x] M2: Resumable account-scoped erasure covers raw, derived, queued and quarantined data.
- [x] M3: Retention applies consistently to canonical facts and dependent aggregates.
- [x] M4: Transactional archive replay is safe across crashes and repeated invocations.
- [x] M5: Bounded rejection inspection and manual purge complement automatic expiry.

## Surprises & Discoveries


The current runbook scrubs identifiers but retains user_id and arbitrary properties/context;
it is identity unlinking, not complete personal-data deletion. Raw TTL/mutations do not retract
materialized views. A local replay output file cannot atomically record a PostgreSQL resend.

The source fixture found that raw and archive discovery can contain the same event ID in
one upsert page. Group those rows and OR their dispositions before ON CONFLICT. Diagnostic
payloads must not enter discovery or dispositions: rejected IDs can later be validly reused by
another user. Detect private queue wrappers by their server envelope marker and explicitly
wrap diagnostic originals when inspecting them, so unknown producer fields cannot impersonate
that envelope. Read raw mapped values too: expired fingerprint evidence may have left the index
while its original raw value still needs erasure.

## Decision Log


On 2026-10-15 use explicit maintenance fencing for destructive cross-store jobs in this initial
single-tenant deployment. Preserve preview/confirm and resumable job state; do not claim atomic
transactions across PostgreSQL and ClickHouse. Retention must not leave fast/slow metric paths
returning different populations.

On 2026-10-16 implement a persisted global fence plus PostgreSQL shared session locks around
whole protected HTTP operations and native writer insert attempts. Confirmation persists a job
before taking the exclusive lock and waiting for admitted operations. A bounded pool of
nonblocking libpq sessions makes coordination fail closed without adding the released Hasql
blocking-cleanup issue discovered in EP-29. Persist account/event dispositions containing only
delete/scrub flags, and re-evaluate them on every writer retry; a retained pre-fence in-memory
batch must never restore old identity or trait fields. Existing accepted hashes remain; a
disposition also reserves a legacy ID that had no acceptance-ledger row.

Retention is an explicitly applied snapshot cutoff, advanced by each apply-retention run;
operators schedule that command when they need periodic advancement. Canonical queries exclude
older facts immediately, source payloads expire under the same fence, all derived states rebuild,
and physical TTL is only cleanup for the applied cutoff. Profiles use the same event cutoff;
minimal acceptance/disposition/trait-erasure/replay identities remain indefinitely. Setting
0/unset removes the future cutoff but cannot restore already-deleted payloads.

Rebuilds read each current installed materialized view's as_select and target columns, replacing
raw sources with the canonical source, then clear/replay dependency-ordered targets under the
global fence. Historical migrations must not overwrite later rich views. Journal stages live
in PostgreSQL; exclusively created 0600 random local receipts preserve redacted discovery counts and the job ID; full unfinished discovery is PostgreSQL-owned.

Later review (2026-10-16) adds backend transaction-level traffic locks to acceptance and
quarantine SQL: a request's coordination session may end while another PostgreSQL backend
is still completing its payload write. Try-lock admission avoids deadlock behind a pending
exclusive job. Maintenance also drains native raw INSERTs before discovery; the native sample-
block handshake registers any write capable of committing rows, and writers explicitly disable
asynchronous insertion. A held native input stream now proves this ordering in the owned fixture.
The dedicated Nix entry point selects kansoku-admin as mainProgram; both metadata evaluation
and nix run --help pass. The CLI accepts --user=VALUE for valid selectors beginning with --; explicit deletion tests that
case. The first packaged gate passes 423 core, 19 client, four probe and seven administrative
families plus required SDK cases, but the final-candidate repeat includes these later fixes.

## Outcomes & Retrospective

All five milestones are complete. Final source acceptance passes 361 core examples, 18 client
examples, four probes, generated contracts/formatting, strict validation of all 17 ADRs, three
telemetry modes and four lifecycle cases. Final packaged acceptance passes 423 core examples,
19 live-configured Haskell client examples, four probes and 59 executed Hurl requests (43 safe,
15 stateful including retries, one disabled). Native recovery/limits/replay/identity, all public
EP-33/34/35/36/40 workflows, geography defaults/startup/privacy and required SDK helper cases
pass in all three telemetry modes.

The packaged kansoku-admin passes seven non-skipped scenario families: credential metadata,
preview/revocation; transactional replay rollback/concurrency and committed-before-output recovery;
rejection inspection/purge; backend transaction/native insert draining, retained writer payload,
failed rebuild/resume and legacy-ID reservation; explicit deletion/account isolation and logical
retry; fingerprint cleanup with unlimited event retention; and retained canonical/rollup/filtered
agreement, crossing sessions, native old-block replay, source expiry and irreversible policy reset.
The fixtures cover Unicode/quoted and leading-dash user selectors, CORS under the persisted fence,
redacted 0600 receipts and valid reuse of a previously rejected ID by another user. No required
case is skipped. Evidence: `.dev/acceptance/run-s46qcs0h/sanitized`, including `admin-summary.log`;
owned CLI processes and private receipts are under its sibling `admin` directory.

The compiled runtime candidate is b33474f; Nix mainProgram metadata is verified at 562b4c8
with both attribute evaluation and nix run --help. ADR-17 is Accepted. Global maintenance windows,
explicit cutoff advancement, full retained-history rebuild cost, indefinite minimal identities,
future new observations and backup/unknown-JSON boundaries are documented in
`docs/guides/administration.md`. EP-39 consumes the same fenced ingest/transaction boundary;
EP-38 owns the final joint consumer, cost and capacity gate.

## Context and Orientation


`kansoku-server/app/Main.hs` contains issue-key; `app/Migrate.hs` supplies the CLI pattern.
`Kansoku.Auth.Issue`, `Auth.Store`, `Postgres.hs`, `ClickHouse.hs` provide existing boundaries.
Read `docs/runbooks/identity-data-deletion.md`,
[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) and
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).
PGMQ APIs are at `mori://shinzui/pgmq-hs/packages/pgmq-hasql`; inspect the pinned version.

## Plan of Work


### M1: Credentials


Create `kansoku-server/app/Admin.hs` and the Cabal/Nix executable. issue-key delegates to the
existing issuance logic and emits plaintext once. list-keys emits metadata without hashes;
revoke-key requires --confirm, is idempotent and reports already-revoked as success. Keep the
existing issue-key alias only as a convenience, with one implementation. Document actual
subcommand flags and failure exit codes.

### M2: Erasure jobs


`erase-user --account ID --user ID [--delete-events] [--out PATH] [--confirm]` previews counts
and scope, not raw SQL with sensitive literals. Save discovery and job state with 0600 permissions
and a random safe filename, never paths derived from arbitrary user IDs. Native parameters
carry values. Without --delete-events, name the result identity unlinking: user_id and arbitrary
traits inside historical payloads may remain. With it, delete explicit-user facts; never delete
another user's anonymous events solely from shared/probabilistic evidence.

Require a persisted maintenance fence that rejects account ingest, stops writer/replay for that
account, and is verified before mutation. For initial single-tenant deployment a global ingest/
writer fence is acceptable if documented. Discover bindings before deletion; scrub matching
queue and archive envelopes, quarantine, identity signals and trait state. Remove explicit-user
trait events with --delete-events; unlink mode still removes current trait state and prevents
rebuild from reintroducing it by scrubbing the relevant trait properties. Preserve minimal
accepted-event tombstones/hashes so retry cannot reaccept deleted events. Extend source-envelope
scrubbing to implicit cookie, all mapped kinds, session references and explicit user fields as
appropriate to the selected operation, without copying secrets to logs.

Wait for mutations to finish, fail on latest_fail_reason and rebuild affected aggregates from
remaining canonical facts before reporting success. Queries must fail clearly while a rebuild
would expose inconsistent state. Resume a crashed job from persisted stages; keep the fence
until verification completes. Document that future newly generated events and backup restoration
require operator policy; this tool cannot erase unknown identifiers embedded in arbitrary JSON.

### M3: Retention


`apply-retention --confirm` reads KANSOKU_EVENTS_RETENTION_DAYS (0/unset means unlimited).
Preview before changing the policy. Define retained facts by occurred_at cutoff consistently
across canonical queries, sessions, user first-seen and exposures; TTL is physical eventual cleanup,
not the sole query predicate. Drop/rebuild old aggregate states so unfiltered and filtered metrics
agree after expiry. Coordinate identity evidence/traits and their stated separate retention
policies; do not advertise all-data retention if profiles remain. Expire replayable queue/archive
payloads older than the policy rather than resurrecting them. Keep minimal acceptance ledger entries and deletion tombstones indefinitely in this initial
version; payload retention does not expire logical event identity. Future ledger pruning requires
a separate explicitly versioned retry-horizon policy. Rebuild sessions crossing the cutoff from remaining facts and state the resulting
retained-history semantics. Keep explicit policy DDL outside normal startup and record job audit.

### M4: Replay/purge


`replay-archive --limit N [--before TS] [--after TS] --confirm` uses a durable PostgreSQL replay
ledger unique on queue/archive message ID. In one transaction lock selected rows, send their
unchanged queued envelopes, and record new message IDs; concurrent/crashed invocations cannot
resend a ledger-completed row. Archive rows may remain for audit until explicit purge; use
keyset pagination and bounded limits, not offset loops or the output file as truth. Respect
erasure fences, tombstones and retention. EP-30 provides downstream event idempotency.
`purge-archive --before TS --confirm` previews scoped counts and deletes in bounded chunks.

### M5: Rejections


list-rejections defaults to metadata with bounded limit and optional account/event/since filters;
--include-payload explicitly prints the sensitive event object. purge-rejections defaults to
now minus configured retention and requires --confirm. Automatic cleanup remains EP-29's owner;
the manual command is recovery/inspection, not the retention guarantee.

## Validation and Acceptance


Without confirm no destructive command changes data. Verify revocation, replay transaction
rollback, two concurrent replay processes and restart after send but before local audit output.
Replay never changes counts/revenue/session results. Deletion followed by archive replay and
aggregate rebuild cannot restore erased links/traits/events; verify a different account unchanged.
Retention makes raw/rollup/filtered counts agree after cutoff. Fail and resume a mutation job
while the fence remains active. Inspect permissions and output redaction. Run packaged CLI
commands only against owned acceptance databases and include the executable in Nix checks.

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


Destructive jobs cannot restore data; their journal is for resumability, not backup. New ingress/metrics maintenance states must be documented problems. Never clear a failed job fence automatically. All schema/table identifiers are service-owned, not interpolated user input.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`, `docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md`, `docs/plans/40-person-properties-set-and-set-once-user-traits.md`.

Hard dependencies: EP-29, EP-30, EP-32, EP-34 and EP-40 Complete; these supply quarantine, replay semantics, identity, sessions and traits. EP-40 owns trait definitions but does not depend on the admin executable. This removes the original implicit implementation cycle.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
