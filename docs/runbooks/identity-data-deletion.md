# Identity data deletion and fingerprint retention

This runbook removes identity-linking data for one user inside one Kansoku account. It
scrubs identifier values from raw events, removes that user's signal evidence, and
describes the periodic mutation that aligns raw fingerprint data with the 180-day TTL on
`analytics.identity_signals`. It does not delete general analytics facts unless the
optional full-event step is selected.

These ClickHouse mutations rewrite data parts asynchronously and cannot be undone. They
are expensive on large tables. Run them off-peak, for one account at a time, save the
read-only discovery output before changing anything, and test substitutions in a
non-production account first. Never omit the `account_id` predicate.

This is ClickHouse identity unlinking, not the complete cross-store erasure workflow. Fence
writers and replay while mutating; queued or archived old payloads must be handled by the
administrative lifecycle owner before resuming. Full erasure also covers replayable inputs,
acceptance tombstones and derived analytical states; that executable workflow is owned by
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`.

## Per-user identity erasure

Set `ACCOUNT` and `USER` to the exact escaped values for the request. Step 1 is read-only
and must run first; save its result because later steps destroy the evidence that
discovers linked values.

```sql
SELECT DISTINCT signal_kind, signal_value
FROM analytics.identity_signals
WHERE account_id = 'ACCOUNT' AND user_id = 'USER'
ORDER BY signal_kind, signal_value;
```

Partition the saved values into two substitution lists:

- `ALL_VALUES` contains values from every kind and is used to remove entries from the
  `identifiers` JSON object.
- `COOKIE_VALUES` contains only rows whose kind is `cookie` and is used to clear the
  implicit cookie stored in `anonymous_id`.

First scrub the requested user's explicitly identified events. Clearing `anonymous_id`
as well as `identifiers` prevents the identify event itself from retaining a cookie link.

```sql
ALTER TABLE analytics.events_raw
UPDATE identifiers = '{}', anonymous_id = ''
WHERE account_id = 'ACCOUNT' AND user_id = 'USER';
```

Then scrub anonymous events that carry any saved mapped identifier. Substitute the
literal values from `ALL_VALUES` into the `IN` list.

```sql
ALTER TABLE analytics.events_raw
UPDATE identifiers = '{}'
WHERE account_id = 'ACCOUNT'
  AND user_id = ''
  AND arrayExists(
        kv -> kv.2 IN ('VALUE1', 'VALUE2'),
        JSONExtractKeysAndValues(identifiers, 'String'));
```

Clear implicit cookie values on anonymous events separately. Substitute only
`COOKIE_VALUES`; if step 1 returned no cookie rows, skip this statement.

```sql
ALTER TABLE analytics.events_raw
UPDATE anonymous_id = ''
WHERE account_id = 'ACCOUNT'
  AND user_id = ''
  AND anonymous_id IN ('COOKIE1', 'COOKIE2');
```

For a request that requires deletion of the user's explicit analytics facts rather than
identity unlinking alone, use this optional larger hammer after the discovery output has
been saved. Do not broaden it to inferred anonymous events: probabilistic signals can be
shared, so doing so could delete another person's facts.

```sql
ALTER TABLE analytics.events_raw
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';
```

Delete the user's evidence rows and both exact lookup indexes after the raw-event scrubs
have completed. This includes every signal kind, including email_hmac.

```sql
ALTER TABLE analytics.identity_signals
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

ALTER TABLE analytics.identity_signal_users
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

ALTER TABLE analytics.identity_session_users
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';

-- Remove contexts containing a saved cookie or mapped value. These fields are
-- server-written Tuple(source_service,session_id,anonymous_id,identifiers).
ALTER TABLE analytics.identity_context_signals
DELETE WHERE account_id = 'ACCOUNT'
  AND (context_key.3 IN ('COOKIE1','COOKIE2') OR arrayExists(
        kv -> kv.2 IN ('VALUE1','VALUE2'),
        JSONExtractKeysAndValues(context_key.4,'String')));
```

If no saved cookies/mapped values exist, omit their respective predicates rather than inventing
placeholders. Mutation does not feed materialized views. After all raw and evidence mutations finish, rebuild all identity projections from canonical,
already-scrubbed facts with migration 0018 while the writer stays stopped. This restores the
contexts for remaining anonymous identities as well as removing erased values; deleting old
context rows alone cannot reconstruct the scrubbed context. The migration also materializes
the raw context key. It must run only after the raw mutations finish. HTTP's physical
query connections detect completed index mutations or replacement by part/table identity and
refresh their private snapshots. Deleting only identity_signals leaves cached/indexed links.

All preceding `ALTER` statements are asynchronous by default. Watch them until no
matching work remains and investigate any non-empty failure reason. In a controlled test
environment, append `SETTINGS mutations_sync = 2` to an `ALTER` statement to wait for
all replicas.

```sql
SELECT database, table, mutation_id, command, is_done, latest_fail_reason
FROM system.mutations
WHERE database = 'analytics' AND is_done = 0
ORDER BY create_time;
```

Finally verify that no evidence for the user remains, that their raw mapped identifiers
and cookies are absent, and that formerly stitched anonymous events now fall back to
their remaining local identity (or the empty string when the cookie was erased).

## Raw fingerprint retention

The table TTL automatically deletes fingerprint evidence after 180 days. Raw events still
hold their source JSON, so run the following account-independent maintenance mutation on
the same retention cadence. It removes only the fingerprint key and preserves other
identifier kinds. The packaged ClickHouse 26.8.2.7 supports `mapFromArrays` and
`toJSONString`; verify the expression on a sample before adopting a different version.

```sql
ALTER TABLE analytics.events_raw
UPDATE identifiers = toJSONString(mapFromArrays(
        arrayMap(
            kv -> kv.1,
            arrayFilter(
                kv -> kv.1 != 'fingerprint',
                JSONExtractKeysAndValues(identifiers, 'String'))),
        arrayMap(
            kv -> kv.2,
            arrayFilter(
                kv -> kv.1 != 'fingerprint',
                JSONExtractKeysAndValues(identifiers, 'String')))))
WHERE occurred_at < now() - INTERVAL 180 DAY
  AND JSONHas(identifiers, 'fingerprint');
```

If those functions are unavailable after a ClickHouse change, use the conservative
fallback below. It also removes other identifier kinds from matching old rows, so record
that broader effect in the incident or maintenance log.

```sql
ALTER TABLE analytics.events_raw
UPDATE identifiers = '{}'
WHERE occurred_at < now() - INTERVAL 180 DAY
  AND JSONHas(identifiers, 'fingerprint');
```


`events_raw.identity_context_key` is a materialized, lossless encoding of account, source
service, session, anonymous ID and the original identifiers object. It contains identity data.
Whole-row erasure removes it with the row. Any workflow that scrubs raw identity fields in
place must recompute/materialize this column before reopening queries and rebuild the context
index; deleting only the original map leaves another copy. Keep writers and replay fenced
through that operation and the index replacement.
