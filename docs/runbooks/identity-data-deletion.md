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

Delete the user's evidence rows after the raw-event scrubs have been submitted.

```sql
ALTER TABLE analytics.identity_signals
DELETE WHERE account_id = 'ACCOUNT' AND user_id = 'USER';
```

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
identifier kinds. The deployed ClickHouse 26.5.1 supports `mapFromArrays` and
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
