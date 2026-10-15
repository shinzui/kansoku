---
id: 28
slug: gate-service-releases-with-isolated-hurl-acceptance-and-ci
title: "Gate service releases with isolated Hurl acceptance and CI"
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
      note: "Isolated executable acceptance, required integration mode, cleanup and CI ownership are coherent once prerequisites are accepted."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:37:31Z
      mode: "update"
      note: "Cascade native pool-recovery and console-span privacy checks into executable acceptance."
---

# Gate service releases with isolated Hurl acceptance and CI

This ExecPlan is a living document. Keep progress, discoveries, decisions and outcomes current.


## Purpose / Big Picture

A contributor or CI runner will execute `just acceptance` and receive reproducible proof that
the built Kansoku executable starts, serves its documented contracts, authenticates callers,
accepts events and exposes their eventual metric results. Contract drift, missing prerequisites
and failing HTTP assertions will fail the command. Verification will own disposable databases
and processes so it cannot truncate a developer's existing analytics data.


## Progress

- [ ] M1: A documented resource-family Hurl suite asserts final public and operational HTTP contracts.
- [ ] M2: A disposable harness starts the packaged executable and both private databases, runs required tests and cleans up reliably.
- [ ] M3: Repository CI enforces checks and executable acceptance, including failure evidence and generated-contract drift detection.


## Surprises & Discoveries

None during implementation yet. Planning established that existing ClickHouse test helpers
truncate `analytics.events_raw` and mark unavailable databases pending. The new harness must
therefore own a private ClickHouse process and make required prerequisites fail explicitly.


## Decision Log

On 2026-10-15, distinguish `just hurl`, a safe suite against an already running local server,
from `just acceptance`, which creates all isolated prerequisites and runs both safe and
explicitly selected stateful scenarios. Neither command silently targets a remote environment.

On 2026-10-15, use the built Nix server/migration binaries in executable acceptance, and Cabal
for the existing test suites, proving both dependency/build paths rather than substituting a
sentinel application for production startup.

On 2026-10-15, carry the review fixes into final acceptance: require the query-pool native
failure/recovery cases and inspect console-exported spans as well as access records for query
secrets. These consume the preceding children's production fixes rather than masking them here.


## Outcomes & Retrospective

Not implemented.


## Context and Orientation

`justfile` currently provides build/test, OpenAPI/schema generators and development database
commands, but no Hurl or aggregated CI target. No tracked GitHub Actions workflow exists at the
audited revision. `nix/haskell.nix` is Seihou-managed; project tools belong in
`haskellProject.extraDevPackages` in the unmanaged `flake.module.nix`. `nix/pre-commit.nix`
currently checks formatting and commit-message literal newlines, not API contracts.
`cabal.project` and `flake.module.nix` independently resolve/build the four local packages.

The API has event ingestion, a public schema catalog and fifteen metrics paths, including
three explicit not-implemented placeholders. The preceding children add problem details,
canonical/legacy probes, safe access logging and documented query bounds. Use their final
contracts from source and OpenAPI, not the audit's old 18-path status tables as immutable truth.
`kansoku-core/test/Kansoku/HttpIntegrationSpec.hs` already exercises a Warp listener;
`Kansoku/ClickHouseTestSupport.hs` truncates a hardcoded analytics table and skips when its
setup fails. `kansoku-client/test/Spec.hs` enables its live case through KANSOKU_SERVER_URL
and KANSOKU_API_KEY. These tests complement, and do not replace, the packaged-server check.

[ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) owns partial batches, ingest CORS and
permanent body-limit failures. [ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) owns operational
route separation and pipeline supervision. [ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)
owns credential transports, revocation, and tenant scope.
[ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md) owns immutable schema
versions and deterministic publication. Read these local files and preserve their accepted
semantics as revised by prerequisite children. The governing testing standard is
`mori://shinzui/haskell-jitsurei/docs/api-hurl-integration-testing`; its reference implementation
is `mori://shinzui/mori/repos/mori`, project-relative `mori-api/test/hurl/`. Reuse its approach,
not environment-specific credentials or fixture assumptions.


## Plan of Work

### M1: Cover the final live contract by resource family

Wait for all hard prerequisites listed below. Add `kansoku-api/test/hurl/README.md`,
`vars.env`, `run.sh`, `health.hurl`, `openapi.hurl`, `schemas.hurl`, `metrics.hurl`,
`ingest.hurl`, and `perimeter/perimeter.hurl`. Safe default files are named explicitly:
health, openapi, schemas and read-only metrics. Ingest and perimeter remain explicit opt-in
because they write state or require specially configured credentials/origins. Run hurlfmt on
all files but never execute a broad glob. Files are independent; captures never cross files.

Every request asserts status, content type when there is a body, and stable wire meaning.
Cover all metrics route families, with distinguishable fixtures where same-typed operations
might be swapped. Exercise the public schema catalog, representative generated OpenAPI paths,
canonical probes, compatibility aliases and Prometheus scrape enable/disable configuration.
Negative cases include malformed JSON/query, 401/403, unknown routes, 413, query bounds,
not-implemented 404 and browser-visible CORS failures. Tests use stable problem codes and
numeric status, not prose or full JSON snapshots. Do not expose real credentials in tracked
vars; pass tokens through Hurl secrets and generate disposable fixture identities.

Write one ingest flow that posts accepted and rejected events, then observes the accepted
metric through public HTTP with bounded per-entry retries. Never replay the mutation just
because the read is eventually consistent, and never use an unconditional sleep. Use unique
accounts/event IDs per stateful family; prove account isolation with a second service token.
Document minimum fixture cardinality, prerequisites and cleanup in the suite README.

### M2: Own isolated processes and fail missing prerequisites

Implement `scripts/acceptance.sh` with bounded startup/readiness waits, logs, PID ownership and
EXIT/INT/TERM cleanup. Start a fresh PostgreSQL process with a private socket/data directory,
a fresh ClickHouse process with private data and dynamically selected private native/HTTP ports,
and the Nix-built server on a private port. A fresh ClickHouse process may use the required
analytics database name because its entire storage directory belongs to this run. Do not invoke
`just ch-reset`, truncate ambient tables, reuse PGDATA/CLICKHOUSE_HOME, or accept an inherited
remote connection URL. Override inherited runtime/service credentials and exporter variables
with the harness's explicit values. Document how callers may choose a local temporary root;
no flag may redirect destructive setup to an existing service.

Build packages first; resolve the server and migration outputs using Nix JSON output paths and
execute their bin/kansoku-server and bin/kansoku-migrate directly. Do not manually read/traverse
/nix/store. Apply both migration sets explicitly, provision isolated queue/account state, and
seed deterministic fixtures before starting Hurl. Use the actual issue-key command to create
disposable write/service credentials, retaining them only in restrictive temporary secret files.
Use the existing configuration keys from Kansoku.Config for ports, database and body limits;
set CORS to a known allowed origin. No migration is moved into normal server startup.

Run destructive/integration Haskell tests only against this private ClickHouse. Add an explicit
required-integration mode to affected helpers so a missing database, missing schema or absent
live-client credential fails under acceptance instead of becoming pending. Local optional mode
may remain convenient. Run fixture-mutating Haskell tests before Hurl fixture seeding and server
start, or reset only the private fixtures between phases, so suites cannot race each other.
Exercise the final probe test kit and live client case as well. Capture a console-export trace
and bounded access record for a known request to complement deterministic telemetry unit tests.

Run the native failure/cancellation/recovery fixture from EP-24 M2 and the EP-26 consumer cases
as required integration tests, including their independent watchdog and post-recovery query.
For console export, send a unique disposable query sentinel alongside valid metrics parameters
and assert it is absent from complete exported spans and access records. Repeat for default/legacy,
`http`, and `http/dup` semantic-convention modes. Prove the query still returns the expected
fixture result, so passing privacy assertions cannot hide erased application parameters. Keep
raw captured output private until checked and publish sanitized evidence only.

`just acceptance` performs this entire lifecycle and exits nonzero on any build, setup, test,
readiness or HTTP failure. A deliberately broken startup configuration must fail within a bound
and retain the relevant logs, not continue with an unrelated listening process. Cleanup stops
only recorded child processes. A second invocation starts fresh and succeeds without manual
cleanup. Keep diagnostics available in an ignored `.dev/acceptance/<run-id>/` directory; redact
or restrict artifacts containing generated credentials, and publish sanitized logs only.

### M3: Make the checks a repository gate

Add reproducible Hurl and an OpenAPI 3.1 linter tool to the project dev environment through
flake.module.nix. Select supported linter syntax from its official documentation at implementation
time, verify the pinned tool, then expose `just openapi-lint`. Do not add Hurl as a Cabal library.
Create `just check` for build-with-tests, convention/format checks, deterministic Haskell tests,
probe tests, OpenAPI/schema drift and strict ADR profile validation. Keep required database/live
cases in `just acceptance`; split/filter suites explicitly so `just check` does not depend on an
ambient database or pass accidentally because every test was filtered out.

Add `.github/workflows/check.yml` on the project's current branch pushes and pull requests,
using a Linux runner and the existing Nix flake. Pin third-party actions to verified immutable
commits selected from authoritative upstream sources during implementation. Run deterministic
checks, `nix build`/`nix flake check`, OpenAPI lint and isolated acceptance; retain sanitized logs
and reports on failure, with bounded job timeouts and unconditional cleanup. Do not add publishing,
deployment, secrets or approval gates to this initiative. Public cache use is sufficient unless
an existing authenticated cache is explicitly available.

Update README and `docs/guides/development.md` with exact commands, coverage boundaries and
private fixture behavior. The aggregate commands must call explicit existing targets without
silently skipping a gate. Maintain the ADR bundle's strict check through the shared workflow,
and record the durable ownership of the executable acceptance environment where appropriate.


## Concrete Steps

Implement and document these repository-root commands, run inside `nix develop`:

```bash
just check
just openapi-lint
just acceptance
```

For contributors who already started a disposable server, provide:

```bash
just hurl
```

The README must show how to supply local base URL, service credentials as secrets and known
fixture requirements. The safe runner defaults explicitly to 127.0.0.1:8080; opt-in suites
require the harness-provided URL and never infer a remote target from ambient shell state.
Expected summary: deterministic tests and Hurl families report nonzero example/request counts,
zero failures, no pending required integration cases, and generators leave no tracked diff.

The final validation, from a clean disposable environment, is:

```bash
nix develop -c just check
nix develop -c just acceptance
nix build .#kansoku-server .#kansoku-client
nix flake check
```


## Validation and Acceptance

Demonstrate clean-start success and rerun success. Prove the packaged executable binds its own
port, canonical readiness becomes healthy, invalid credentials produce the documented problem,
a partial batch acknowledges exactly accepted/rejected entries, and eventually only the correct
account sees the accepted events. High-cardinality fixtures must provoke the permanent query
limit problem without partial success. Canonical probe paths must not emit access records;
a known authenticated request must emit a sanitized record with the expected trace correlation.

Exported HTTP spans must also omit the disposable query sentinel in every tested semantic mode;
legacy `http.target` is path-only and stable `url.query` is absent or empty. The native recovery
cases must prove the same pool can serve a successful query after failure without restart.

Demonstrate failing gates by changing a generated artifact in a temporary controlled edit,
providing invalid startup configuration, and causing one Hurl assertion to fail. Each must
produce nonzero exit, useful sanitized evidence and process cleanup. Restore only those edits.
Do not add artificial permanent tests for the build scripts' implementation. Audit required test
counts and pending statuses rather than treating a green skipped suite as success. Verify an
existing local database or listening service is unaffected throughout the acceptance lifecycle.


## Idempotence and Recovery

Every run owns a fresh directory and processes. Traps stop only owned PIDs and preserve sanitized
failure evidence. A port collision is a bounded setup failure or a retried local allocation,
never permission to kill a foreign process. Reruns require no destructive cleanup of the checkout.
Any seeded API writes remain confined to the private databases. Do not upload secret files or
raw reports that echo tokens. Rollback of CI/harness changes leaves production behavior intact.


## Interfaces and Dependencies

Hard prerequisites are the entire children
`docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`,
`docs/plans/24-adopt-shared-liveness-and-readiness-probes.md`,
`docs/plans/25-trace-http-requests-and-emit-safe-correlated-access-logs.md`,
`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, and
`docs/plans/27-enforce-core-record-and-route-construction-conventions.md`.
This child owns the Hurl suite, isolated harness, required-integration test mode, aggregated
commands, test tools and CI. It consumes contracts and assembly from the preceding children;
it does not move unresolved production changes into the test harness. Implementation commits
carry parent, child and intention trailers matching frontmatter. Completion includes the parent
MasterPlan's final acceptance evidence and ADR distillation.
