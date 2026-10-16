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

## Organisation attributes and membership

Organisation state lives in `organization_properties` and `user_organizations`. The public
`erase-user` command is not an organisation deletion command: an organisation can be shared
by many people. To remove an organisation's current attributes and membership, an operator
must stop ingest, writer, readers and archive replay, and fence every producer of that account.
Keep that fence until source cleanup and verification finish. This is a manual operation;
there is no shipped `erase-organization` CLI command.

Discover all retained and replayable `group` event IDs with the target account/organizationId,
including PostgreSQL queues, archives, immutable acceptance records and quarantine. Reserve
their account/event IDs with `delete_event=true` in `kansoku.event_dispositions` before
cleaning their payloads, so a held writer batch or accepted-event retry cannot restore them.
Clean the same IDs from replayable payload stores using the administrative workflow's
cross-store source policy. Do not delete another organisation's or account's group records.

Then run this ClickHouse sequence with native String parameters `account` and `organization`.
It removes the organisation's group source writes, not its historical activity or payment
events. Backups require the same operator retention/erasure policy as person data.

```sql
INSERT INTO analytics.trait_event_erasures
SELECT account_id,event_id FROM analytics.events_canonical
WHERE account_id={account:String} AND organization_id={organization:String} AND event_name='group';

ALTER TABLE analytics.events_raw DELETE
WHERE account_id={account:String} AND organization_id={organization:String} AND event_name='group'
SETTINGS mutations_sync=2;

ALTER TABLE analytics.organization_properties DELETE
WHERE account_id={account:String} AND organization_id={organization:String}
SETTINGS mutations_sync=2;

-- Clear the account's membership states before rebuilding; old argMax winners
-- cannot be retracted by inserting newer aggregate states alone.
ALTER TABLE analytics.user_organizations DELETE
WHERE account_id={account:String} SETTINGS mutations_sync=2;

INSERT INTO analytics.user_organizations
SELECT r.account_id,r.user_id,
       argMaxState(r.organization_id,tuple(r.occurred_at,r.received_at,r.event_id)) AS value
FROM analytics.events_canonical AS r
WHERE r.account_id={account:String} AND r.event_name='group'
  AND r.organization_id!='' AND r.user_id!=''
  AND (r.account_id,r.event_id) NOT IN
      (SELECT account_id,event_id FROM analytics.trait_event_erasures)
GROUP BY r.account_id,r.user_id;

SELECT count() FROM analytics.organization_traits
WHERE account_id={account:String} AND organization_id={organization:String};

SELECT count() FROM
  (SELECT account_id,user_id,argMaxMerge(organization_id) AS current_organization
   FROM analytics.user_organizations GROUP BY account_id,user_id)
WHERE account_id={account:String} AND current_organization={organization:String};
```

Both counts must be zero. Check completed mutations and absence of replayable group payloads
before releasing the fence. Repeat the clear/rebuild steps after interruption; never rebuild
by replaying old migrations. A user's earlier retained membership in another organisation may
become current after deletion. Historical events with explicit organisation IDs keep their
event attribution; erasing those facts is a separate full-event deletion with the same source
reservations and cleanup across every derived projection. New immutable group IDs may establish
new attributes or membership. Retention and ordinary administrative rebuilds already include
both organisation state tables and use current canonical projection definitions.
