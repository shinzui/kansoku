# Develop Kansoku

Use `nix develop`, then `cabal build all --enable-tests` and `cabal test all` for
local builds and tests. Storage/live-client tests report pending when their optional
prerequisites are absent; a passing optional run does not establish executable or
database acceptance. The dedicated isolated commands described in the plans require
real native cases and fail missing prerequisites.

All four local packages share GHC2024, explicit deriving strategies, overloaded labels
and fatal `-Werror=missing-fields`. Every local library, executable and test imports
its package's `common` stanza. A new NamedRoutes field must have an explicit handler;
omitting one fails compilation. Keep the route-dispatch tests too: swapping same-typed
handlers can still compile.

Use strict fields in data records, without type prefixes in field names. Newtypes
keep their permitted unwrapping functions and cannot have strictness annotations.
Manipulate project records with generic-lens (`^.`, `.~`, `?~`, `%~`), importing
`Data.Generics.Labels ()` in each manipulation module. Keep that orphan import out of
`Kansoku.Prelude` and pure type-definition modules; constructor pattern matching is
appropriate there. The prelude alone keeps PackageImports local to its package pins.

Servant route selectors have type-family limitations and may use qualified selector
application. External-library records such as WAI Request, HTTP Request, ServerError
and Aeson Options retain their library's ordinary record-update API. Native driver
wire-column records retain ClickHouse's required names. Dynamic SQL assembly remains
explicit code; adopting MultilineStrings does not require rewriting dynamic fragments.

The internal registry's PropertySpec fields are name, propertyType, required,
validationPattern and description. EventSchema uses eventName, version, note and
properties. These internal names do not change event JSON or released schema versions.
[Schema governance](../event-schema-governance.md) and
[ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md) still require
immutable released event schemas.

Regenerate `docs/api/openapi.json` with `just openapi` and
`docs/contracts/events.json` with `just contracts`. Source-only convention changes
must preserve both artifacts byte-for-byte. `nix fmt` formats owned source; the
pinned third-party snapshot under `vendor/` keeps its upstream formatting.

The baseline conventions are documented at
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`,
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`, and
`mori://shinzui/haskell-jitsurei/docs/api-servant-routes`.
