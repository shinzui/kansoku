---
type: Runbook
title: "Administrative operations"
description: "Issue and revoke credentials, inspect rejected events, and preview or resume fenced erasure, retention and archive maintenance."
docId: DOC-1
tags: ["administration", "credentials", "maintenance", "retention"]
generated:
  by: process:codex
  at: "2026-10-16T03:20:35Z"
---

# Administrative operations

`kansoku-admin` ships with the server and migration executables and uses their database and
queue configuration. Apply both migration systems first; [operations](operations.md) describes
them. Normal startup applies neither migrations nor retention policy. Build the packaged CLI
with `nix build .#kansoku-admin`, then use `./result/bin/kansoku-admin --help`.
`nix run .#kansoku-admin -- --help` selects the same administrative executable.

Exit 0 means success or a requested preview; exit 1 means invalid arguments or an operation/
output failure. Destructive/data-maintenance commands preview without `--confirm`. Key issuance
is an explicit creation command and displays its token once. Mutation journals cannot restore
deleted payloads. Run commands against the intended database endpoints.

## Credentials

```bash
kansoku-admin issue-key --kind write --account account_123 --description 'browser'
kansoku-admin issue-key --kind service --account account_123 --description 'reporting'
kansoku-admin list-keys --account account_123 --limit 100
kansoku-admin revoke-key --id KEY_UUID
kansoku-admin revoke-key --id KEY_UUID --confirm
```

Listings contain metadata, never hashes or recoverable tokens. Revocation affects the next
authenticated request. Already-revoked IDs succeed; unknown IDs fail. Optional `--account`
constrains the revocation preview. `kansoku-server issue-key` calls the same issuance code.

## Erasure and recovery

```bash
kansoku-admin erase-user --account account_123 --user user_42
kansoku-admin erase-user --account account_123 --user user_42 --confirm
kansoku-admin erase-user --account account_123 --user user_42 --delete-events
kansoku-admin erase-user --account account_123 --user user_42 --delete-events --confirm
```

Use the standard `--user=VALUE` form for user IDs beginning with `--`.

Preview reports scope and counts for raw facts and replayable sources without printing SQL or
discovered identifiers. Live ingest can change counts before confirmation. Default **identity
unlinking** removes matching cookies, mapped identifiers, session links and current traits;
explicit user IDs and arbitrary historical properties/context may remain. `--delete-events`
also removes that account/user's explicit facts. Shared/probabilistic evidence never authorizes
deleting another user's anonymous facts. Other accounts' facts remain unchanged.

Both modes scrub queue/archive envelopes and remove matching quarantine. Rejected payloads do
not establish bindings or reserve event IDs. Accepted hashes and minimal dispositions remain:
equal retries acknowledge the existing logical event without publishing it again. Legacy erased
IDs without a hash conflict. New IDs can establish new observations; this is not a permanent
user ban or a search for unknown personal text embedded in arbitrary JSON.

Confirmation persists a job and global fence, then waits for admitted reads/inserts/replays,
including backend work surviving a cancelled caller. A native-write drain exceeding sixty
seconds fails with the fence retained before discovery or mutation.
Ingest and metric routes return retryable 503 `maintenance_unavailable`, preserving ingest CORS.
Operational routes and the schema catalog remain available; readiness may report the paused
pipeline. The global window is intentional for the initial single-tenant deployment.

```bash
kansoku-admin list-jobs --limit 20
kansoku-admin job-status --id JOB_UUID
kansoku-admin resume-job --id JOB_UUID
kansoku-admin resume-job --id JOB_UUID --confirm
```

Unconfirmed resume returns status. Failed/interrupted jobs keep the fence: resolve the dependency
or schema failure, then resume. Completed resume is idempotent. There is no automatic fence-clear
command. Rebuilds use current projection definitions; do not rerun historical migrations instead.

Executing jobs create random, exclusive 0600 recovery receipts in the temporary directory.
`--out NEW_PATH` chooses a new filename; existing files/symlinks are refused. Receipts contain
the job ID and redacted counts at their checkpoint. PostgreSQL is the authoritative current
stage and full unfinished discovery. Completion removes saved signal discovery and retains a
user digest. The final JSON response reports completion and the receipt path.

## Applied event and fingerprint retention

```bash
KANSOKU_EVENTS_RETENTION_DAYS=90 kansoku-admin apply-retention
KANSOKU_EVENTS_RETENTION_DAYS=90 kansoku-admin apply-retention --confirm
```

This applies a UTC snapshot cutoff at command time minus the configured days. Zero/unset means
unlimited events. Setting the variable alone changes nothing; schedule confirmed commands when
periodic advancement is required. Canonical reports and raw-triggered aggregates enforce the
applied cutoff. The job removes expired raw/replayable payloads, reserves logical identities,
rebuilds all derived states and verifies before releasing the fence. TTL is physical cleanup,
not the query predicate. Crossing sessions use remaining facts, so entry/duration/first-seen
cohorts may change. Profiles follow the event cutoff; expired profiles can remove current traits.

Every confirmed run also applies the separate 180-day fingerprint cleanup, including unlimited
event retention. Preview includes that cutoff and affected counts. Cleanup removes expired
fingerprint keys from raw/context data and existing queue/archive/diagnostic envelopes, preserves
other identifiers, rebuilds identity state and persists the fingerprint cutoff for later writer
attempts. Lookup evidence already expires after 180 days independently. New rejected diagnostics
retain their original-payload contract until their quarantine schedule or a later applicable cleanup.

Acceptance hashes, dispositions, trait-erasure and replay IDs remain indefinitely. Payload expiry
does not expire logical identity. Returning to unlimited retention cannot restore removed payloads.
Backups/manual database restoration need operator policy preserving ledgers/cutoffs and reapplying
erasure; never restore old source payloads into a live writer without that policy.

## Archive replay and purge

```bash
kansoku-admin replay-archive --limit 100 --before 2026-10-01T00:00:00Z
kansoku-admin replay-archive --limit 100 --before 2026-10-01T00:00:00Z --confirm
kansoku-admin replay-archive --after 2026-09-01T00:00:00Z --confirm --out new-replay.json
kansoku-admin purge-archive --before 2026-09-01T00:00:00Z --limit 1000
kansoku-admin purge-archive --before 2026-09-01T00:00:00Z --limit 1000 --confirm
```

`before` is exclusive and `after` inclusive, using archive time. Replay sends unchanged stored
envelopes and records new message IDs in one transaction with row locks and a unique physical-
queue/archive-ID ledger. Concurrent/retried commands cannot resend completed rows. Rollback sends
nothing. An output-file failure after commit can return exit 1: rerun safely and trust the ledger.
Archives remain until purge or retention expiry. Replay respects fences, dispositions and retention;
event idempotency preserves metrics. Limits default to 100, in 1..10000. Purges use at most 1000
rows per statement and stop at the command's total limit; repeat for more rows. No OFFSET is used.

## Rejected event inspection

```bash
kansoku-admin list-rejections --account account_123 --event identify --since 2026-10-01T00:00:00Z --limit 100
kansoku-admin list-rejections --account account_123 --limit 10 --include-payload
kansoku-admin purge-rejections --account account_123
kansoku-admin purge-rejections --account account_123 --confirm
```

Listings default to metadata; `--include-payload` explicitly prints sensitive original objects.
Purge defaults to now minus `KANSOKU_INGEST_QUARANTINE_RETENTION_DAYS`, accepts `--before`, and
uses the same bounded limits. Manual purge complements automatic quarantine expiry/caps; it is
not the automatic retention guarantee.
