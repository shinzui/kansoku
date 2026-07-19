# Event schema governance

Kansoku event schemas are a shared portfolio contract. Producers can read the live catalog
without credentials at `GET /v1/schemas`, or use the committed, reviewable copy at
`docs/contracts/events.json`. Both are generated from `defaultRegistry` in
`kansoku-api/src/Kansoku/Event/Registry.hs`; do not maintain a separate schema copy in a
producer repository.

The catalog's top-level `catalogVersion` versions the JSON document shape. Each event's
`versions` array independently versions that event's properties. A property publishes its
name, JSON type, requiredness, validation pattern, and description.

## Declaring a new event

Open a change in this repository and add an `EventSchema` to `defaultRegistry` with:

- the new `EventName`;
- `schemaVersion = 1`;
- a short `schemaNote` explaining the initial contract;
- every enforced property, including its type, requiredness, optional pattern, and useful
  description.

Unknown event names are accepted without registry property checks, so producers may begin
emitting an event before it is declared. Declaration is the point at which Kansoku starts
enforcing that name's published shape.

After editing the registry, regenerate and verify the contract:

```bash
just contracts
just test
git diff -- docs/contracts/events.json
```

Commit the registry and generated artifact together. The golden test fails when the two
disagree. If a route or DTO changed too, also run `just openapi` and commit
`docs/api/openapi.json` in the same change.

## Changing a released schema

Released versions are immutable. Any change creates the next contiguous version, including:

- adding an optional property;
- changing a description, validation pattern, type, or requiredness;
- removing or renaming a property.

Copy the previous full `EventSchema`, increment `schemaVersion` by one, make the change, and
write a note that says what changed. Keep every older entry. Do not edit version 1 in place:
the generated artifact will show a changed block with the same version number, which reviewers
must reject.

`registerSchema` sorts versions and makes construction idempotent, while the test suite pins
the released-registry invariants: versions are exactly `1..n`, schema names match their map
keys, notes are non-empty, and property names are unique within a version.

## Pinning a producer

Set `schemaVersion` on each event to the version the producer implements. In the Haskell SDK:

```haskell
trackEventWithVersion client ids "page_view" 1 ["url" Aeson..= pageUrl]
```

Other clients send the same integer as the JSON key `schemaVersion`. Omitting the field means
version 1, never latest; this preserves legacy producers when a later version is released.
The Haskell SDK's `fetchSchemaCatalog` can load the live contract for startup or CI checks.

For a known event name, Kansoku validates the exact requested version. An unknown version is
HTTP 400 and names the known versions. Versions outside `1..65535` are invalid because the
persisted ClickHouse column is `UInt16`. An unknown event name remains permissive when its
declared version is in range.

## Compatibility and analytics

Keep older versions available as long as producers can emit them. Adding a new version does
not move versionless traffic forward. Property-based metric compilation uses the latest
declared schema; version-specific metric dimensions are not currently exposed.

Every accepted event persists its effective version in `analytics.events_raw.schema_version`:

```sql
SELECT event_name, schema_version, count()
FROM analytics.events_raw
WHERE occurred_at >= now() - INTERVAL 7 DAY
GROUP BY event_name, schema_version
ORDER BY event_name, schema_version;
```

Use this distribution to find legacy producers before retiring application support for an
older shape. Do not infer a producer version from property presence when the explicit column
is available.

Portfolio documentation in kikan and mori may point to `docs/contracts/events.json` or the
live endpoint, but Kansoku remains the authoring source of truth. See ADR 0007 and EP20's
ExecPlan for the design rationale and acceptance evidence.
