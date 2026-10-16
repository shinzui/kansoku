---
type: Guide
title: "Develop Kansoku"
description: "Build and test Kansoku, follow source conventions, regenerate contracts, and run isolated acceptance gates."
docId: DOC-6
tags: ["development", "testing", "contracts", "haskell"]
generated:
  by: process:codex
  at: "2026-10-16T17:56:53Z"
---

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

Run `nix develop -c just check` for build-with-tests, source formatting, deterministic tests,
probe tests, generated OpenAPI/schema drift, OpenAPI 3.1 lint, strict ADR validation and HTTP
telemetry privacy/lifecycle checks. Deterministic subsets explicitly exclude native/live cases
and reject zero or pending examples. Regenerate intentionally with `just openapi` and
`just contracts`; the drift checks preserve the existing artifact bytes even when they fail.

Run `nix develop -c just acceptance` for disposable database and Nix-packaged server acceptance.
It runs all core tests, the probe kit and live SDK tests with prerequisites required, then Hurl
resource families, native recovery/cardinality checks and exported telemetry privacy. It owns
fresh processes and data rather than using development databases. See the
[HTTP suite guide](../../kansoku-api/test/hurl/README.md) for fixture and private-log handling.
`just hurl` runs the explicit safe subset against an already running loopback fixture server.
CI runs both aggregate gates and Nix package/flake checks; it has no publishing step.

## Saved-resource acceptance fixtures

Run `nix develop -c just fixture-isolation-acceptance` to compose custom metrics and cohorts
twice on fresh owned stores. The check compares complete saved-definition baselines in both
accounts and injects failures after membership upload. It verifies explicit membership
clearing, retention of the original failure, continued cleanup after a cleanup error, and
survival of an unrelated resource. The packaged acceptance suite requires the same verifier.

Register each successfully created saved definition with `OwnedResources` in
`scripts/acceptance_resources.py`, using its returned ID and originating credential. Scope
scenario work with the context manager so assertion failures still finalize resources. Delete
saved metrics before clearing and deleting their cohorts. Only an already-absent owned 404
is benign; other cleanup errors fail the run. Keep exact pagination assertions and release
only the resources the scenario registered. Historical static-membership facts may remain
in disposable stores after active membership is explicitly cleared.
