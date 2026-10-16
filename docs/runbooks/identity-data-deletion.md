# Identity erasure and fingerprint retention

Use the shipped [administrative workflow](../guides/administration.md). It coordinates
PostgreSQL sources, canonical facts, current identity/context indexes, whole sessions,
metric states and both governed trait states under a persisted fence. Raw-table mutations
alone cannot supply those guarantees.

```bash
kansoku-admin erase-user --account account_123 --user user_42
kansoku-admin erase-user --account account_123 --user user_42 --confirm
kansoku-admin erase-user --account account_123 --user user_42 --delete-events
kansoku-admin erase-user --account account_123 --user user_42 --delete-events --confirm
```

Default unlinking removes current traits and matching cookie/mapped/session links but can
retain explicit user IDs and arbitrary historical JSON. Explicit deletion also removes
that user's identified facts. Shared evidence never authorizes deleting another user's
anonymous facts. Retained logical identities prevent supported retries/archive replay from
restoring erased facts or traits. New IDs can establish new observations. Backups and
unknown personal text in arbitrary JSON require operator policy.

```bash
kansoku-admin list-jobs --limit 20
kansoku-admin job-status --id JOB_UUID
kansoku-admin resume-job --id JOB_UUID --confirm
```

A failed job keeps its fence. Resolve unfinished/failed native mutations or missing current
projections and resume; do not manually clear the fence or reapply old migrations. The tool
rechecks batches held in writer memory before insertion. Optional --out must name a new file:
receipts are exclusive 0600 files with redacted counts; full unfinished discovery stays in
PostgreSQL, which owns the current job stage.

Fingerprint lookup evidence has a separate 180-day TTL. Apply physical raw/source cleanup
even when keeping ordinary events indefinitely:

```bash
KANSOKU_EVENTS_RETENTION_DAYS=0 kansoku-admin apply-retention
KANSOKU_EVENTS_RETENTION_DAYS=0 kansoku-admin apply-retention --confirm
```

Preview includes the fingerprint cutoff. Cleanup preserves other identifier kinds, refreshes
the materialized context key, rebuilds identity state and cleans existing replay/diagnostic
sources. The persisted cutoff sanitizes later writer attempts. New rejected diagnostics keep
the original-payload/quarantine-retention contract until subsequent cleanup. Schedule explicit
runs to advance the applied cutoffs. Positive event days additionally expire whole events and
profiles; read [policy boundaries](../guides/administration.md#applied-event-and-fingerprint-retention)
before changing the setting.
