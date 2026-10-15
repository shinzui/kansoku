---
id: 27
slug: enforce-core-record-and-route-construction-conventions
title: "Enforce core record and route construction conventions"
kind: exec-plan
created_at: 2026-10-15T03:10:58Z
intention: "intention_01m4yrkpeve8c8aktyqnqdftv0"
master_plan: "docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-15T03:10:58Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:29:26Z
      verdict: "approved"
      note: "Focused convention scope, component warning coverage and byte-preserving contract acceptance are implementable."
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T04:51:56Z
      mode: "implement"
      note: "Enforce omitted-field diagnostics and normalize internal registry records without wire changes."
---

# Enforce core record and route construction conventions

This ExecPlan is a living document. Keep milestones and any discoveries current.


## Purpose / Big Picture

Adding a Servant route without a handler will fail the build. The schema registry's internal
records will use the project's unprefixed-field and lens conventions without changing published
event schemas or JSON. These changes improve maintenance safety while keeping behavior stable.


## Progress

- [x] (2026-10-15) M1: Every local component inherits fatal missing-record-field diagnostics and all existing components build.
- [x] (2026-10-15) M2: Focused schema-registry record cleanup preserves wire contracts and passes registry/validation tests.


## Surprises & Discoveries

The scoped rename compiled without expanding the source cleanup into unrelated
records. Pure registry/type modules use constructor pattern matching and do not
import generic-lens orphans. Touched project probe/config test updates use lenses;
external Request records and newtype unwrappers keep their established APIs.


## Decision Log

On 2026-10-15, restrict cleanup to the audited schema-registry field/selector violations and
project-owned record updates in tests. Leave external-library records, newtype unwrap functions,
constructor pattern matching, wire-field names and dynamic SQL composition intact. Do not turn
a safe convention repair into a repository-wide source/API redesign.


## Outcomes & Retrospective

All four packages enforce -Werror=missing-fields through every local component's
common stanza. A temporary removal of the metrics handler from KansokuAPI failed
with GHC-20125 / Werror=missing-fields, naming the omitted metrics field. The exact
field was restored and the library rebuilt successfully; no partial handler remains.

Internal PropertySpec/EventSchema fields and all local consumers now follow the
unprefixed convention. Existing registry, property, validation, route-dispatch and
contract tests pass in the full suite (core 169 examples, 25 optional storage pending;
client 15, one optional live case pending; probe kit four passing cases). Both artifact
generators ran, and SHA-256 comparisons with the immediate EP-26 starting tree proved
OpenAPI and event catalog byte-for-byte unchanged. Cabal builds every component with
tests; Nix server/client builds pass.

The developer guide records the warning policy, per-module label imports, pure type
module exception, external-record/newtype/Servant selector exceptions and immutable
wire contracts. This source convention change needs no new architecture record;
ADR-7's released-schema invariants remain unchanged.


## Context and Orientation

All four package Cabal files have `common common` with GHC2024, mandatory extensions and
-Wall, but no fatal missing-fields flag. GHC ordinarily warns about omitted fields and can
still construct a partial handler record. `kansoku-api/src/Kansoku/Api.hs` and its ingest/metrics
slice records use NamedRoutes, while `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs` supplies
runtime sentinel responses to catch same-typed handler swaps. Fatal missing fields complement,
and do not replace, those tests.

At the starting revision, `kansoku-api/src/Kansoku/Event/Registry.hs` used prefixed PropertySpec fields propName,
propType, propRequired, propPattern, propDescription and EventSchema fields schemaEventName,
schemaVersion, schemaNote, schemaProperties. Helpers use selector-function applications.
Consumers include `kansoku-api/src/Kansoku/Event/Validation.hs`, `Kansoku/Event/Contract.hs`,
`kansoku-core/src/Kansoku/Metrics/Query/Property.hs` and their tests. `Kansoku.Prelude` correctly
keeps PackageImports local and does not import Data.Generics.Labels; preserve this. Orphan label
instances propagate transitively, so pure record-definition modules should not acquire them
merely to manipulate data in a helper that could instead use constructor pattern matching.

Relevant references are `mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`,
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude` and
`mori://shinzui/haskell-jitsurei/docs/api-servant-routes`.
[ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md) requires immutable released
schema versions and deterministic public catalogs. [ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
requires declared-property resolution. No local ADR requires prefixed internal names or warning-only
handler construction; a new architecture record solely for stylistic spelling is unnecessary.


## Plan of Work

### M1: Make omitted record fields fatal

Add -Werror=missing-fields to the shared stanza in each of kansoku-api, kansoku-core,
kansoku-server and kansoku-client. Confirm every library, executable, test suite and new probe
test imports common. Repair any actually missing fields explicitly. Do not add blanket -Werror
or disable missing-fields on route modules. Keep -threaded on SDK/server/socket-test components.

Run cabal build all --enable-tests and the Nix package build. As a one-time manual verification,
remove one handler field in a temporary edit and observe the expected missing-fields build
error; restore the field before committing and rebuild the affected target. Use a patch touching
only that field and restore only that patch; never reset unrelated working changes. Record the
observed diagnostic rather than adding a test that merely greps the Cabal implementation.

### M2: Apply focused registry conventions without wire drift

Rename internal PropertySpec fields to name, propertyType, required, validationPattern and
description; rename EventSchema fields to eventName, version, note and properties. Adapt all
local constructors, patterns and consumers found with scoped rg. Use constructor pattern matching
for registry helpers where it keeps a pure type module free of generic-lens orphans; use
per-module Data.Generics.Labels imports at manipulation sites that need lens access. Keep strict
data fields and explicit deriving strategies. Do not put strictness annotations on newtype fields.

Convert project-owned test record updates to lens updates where they manipulate these records
or application/probe/config fixtures. External Request, ServerError and Aeson Options updates
remain normal library API use; do not force Generic lens constraints onto dependencies. Leave
newtype unwrap selectors and Servant route selectors allowed by their documented type-family
limitations. MultilineStrings is already enabled; do not rewrite dynamically assembled SQL
unlines solely to satisfy a superficial textual rule.

All event wire keys, catalog order, validation results and property query output must stay
unchanged. Update developer guidance in docs/guides/development.md (create if absent) and link
it from docs/README.md with the baseline conventions and exception rationale. If implementing
after other children, compare generated artifacts with the immediate starting revision, not
with the pre-migration audit artifacts.


## Concrete Steps

Run from the repository root inside `nix develop`:

```bash
rg -n 'propName|propType|propRequired|propPattern|propDescription|schemaEventName|schemaVersion|schemaNote|schemaProperties' kansoku-api kansoku-core kansoku-client kansoku-server
cabal build all --enable-tests
cabal test kansoku-core-test --test-options='--match Kansoku analytics route dispatch' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.Event' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku event schema contract' --test-show-details=direct
just contracts-check
just openapi-check
nix build .#kansoku-server .#kansoku-client
```

Check actual Hspec descriptions before filtering; change a filter if necessary and record a
nonzero example count. Both artifact checks must report no diff for this child alone.


## Validation and Acceptance

Build every local component with the new warning policy. The temporary omitted-handler edit
must fail compilation, and sentinel dispatch must still pass after restoration. Registry version
selection, validation, published schema JSON and property-query tests must retain their current
behavior. Generated event contracts and OpenAPI bytes must match this child's starting tree.
No test-only change should alter production schema or metric behavior. Ordinary formatting
verification is sufficient for incidental style edits; do not add tests mirroring renames.


## Idempotence and Recovery

This is source-only work with no database migrations. Keep renames and all local consumers in
one coherent change. Preserve unrelated edits during manual diagnostic checks and regenerate
only documented artifacts. A rollback must restore both definition and consumer names together.


## Interfaces and Dependencies

No hard prerequisite. Soft dependencies on
`docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`,
`docs/plans/24-adopt-shared-liveness-and-readiness-probes.md`,
`docs/plans/25-trace-http-requests-and-emit-safe-correlated-access-logs.md` and
`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` reduce overlapping edits;
this child can start before them if needed. It owns warning flags and internal registry names,
not public JSON field names or route result shapes. Use all plan/intention trailers from frontmatter.
