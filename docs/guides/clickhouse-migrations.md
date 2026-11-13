---
type: Runbook
title: "Initialize and upgrade ClickHouse"
description: "Initialize a fresh owned ClickHouse target, retain native identities, coordinate maintenance and recover explicit migration attempts."
docId: DOC-13
tags: ["clickhouse", "migrations", "maintenance", "recovery"]
timestamp: 2026-11-13T21:42:19Z
generated:
  by: process:codex
  at: "2026-11-07T20:24:51Z"
---

# Initialize and upgrade ClickHouse

Use `kansoku-ch-migrate` for explicit native migrations. Normal server startup applies neither
PostgreSQL nor ClickHouse migrations. PostgreSQL must be migrated first. The original shell
runner is retired, and `ch-reset` refuses: dropping only analytics would leave the separate
native ledger current and skip schema recreation.

The qualified integration target is one directly addressed, self-managed ClickHouse
26.8.28.14 server on arm64 macOS, using healthy writable Local disks and synchronous local
effects. `nix develop` supplies the hash-qualified artifact ahead of the template binary.
The [matrix](../../db/clickhouse/qualification/matrix.json) and
[adoption evidence](../evidence/clickhouse-migrate-adoption.md) record its digest and limits.
The released upstream `0.2.0.0` cohort also qualifies exact Altinity
`26.3.60.10001.altinitystable` and `26.3.60.10002.altinitystable` on owned Linux arm64
servers. Upstream records passing Nix and extracted-source qualification for these
artifacts. All four packages use the Hackage `0.2.0.0` cohort selected in
`cabal.project` and `flake.module.nix`, verified against registry metadata and the
upstream release tag on 2026-11-13. Kansoku supports explicit direct or replicated selectors as described below. These checks do not
qualify managed-cloud/proxy topology or the Linux amd64 application image. The
staging initiative at
`mori://tan/tan-app-infrastructure/plans/42-qualify-kansoku-artifacts-and-the-staging-clickhouse-contract`
uses the existing cluster for first-service qualification; its managed/package and
persistent recovery evidence remain required before normal serving. This runbook's
local commands still use the original qualified Darwin fixture and fresh identities.

## Fresh installation

Use a new checkout with new owned database roots. Preserve any old development data until its
owner chooses disposal. A database populated by the filename-only runner is not imported.
Native history executes the immutable 25-migration/257-step baseline followed by the
seven-step 0026 diagnostic-session correction (26 migrations/264 direct steps). Its reviewed
conversion preserves original SQL byte ranges: two standalone assertions become explicit
prepare/check/cleanup steps, and one materialization uses the qualified local mutation policy.
The [conversion evidence](../../kansoku-server/migrations/clickhouse/provenance.json) records
all three adaptations. There is no SQL splitting or source loading during execution.

Start the dependencies with `just up` in terminal 1. In terminal 2, enter the default development
shell, apply PostgreSQL first, build the executable and inspect the compiled plan:

```bash
nix develop
set -euo pipefail
umask 077
just migrate
migration_package="$(nix build .#kansoku-server --no-link --print-out-paths)"
export CH_MIGRATE="$migration_package/bin/kansoku-ch-migrate"
"$CH_MIGRATE" --help
"$CH_MIGRATE" plan --json
clickhouse-server --version
```

Plan works offline with credentials unset. The expected version is 26.8.28.14; a startup
crash or unsupported version fails the rehearsal. Do not restart repeatedly to turn a failed
qualification case into a pass. The generated command families are `plan`, `status`,
`history`, `verify`, `up`, `repair` and `maintenance`. The inherited `adopt` parser is always
refused by Kansoku before loading configuration or reading its request file.

Verify that the listener and data root belong to this new stack. Only then capture its server
UUID once, generate a ledger UUID, and retain the binding. Credentials remain in the environment
or a secret manager, outside this identity file:

```bash
export KANSOKU_CH_MIGRATION_TARGET='kansoku/local-owned'
export KANSOKU_CH_MIGRATION_ENDPOINT="http://127.0.0.1:$CLICKHOUSE_HTTP_PORT"
export KANSOKU_CLICKHOUSE_USER=default
export KANSOKU_CLICKHOUSE_PASSWORD=''
export KANSOKU_CH_MIGRATION_SERVER_ID="$(clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query 'SELECT toString(serverUUID())')"
export KANSOKU_CH_MIGRATION_LEDGER_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
mkdir -p .dev/migration-audit
python3 - <<'PY'
import json, os
keys = ['KANSOKU_CH_MIGRATION_TARGET', 'KANSOKU_CH_MIGRATION_ENDPOINT',
        'KANSOKU_CH_MIGRATION_SERVER_ID', 'KANSOKU_CH_MIGRATION_LEDGER_ID']
with open('.dev/migration-audit/target.json', 'x') as output:
    json.dump({key: os.environ[key] for key in keys}, output)
PY
```

Keep this binding after interruption. Subsequent operations load the retained values; they do
not rediscover and trust a new server UUID or generate another ledger UUID. The native ledger
is an Atomic database named `kansoku_migration_ledger`, separate from `analytics`.
`PG_CONNECTION_STRING` addresses the PostgreSQL coordinator created by `just migrate`.

Begin a persistent session before sending any native mutation:

```bash
"$CH_MIGRATE" maintenance begin --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --actor "$USER" --reason 'initialize this new owned stack' \
  > .dev/migration-audit/session.private.json
export KANSOKU_CH_MIGRATION_SESSION="$(jq -r .result.id .dev/migration-audit/session.private.json)"
"$CH_MIGRATE" maintenance status --json
```

Begin fences new protected traffic, excludes other administrators, and waits for cooperating
traffic scopes. A process/backend exit does not clear this fence. If begin failed after
persisting a session, `maintenance status` without a session variable finds the active session
matching the retained target/server/ledger binding. Retain that ID and diagnose; do not begin
an unrelated replacement session.

Before the first entry, stop every application/writer and manual administrative client that
could submit requests, and pause external SQL schedules. A native request can outlive the
PostgreSQL backend that admitted it. Stopping clients and restarting the directly owned server
with its retained data root is one reproducible drain procedure. For this local stack:

```bash
export PC_PORT_NUM="${PC_PORT_NUM:-8081}"
process-compose --address 127.0.0.1 --port "$PC_PORT_NUM" process restart clickhouse
```

Wait for the same process to become healthy and verify that `serverUUID()` still equals the
retained UUID. Restart alone is insufficient if old clients can reconnect or a delayed request
can still arrive. An empty `system.processes`, timeout or missing client PID is not drain proof.
Record the actual client-stop/restart procedure, target/server/ledger/session identities and
current predecessor counter in private evidence. Set `DRAIN_EVIDENCE` to that retained reference;
creating a file or supplying `--quiescent` alone does not establish quiescence.

```bash
export DRAIN_EVIDENCE='/secure/path/to/this-entry-drain-record'
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --drain-evidence /secure/current-drain.json --predecessor "$predecessor" up --json \
  --initialize-ledger "$KANSOKU_CH_MIGRATION_LEDGER_ID" \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reviewed fresh native initialization' --quiescent \
  --evidence "$DRAIN_EVIDENCE" > .dev/migration-audit/up.private.json
"$CH_MIGRATE" verify --require-current --guarded --json
```

Only first initialization uses `--initialize-ledger`. If bootstrap was interrupted, retain
that same UUID and use explicit reconciliation/recovery below. Existing native history is
checked under its retained binding; absent history never authorizes replay over old application
objects. Native checksums describe migration history, not arbitrary live-schema equality.

Before finishing, repeat the external drain procedure and retain fresh evidence for the new
predecessor counter. Set `DRAIN_EVIDENCE` to that fresh retained record. Then verify currentness and close the fence:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --drain-evidence /secure/current-drain.json --predecessor "$predecessor" maintenance finish --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'current native history and externally drained predecessors' \
  --quiescent --evidence "$DRAIN_EVIDENCE"
```

Finish refuses unresolved outcomes/receipts, incompatible history or pending migrations. A
failure preserves the fence. Start application traffic and resume external readers only after
successful completion. The migration operator remains the definer of reader views and must
retain their underlying SELECT rights; keep the separately constrained reader role and grants.

## Reload retained identities

When reopening a shell for reuse, upgrade or recovery, enter `nix develop` in the same checkout.
Restore the same PostgreSQL connection and migration operator credentials from your environment
or secret manager, including an explicitly set `KANSOKU_CLICKHOUSE_PASSWORD`. Apply PostgreSQL
migrations first and rebuild/select the new executable. Load the saved binding instead of
repeating the first-install UUID generation:

```bash
set -euo pipefail
umask 077
just migrate
migration_package="$(nix build .#kansoku-server --no-link --print-out-paths)"
export CH_MIGRATE="$migration_package/bin/kansoku-ch-migrate"
export KANSOKU_CH_MIGRATION_TARGET="$(jq -er .KANSOKU_CH_MIGRATION_TARGET .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_ENDPOINT="$(jq -er .KANSOKU_CH_MIGRATION_ENDPOINT .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_SERVER_ID="$(jq -er .KANSOKU_CH_MIGRATION_SERVER_ID .dev/migration-audit/target.json)"
export KANSOKU_CH_MIGRATION_LEDGER_ID="$(jq -er .KANSOKU_CH_MIGRATION_LEDGER_ID .dev/migration-audit/target.json)"
"$CH_MIGRATE" plan --json
```

Retain all session reports alongside this binding. For recovery, restore
`KANSOKU_CH_MIGRATION_SESSION` from the matching report's `.result.id`; if begin lost its
response, unset that variable and use `maintenance status --json` to find the active session
under the retained binding. Do not start a replacement session while one remains unfinished.

## Subsequent native migration

Back up both stores consistently, retain the identities and rehearse the new executable against
an isolated restored copy before a persistent rollout. Append native definitions; never edit
applied names, SQL, checksums or their ordering. Inspect the new offline plan, apply any new
PostgreSQL migrations first, and reload the retained identities as above. Stop submitting
clients/read schedules. After confirming the previous session completed, unset
`KANSOKU_CH_MIGRATION_SESSION` and begin a new session with the same native ledger binding,
using the fresh-install `maintenance begin` command with a new reason and a new private report
path. Export that report's `.result.id` as the new session ID. Preserve earlier reports.
Establish external drain before each entry.

After recording fresh external drain evidence and the complete recovery set below, run:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --recovery-set /secure/recovery-set.json \
  --drain-evidence /secure/current-drain.json --predecessor "$predecessor" up --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reviewed native upgrade or clean repeat' --quiescent \
  --evidence "$DRAIN_EVIDENCE"
"$CH_MIGRATE" verify --require-current --guarded --json
```

Do not supply `--initialize-ledger` for recurring execution. `up` applies only a compatible
pending suffix. A repeated clean run, after fresh drain evidence, submits no application SQL.
Establish fresh drain again and finish with the fresh-install `maintenance finish` command and
the newly observed predecessor counter. Ordinary `up` does not resume interrupted work or
consume standing repair authorization. Do not run the old shell runner beside native history.

Rollback is a separately reviewed restore of consistent backups into a separate isolated target
with reviewed target/server/ledger identities. Prevent simultaneously active cloned identities.
Restoring analytics alone, changing recorded checksums or deleting native events is not rollback.
No reset, force-clear, legacy import, data deletion or live deployment is automated here.

## Recovery set before application SQL

The first pending `up` or repair requires `--recovery-set FILE`. A bounded 64 KiB
JSON manifest covers PostgreSQL (including queue/application and coordination
schemas), `analytics` and `kansoku_migration_ledger`. Keep the manifest and immutable
backup artifacts outside those databases. Validation records an operator attestation;
the executable does not fetch artifacts or authenticate provider receipts.

After fencing, stop submitters and overlapping schedules, establish drain and
settle background mutations and TTL changes using app-scoped controls. Keep backup
and migration credentials available. Capture all three stores while logical state
is stable, before any native migration entry. PostgreSQL must contain the active
session/fence. Its snapshot precedes the later recovery-set acceptance record.
One ClickHouse archive may cover both databases, with two explicit coverage entries.
Use qualified tools such as PostgreSQL `pg_dump --format=custom` and ClickHouse
`BACKUP DATABASE analytics, DATABASE kansoku_migration_ledger TO ...`; rehearse their
corresponding restore commands on an owned target. Close timestamps alone do not
prove consistency. A failed backup leaves the fence held and cannot authorize SQL.

Read the exact expected identities, compiled-plan fingerprint, PostgreSQL database,
retention policy and pre-entry coordinator state with:

```bash
"$CH_MIGRATE" maintenance recovery-context --json > /secure/recovery-context.json
```

The manifest has exactly these fields: `schemaVersion` (1), `id` (new UUID),
`target`, `servers` (complete UUID inventory), `ledger`, `session`, `predecessor`,
`planSha256`, `drainSha256`, `postgresDatabase`, `retentionPolicy`, `coordinatorState`,
`stableFrom`, `stableUntil`, `coordinatorSnapshotPhase`, `backgroundChangesSettled`,
`operatorAttested` and `snapshots`. Copy expected context values exactly; hash the
actual drain file for `drainSha256`. Use UTC timestamps. The stable interval starts
after completed drain and ends no later than drain expiry; it must still be current
when acceptance occurs. Set the phase to `fenced-before-native-entry` and both
attestations to true only after establishing them.

Each of exactly three `snapshots` contains `store` (`postgresql` or `clickhouse`),
`database`, `startedAt`, `completedAt`, `artifactReference`, `artifactSha256`,
`verificationReference`, `verificationSha256` and `complete` (true). Use the actual
PostgreSQL database name and the two fixed ClickHouse names. References identify
retained artifacts/receipts; hashes are 64 hexadecimal SHA-256 characters. Every
capture must finish within the stable interval before validation. Unknown fields,
partial coverage, foreign identities, policy/state mismatch or late receipts fail
before consuming the predecessor counter.

Acceptance is retained by session and compiled plan. A retry may omit the file or
resupply its exact bytes, but still needs fresh owner-bound drain. Another owner or
changed plan needs a new set. A proven-empty native installation records a separate
fresh-empty exception; initialization flags cannot exempt a populated target.
Changing the configured UUID does not authorize recovery; use explicit adoption below.

## Verify a renamed restored copy read-only

`verify-restored` uses a separate inspection connection and explicit scratch
names. It needs neither PostgreSQL nor a maintenance session and never authorizes
migration or rebuilt-server adoption. Both live names (`analytics` and
`kansoku_migration_ledger`), equal names and invalid identifiers are refused.
Keep the original logical target/ledger IDs; the observed server UUID and physical
scratch databases identify the copy being inspected.

The embedded version-1 schema expectation was derived by applying the actual
immutable plan to the qualified native `26.8.28.14` artifact. It covers 45 objects
and 284 columns and records the derivation artifact's digest. This initially
qualifies the direct Atomic-database shape; other engines/versions require their
own reviewed expectations and are refused. Remote version/UUID observations do
not attest remote executable bytes. Existing exact toolkit qualification remains
in force.

Give a dedicated verifier SELECT on both restored databases and on
`system.databases`, `system.tables`, `system.columns`, `system.storage_policies`,
`system.disks` and `system.users`. Set `readonly=2`: it forbids writes while allowing
the public toolkit's bounded synchronous query settings. Mode 1 rejects its
`async_insert` setting before inspection. Do not grant CREATE, INSERT, ALTER, DROP,
temporary-table, access-management, query-kill or cross-user process visibility.
The fixture independently denies temporary-table creation and captures every
verifier request; all are SELECT statements. The expected view definer must exist;
this check does not change or certify its deployment-specific grants.

Load only the separate credentials; there is no fallback to live mutation credentials:

```bash
export KANSOKU_CH_RESTORE_USER=restored_verifier
export KANSOKU_CH_RESTORE_PASSWORD='...'
"$CH_MIGRATE" restored-expectations --json > /secure/schema-expectations.json
plan_sha="$(jq -r .result.planSha256 /secure/schema-expectations.json)"
"$CH_MIGRATE" verify-restored --json \
  --endpoint "$RESTORED_ENDPOINT" --server "$OBSERVED_SERVER_UUID" \
  --original-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --original-ledger "$KANSOKU_CH_MIGRATION_LEDGER_ID" \
  --application-database analytics_restore_rehearsal \
  --ledger-database kansoku_migration_ledger_restore_rehearsal \
  --expect-plan-sha256 "$plan_sha" --expected-definer "$REVIEWED_DEFINER" \
  --expected-policy /secure/restored-point-policy.json > /secure/restore-report.json
```

The expected-policy file is the retained PostgreSQL retention-policy
object from the recovery point, including `days`, `revision` and `cutoff`; use
that point's evidence rather than current live policy or observed TTL text. Even
an unused policy needs explicit revision-zero/null-cutoff expectations. Instead
of `--expected-policy`, a global `--recovery-set FILE` may supply the retained
policy from a manifest with the same original target, ledger and compiled plan.
That use supplies inspection expectations and does not authenticate a restore.

Exit zero requires a compatible, current, resolved ledger and matching schema.
The JSON reports `ledger.compatible/current/unresolved`, `schema.status`,
`schema.matches` and mismatch labels, together with observed mappings, plan and
expectation digests. A compatible older prefix reports `current=false` and exits
nonzero. Missing/extra objects, changed columns/defaults/codecs, engine/key/TTL
changes, foreign references, unavailable metadata or unsupported syntax cannot
produce a full pass. Data literals and unrelated identifiers are preserved while
only structural relation positions map scratch names. Physical restore UUIDs are
not logical schema identity.

Supported retention changes are constrained to the application's exact DELETE TTL
expression and the retained cutoff at native millisecond precision, with the
restored retention-policy relation cross-checked. The qualified metadata may omit
its default `DELETE` keyword; that equivalent representation is accepted. A
matching ledger alone never excuses schema drift. Session-local temporary identity
caches are not durable application schema and are neither created nor exercised
by inspection. Every result remains `mode=scratch-inspection` and
`authorizedForMutation=false`.

When appending migrations, derive new expectations on an owned target with
`scripts/generate_clickhouse_schema_expectation.py`; review the resulting
`kansoku-server/migrations/clickhouse/schema-expectation.json`. The deterministic
schema contract and archive gates bind it to the compiled plan. Source-archive
qualification verifies its embedded digest with migration inputs withheld and
rejects a deliberately mismatched plan fingerprint. Never generate expectations
by accepting the current live schema or rewriting applied SQL.

## Nagare receipt mapping

The maintenance facility tracked by
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31` is already delivered.
The recipe was checked against the upstream `v0.20.0` tag on 2026-11-13; this is
source-level mapping, not evidence of an exercised Nagare installation. EP-53
retains the actual deployment execution gate.

Persist Kansoku's fence first. Stop all remaining submitters/read schedules,
including old clients using migration credentials. For each PostgreSQL and
ClickHouse app-database membership, review and apply a runtime-only quiesce plan:

```bash
nagarectl db app-database quiesce "$APP_DATABASE" -n "$NAMESPACE" \
  --users runtime --save-plan /secure/nagare/quiesce
nagarectl inventory apply /secure/nagare/quiesce --yes
nagarectl db app-database evidence "$APP_DATABASE" -n "$NAMESPACE" --json
```

Use distinct retained plan directories for the two memberships. Runtime-only
quiescence pauses their backup schedules and leaves the migration principal usable
for the coordinator, backups and migration. It does not exclude arbitrary external
clients using that principal; retain their separate exclusion/drain proof. Confirm
background logical changes are settled and map the evidence into Kansoku's exact
owner/predecessor envelope. Refuse if any required exclusion is missing.

Within that same stable interval, review/apply one on-demand backup per membership,
then ingest each resulting Job UID as a verified receipt:

```bash
nagarectl db app-database backup "$APP_DATABASE" -n "$NAMESPACE" \
  --save-plan /secure/nagare/backup
nagarectl inventory apply /secure/nagare/backup --yes
nagarectl db app-database backup-receipts "$APP_DATABASE" -n "$NAMESPACE" \
  --backup-id "$JOB_UID" --save-plan /secure/nagare/ingest
nagarectl inventory apply /secure/nagare/ingest --yes
```

Require the PostgreSQL receipt to cover the complete Kansoku/queue/coordinator
state. Require the ClickHouse membership and archive to cover both analytics and
the native ledger; represent that archive with two explicit manifest entries.
Map actual capture times, immutable artifact hashes and verified receipt references
into the generic recovery set. Two successful Jobs without that coverage and stable
interval are insufficient. Keep the final manifest outside both snapshots. Complete
Kansoku's migration/verification/finish ceremony before separately reviewing/applying
`db app-database resume` for each membership and resuming external schedules.

## Rebuilt direct-server adoption

Keep the restored installation fenced and every unrelated submitter externally
blocked. Restore the whole recorded set, including the original PostgreSQL active
session and unresolved receipts. Retain the original manifest and drain file.
Configure the candidate endpoint and its explicit new server UUID, keeping target,
logical ledger and session IDs. Ordinary session loading refuses the old binding.
Rebuilt replicated-inventory adoption is not qualified by this command.

Read the candidate with `maintenance recovery-observation --json`. This uses the
public toolkit's read-only qualified-target/history inspection, permits unresolved
attempts for subsequent repair, and rejects incompatible definitions. It changes
no binding. Verify all three restored stores against the recorded artifacts and
retain a separate live restore receipt. Scratch inspection alone is insufficient.

That receipt is bounded JSON with exactly: `schemaVersion` (1), `mode`
(`live-recovery`), `target`, `oldServer`, `newServer`, `ledger`, `session`,
`recoverySetId`, `recoverySetSha256` (hash of the original manifest bytes),
`ledgerSha256` (the verified observation fingerprint), `inspectedAt`, `expiresAt`,
`allStoresRestored` (true) and `operatorAttested` (true). It records an operator
verification of the whole restore, not an automatic artifact download/check.
Compare its history fingerprint with the retained original observation, and
independently verify restored application/queue/coordinator contents. Establish
fresh new-server drain, bound to the restored session's predecessor. The receipt
must still be current and expire no later than that exclusion.

```bash
"$CH_MIGRATE" --recovery-set /secure/original-recovery-set.json \
  --drain-evidence /secure/rebuilt-drain.json maintenance rebind --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --old-server "$ORIGINAL_SERVER_ID" --new-server "$KANSOKU_CH_MIGRATION_SERVER_ID" \
  --original-drain /secure/original-drain.json \
  --restore-verification /secure/live-restore.json \
  --actor "$USER" --reason 'verified whole recovery-set restore' \
  --evidence /secure/live-restore.json > /secure/rebind-report.json
```

The operation acquires administrator/traffic exclusion, validates exact restored
policy and coordinator state against the original backup boundary, observes the
candidate ledger, and atomically changes only the active session's server binding
with its audit and retained recovery set. It preserves counters, receipts, outcome
and the persistent fence. `maintenance status --json` now loads the new binding.
Repeating the exact request returns its original audit without another transition;
retain that report after a lost response. Conflicting identities or manifests fail.
Existing reconciliation/repair still resolves interrupted work with fresh drain
and exact pending receipts. Adoption never marks an unresolved entry successful
or releases its fence. Verify currentness and finish through the ordinary ceremony.

## Interruption, receipts and explicit repair

Keep the session fence active and preserve stdout/stderr reports, pending receipts and private
diagnostics. Read-only `status`, `history`, `verify` and `maintenance status` remain available.
Stop submitting clients, establish external drain, then inspect fresh guarded history. Each
entry increments the persistent predecessor counter before native SQL, including failed entries.
A stale counter, wrong target or mismatched session/server/ledger identity refuses entry.

`maintenance status --json` exposes `outcome`, `entry` and `pending_receipts`. A killed process
leaves `outcome=submitted`; an observed failure leaves `outcome=failed`. These states block
ordinary up and finish even if a lost ledger response later appears current. Retain every exact
receipt, including secondary recording failures. Supply all of them with repeated
`--pending-append RECEIPT` options to reconciliation or repair.

Explicit reconciliation performs native reads under exclusion. It acknowledges only compatible,
resolved history after external drain; `NotObserved` alone is never permission to submit SQL:

```bash
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
"$CH_MIGRATE" --drain-evidence /secure/current-drain.json --predecessor "$predecessor" maintenance reconcile --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" --actor "$USER" \
  --reason 'reconcile retained response loss after external drain' \
  --quiescent --evidence "$DRAIN_EVIDENCE" \
  --pending-append "$RETAINED_RECEIPT"
```

Omit the receipt option only when none is retained. `resolved=false` keeps the outcome pending;
use a selected repair operation with fresh native position/attempt metadata. `PresentIdentical`
is an exact recorded event observation, not proof that unrelated requests have drained.
Interrupted initialization can reconcile absent/uninitialized history only while application
objects remain absent, or resume the matching initialized native ledger. It retains the original
UUID in either case.

Use `repair --help` and the selected operation's help for exact syntax. After external drain,
capture fresh guarded status and the current predecessor counter:

```bash
"$CH_MIGRATE" status --guarded --json > .dev/migration-audit/status.private.json
predecessor="$("$CH_MIGRATE" maintenance status --json | jq -r .result.entry)"
```

From that report, retain `.result.report.observation.position`, the active migration's `attempt`
in `.result.report.migrations`, and the selected step's `attempt.ownerAttempt`, `attempt.step`
and `attempt.queryId` in its `steps` array. Set `POSITION`, `ATTEMPT`, `STEP_ATTEMPT`, `STEP`
and `QUERY_ID` from those reviewed values, and set `DRAIN_EVIDENCE` to fresh evidence for this
session/counter. Do not select a different step merely because a prior command failed:

```bash
"$CH_MIGRATE" --drain-evidence /secure/current-drain.json --predecessor "$predecessor" repair accept-step --json \
  --expect-target "$KANSOKU_CH_MIGRATION_TARGET" \
  --expect-position "$POSITION" --attempt "$ATTEMPT" \
  --step-attempt "$STEP_ATTEMPT" --step "$STEP" --query-id "$QUERY_ID" \
  --actor "$USER" --reason 'independently verified selected effect' \
  --quiescent --evidence "$DRAIN_EVIDENCE"
```

Include every retained receipt when applicable. `accept-step` attests an observed effect and
sends no application SQL. `retry-step` executes only its explicitly selected statement and can
repeat an effect; it gives no exactly-once guarantee. `resume` runs only never-started steps of
the active migration, then completes that migration. `finalize` records completion of fully
resolved steps without application SQL. Neither accept nor retry automatically runs the suffix.
Every subsequent operation needs fresh counter/position/attempt/evidence as applicable. Unknown
requests, active native work, incompatible definitions and cleanup errors preserve the fence.


## Replicated targets

Set both `KANSOKU_CH_MIGRATION_CLUSTER` and `KANSOKU_CH_MIGRATION_REPLICA_IDS`
(a comma-separated list of server UUIDs), and remove `KANSOKU_CH_MIGRATION_SERVER_ID`
entirely. Empty values are present values and are refused. UUIDs are validated, whitespace
around CSV entries is trimmed, duplicates are refused, and the complete inventory is sorted.
Changing the cluster, topology, or any UUID refuses a retained PostgreSQL session.
Online native JSON reports include `selectedTarget`, naming the topology and the
cluster/replica inventory (or direct server UUID).
Run PostgreSQL migrations first, including `0008-clickhouse-replicated-administration`.
Existing direct sessions retain their fences, receipts and identities across this upgrade.

With neither replicated selector present, direct installations keep their original component,
immutable 25-migration/257-step prefix and checksum v1 history, followed by 0026. Replicated installations use the separate
`kansoku_replicated` component (immutable 25-migration/254-step prefix, then the seven-step 0026 suffix) and a fresh checksum v2 ledger.
A direct ledger cannot be adopted or converted. Operators must pre-create both `analytics`
and `kansoku_migration_ledger` as Replicated databases. Persistent tables use Replicated engine
families without explicit Keeper paths or replica arguments; replacement version columns remain.
The empty schema inference in 0020 uses `EMPTY AS SELECT`; its separate backfill remains.
Memory tables exist only during the two historical native assertion groups.

Offline inspection needs only the topology selectors:

```bash
env -u KANSOKU_CH_MIGRATION_SERVER_ID \
  KANSOKU_CH_MIGRATION_CLUSTER=fixture \
  KANSOKU_CH_MIGRATION_REPLICA_IDS=11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222 \
  kansoku-ch-migrate plan --json
```

The maintenance begin/up/guarded verify/finish lifecycle and all existing audit, ledger UUID,
session UUID and predecessor requirements apply. Before fresh initialization, bounded local
observations must cover every configured UUID and verify both database engines. The endpoint
must route fresh HTTP connections to every expected replica within 35 seconds and at most
64 observations (each response is limited to 64 KiB). An unexpected replica or exhausted
coverage fails closed. A matching initialized ledger permits interrupted recovery with existing
application tables, while replica coverage and database engines remain required.

Drain evidence must cover all replicas and all submitting clients, including external SQL
schedules. Failed observations, timeouts and process disappearance do not prove drain and do
not release the PostgreSQL fence. Retain identities and exact receipts for explicit recovery;
never delete only analytics or replace an existing ledger UUID. Owned round-robin acceptance
is separate from qualification of a managed endpoint, deployment permissions, and replicated
application or data-maintenance behavior.

## Runtime topology after migration

The replicated baseline alone does not establish write/read/maintenance
consistency. Pass the same cluster and complete UUID inventory selectors to the
runtime and data-job CLI. They share the strict core topology parser while
migration commands retain their additional direct-server identity requirement.
PostgreSQL migration `0009-clickhouse-replicated-jobs` appends a persisted target
identity for data jobs; existing jobs remain direct-only. Migration session
identity and immutable direct/replicated native histories retain their original
contracts.

Use [the runtime operating policy](operations.md) and
[replicated administration](administration.md) for quorum acknowledgement,
synchronized read-back and all-replica repair/resume. The owned runtime recipe
reuses actual migration initialization on a fresh exact-candidate cluster, then
adds native driver and production executable fault cases. Its private native
ports are resolved only from the live fixture's reported endpoints and verified
UUIDs; the migration fixture's special query-test deduplication controls are not
applied to writer qualification.

## Selected TAN production target

The selected target is Altinity.Cloud `tan-production`, exact
`26.3.60.10002.altinitystable`, one shard/two replicas, HTTPS on 8443 and verified
native TLS on explicit port 9440. See the
[target dossier](../evidence/tan-production-target.md) for source observations,
coverage and the dated owner-accepted residual risks. Selection is not managed certification.
Per-connection UUID/version/cluster/settings admission fails closed but does not
establish full provider routing or independent replica inventory. TAN must verify
all expected UUIDs, healthy writable Local default storage/fsync, grants, external
drain and managed migration/event-flow rehearsal. Preserve fences after uncertain
submission. A direct staging rollout cannot replace replicated acceptance or
retained migration image/session/ledger inputs.

The published [TAN artifact record](../evidence/tan-production-qualified-artifact.json) uses the replicated offline native plan hash. Keep direct and replicated hashes distinct; raw CLI stdout includes its final newline. Publication does not create a managed ledger or perform production migrations.

## Diagnostic session engagement upgrade

`0026_diagnostic_session_engagement` excludes the exact names `client_error` and `web_vital`
from engagement for every stored version, including versionless rows. Both still contribute to
the first/last timestamps and observed duration. Purchase and other application actions still
remove a one-page bounce. Existing engagement sets cannot remove old diagnostic IDs, so this
migration replaces `mv_sessions`, clears `sessions`, replays retained canonical facts using the
applied retention cutoff, and asserts equality of every finalized session field. It leaves raw
events and other derived populations intact. Discarded raw history cannot be recovered.
Installations that have not applied 0026 retain the old aggregate classification.

Use the begin/up/guarded verify/finish commands in **Subsequent native migration** above.
Deploy the matching application binary and migration in this same maintenance window: stop
application traffic and external SQL readers/writers/schedules before beginning; preserve the
existing target, ledger and session identities; establish and record external drain before
each mutating entry. Run `up`, then `verify --require-current --guarded --json`. Establish fresh
drain evidence and run `maintenance finish`. Finish checks the full canonical/materialized
session projection again while fenced. Resume traffic only when finish succeeds, so canonical
and materialized queries never intentionally serve different classifications.

Replicated operators also need `SYSTEM SYNC DATABASE REPLICA`, `SYSTEM SYNC REPLICA`, `CLUSTER` and
`REMOTE` privileges. The coordinator validates the cluster UUID inventory, synchronizes the
Replicated schema and `events_raw`, `retention_policy`, `sessions` tables, and observes an empty
session target on every expected UUID before the single replay. Completion and finish repeat
synchronization and require canonical agreement on each UUID. A missing replica, barrier error,
permission refusal or verification failure retains the fence. Native reconstruction retains the toolkit's protected sequential-read and full INSERT-quorum
policy. Retained replicated data must follow the supported synchronous quorum-write contract.
Independent complete-history verification reads all synchronized canonical facts
(`select_sequential_consistency=0`); omitted nonquorum history prevents completion and fence
release. Diagnose that history under the same fence and reconcile it to the supported write
contract before retrying; do not hide it by weakening verification or releasing maintenance. The endpoint must cover the
complete expected inventory; discovered hostnames never redirect credentials.

If interrupted after clear, keep maintenance active and follow **Interruption, receipts and
explicit repair** above. Preserve exact receipts and reconcile them with fresh drain evidence.
Inspect fresh guarded status and independently observe the selected effect on every replica:
accept a completed clear only when all session targets are empty, then `repair resume` runs
the never-started replay and checks. Do not blindly rerun clear after replay may have succeeded.
An uncertain replay requires determining whether it completed before accepting or retrying its
selected step; the pre-replay empty-target barrier refuses replay into populated state. If a
full clear/rebuild is needed, retain the same fence and deliberately repair the selected state;
do not start a separate data-maintenance job while the migration owns it. A repeated clean
`up` submits no application SQL. Restoring separately reviewed consistent backups to an isolated
target remains the rollback procedure.

`just ch-migrations-replicated` uses Apple Container with the exact digest-qualified Linux arm64
image, owned Keeper and two replicas with 4 GiB per replica for the full native query fixtures. Failed fixture evidence is retained under `.dev/acceptance`.
This local execution is separate from managed endpoint qualification.

## Owner-bound drain envelope

The outer `--drain-evidence FILE` option accepts a version-1 operator attestation
for `up`, repair, maintenance reconciliation and finish. Put it before the
subcommand, alongside `--predecessor`. Existing `--quiescent`, audit references
and target checks remain required. The envelope is mandatory for every mutating
entry, reconciliation and finish. Dedicated-server operators produce the same
envelope after stopping submitters and restarting their owned server. Shared-server
operators establish app-scoped exclusion and drain without a restart.

Set `KANSOKU_CH_DRAIN_SUBMITTERS` to a JSON array listing every deployment principal
that can submit Kansoku work, including migration, backup and scheduled-reader
principals. This trusted configuration must be independent of the evidence file.
The evidence must list the current migrator in `availablePrincipals`: the migrator
can remain available while its earlier work is drained and other submitters are
excluded. No platform subprocess is launched by Kansoku.

The bounded JSON object has exactly these fields: `schemaVersion` (1), `target`,
`servers` (complete UUID array), `ledger` (UUID or null), `databases` (exact names),
`submitters`, `availablePrincipals`, `owner`, `exclusionStartedAt`, `drainedAt`,
`expiresAt`, `procedureReference`, `procedureSha256`, `submittersBlocked`,
`schedulesPaused`, `backgroundChangesSettled`, and `operatorAttested`. All four
attestation booleans must be true. A migration owner is an object containing
`kind: "migration-session"`, `id` and nonnegative `predecessor`; a data-job owner
uses `kind: "data-job"`, `id` and positive `attempt`. The latter shape is accepted by `kansoku-admin resume-job --drain-evidence FILE`.

The file is limited to 64 KiB; inventory arrays contain at most 128 distinct,
nonempty entries. Text fields contain at most 1024 characters and no control
characters. Times are UTC JSON timestamps: drain follows exclusion and the persisted predecessor timestamp; expiration follows
the current time. Continuous exclusion may span several predecessor drains. An exclusion
interval cannot exceed 24 hours. The procedure digest is 64 hexadecimal characters
identifying externally retained proof. The envelope is retained in the entry's
PostgreSQL audit together with the exact file SHA-256. Expiration is rechecked
after waiting for exclusion. Validation checks identity and declarations; it does not read the
external proof, authenticate a platform signature or prove the attestation true.
A deployment operator must establish and retain the actual exclusion/drain proof.

Run the owned initial producer/consumer proof with:

```bash
nix develop -c python3 scripts/portable_drain_acceptance.py
```

This uses fixture-owned PostgreSQL and ClickHouse instances and the locally built
migration/admin executables. It does not claim packaged, Nagare, complete data-job
or backup/recovery acceptance.

Each consumed migration entry retains its audit document in
`kansoku.clickhouse_migration_entry_audit`, including the portable envelope and
exact input-file digest when supplied. Advancing an entry cannot overwrite a
previous entry's evidence. Audit-write failure prevents native entry and leaves
the previous counter and persistent fence authoritative.
