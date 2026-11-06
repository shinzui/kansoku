---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [OKF log append removes existing guide provenance prose](1-okf-log-append-removes-existing-guide-provenance-prose.md) - The log appender rewrote historical guide log content and dropped the adoption provenance table, requiring restoration.
- [Owned acceptance repeatedly fails fingerprint expiry fixture](2-owned-acceptance-repeatedly-fails-fingerprint-expiry-fixture.md) - The unchanged native identity cache fixture failed twice before packaged AI reporting could run, requiring diagnosis of its expiry boundary.
- [OKF log add rewrites existing log prose](3-okf-log-add-rewrites-existing-log-prose.md) - The OKF log writer dropped historical prose and reformatted unrelated entries while adding an implementation entry.
- [Focused acceptance helper discards ownership query output](4-focused-acceptance-helper-discards-ownership-query-output.md) - The owned custom acceptance harness failed before server startup because its command helper returned None.
- [Custom metric validation specs were compiled but never executed](5-custom-metric-validation-specs-were-compiled-but-never-executed.md) - The explicit Hspec runner omitted CustomSpec, so deterministic checks passed without running the advertised custom-definition tests.
- [OpenAPI generation reconfigures the test-enabled build](6-openapi-generation-reconfigures-the-test-enabled-build.md) - Running cabal run through the documented OpenAPI target changes component flags and makes the next test-enabled build recompile much of the workspace.
- [Bundle log appends discard existing prose evidence](7-bundle-log-appends-discard-existing-prose-evidence.md) - okf log add rewrote the guides log and removed its adoption provenance table, requiring preservation of the original body.

