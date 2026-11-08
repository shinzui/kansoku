---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [OKF log append removes existing guide provenance prose](1-okf-log-append-removes-existing-guide-provenance-prose.md) - The log appender rewrote historical guide log content and dropped the adoption provenance table, requiring restoration.
- [Embedded migration build forces full recompilation during query iteration](10-embedded-migration-build-forces-full-recompilation-during-query-iteration.md) - The build-with-tests wrapper forces all components to recompile and changing to a focused Cabal build changes flags again, adding several minutes to a query-only iteration.
- [OKF log append rewrites historical adoption evidence](11-okf-log-append-rewrites-historical-adoption-evidence.md) - The OKF log append command discarded the guides adoption snapshot table and rewrote unrelated old entries, requiring restoration of the retained history.
- [Two embedded histories amplify content-wrapper rebuild cost](12-two-embedded-histories-amplify-content-wrapper-rebuild-cost.md) - The content-qualified embedding wrapper forces the entire application dependency graph to recompile during topology acceptance iteration.
- [Migration fixture defaults need a separate native-test account](13-migration-fixture-defaults-need-a-separate-native-test-account.md) - The migration toolkit fixture intentionally supplies hostile defaults and a read-only XML administrator, requiring additional setup before existing application native tests can run.
- [OKF log updates discard adoption evidence outside parsed entries](14-okf-log-updates-discard-adoption-evidence-outside-parsed-entries.md) - Updating the guide bundle log rewrote old history and removed its adoption-provenance table, requiring restoration from Git before completion.
- [ClickHouse directory ignore hides new Haskell source modules](15-clickhouse-directory-ignore-hides-new-haskell-source-modules.md) - The unanchored clickhouse directory ignore also matches Kansoku/ClickHouse on a case-insensitive filesystem and excludes new modules from Nix source.
- [Owned replica restart readiness ends before interrupted rebuild recovery](16-owned-replica-restart-readiness-ends-before-interrupted-rebuild-recovery.md) - The public replicated fixture discards its operation error and ends its thirty-second restart readiness loop before all tables recover after a final-checkpoint outage.
- [Final native gates force broad recompilation for a focused consumer fix](17-final-native-gates-force-broad-recompilation-for-a-focused-consumer-fix.md) - The content-qualified embedding wrapper recompiles the application graph and both embedded histories when rerunning a required native gate after a focused session-test fix.
- [Owned acceptance repeatedly fails fingerprint expiry fixture](2-owned-acceptance-repeatedly-fails-fingerprint-expiry-fixture.md) - The unchanged native identity cache fixture failed twice before packaged AI reporting could run, requiring diagnosis of its expiry boundary.
- [OKF log add rewrites existing log prose](3-okf-log-add-rewrites-existing-log-prose.md) - The OKF log writer dropped historical prose and reformatted unrelated entries while adding an implementation entry.
- [Focused acceptance helper discards ownership query output](4-focused-acceptance-helper-discards-ownership-query-output.md) - The owned custom acceptance harness failed before server startup because its command helper returned None.
- [Custom metric validation specs were compiled but never executed](5-custom-metric-validation-specs-were-compiled-but-never-executed.md) - The explicit Hspec runner omitted CustomSpec, so deterministic checks passed without running the advertised custom-definition tests.
- [OpenAPI generation reconfigures the test-enabled build](6-openapi-generation-reconfigures-the-test-enabled-build.md) - Running cabal run through the documented OpenAPI target changes component flags and makes the next test-enabled build recompile much of the workspace.
- [Bundle log appends discard existing prose evidence](7-bundle-log-appends-discard-existing-prose-evidence.md) - okf log add rewrote the guides log and removed its adoption provenance table, requiring preservation of the original body.
- [Percentile replay fixture exceeds the packaged request cap](8-percentile-replay-fixture-exceeds-the-packaged-request-cap.md) - The existing percentile replay sends its complete sample population in one batch despite the packaged 4 KiB cap, blocking full acceptance after acquisition HTTP succeeds.
- [OKF log append removes existing guide provenance table](9-okf-log-append-removes-existing-guide-provenance-table.md) - The okf log add command rewrote existing history and removed the guide migration provenance table, requiring restoration around the generated new entry.

