---
id: 25
slug: trace-http-requests-and-emit-safe-correlated-access-logs
title: "Trace HTTP requests and emit safe correlated access logs"
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
      verdict: "changes-requested"
      note: "WAI instrumentation exports raw query attributes; add span sanitization and exported-span secret tests, not only access-log assertions."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:37:31Z
      mode: "update"
      note: "Require sanitized instrumentation request views and exported-span privacy tests in all HTTP semantic modes."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T04:25:24Z
      mode: "implement"
      note: "Implement sanitized HTTP instrumentation, correlated access logging and export privacy coverage."
---

# Trace HTTP requests and emit safe correlated access logs

This ExecPlan is a living document. Update living sections and affected ADRs as work proceeds.


## Purpose / Big Picture

Operators will trace an incoming analytics request by its stable route and find a matching
JSON access record using the same trace ID. Request records will show status and elapsed time
without exposing credentials, bodies or query values. Default local development will continue
to work without an OpenTelemetry collector; existing Prometheus pipeline metrics remain usable.


## Progress

- [x] (2026-10-15) M1: A real HTTP request produces one correctly parented server span named by the served route.
- [x] (2026-10-15) M2: Access records match the serving span and exclude probe noise; both access records and exported spans exclude secrets and query values.
- [ ] M3: Provider shutdown, disabled mode, error responses and concurrent requests pass lifecycle and isolation checks.


## Surprises & Discoveries

Dependency research found the catalog's compatibility commit
on a feature branch while remote main had moved; verify source at the immutable pin, not the
working checkout. This is a known input to M1, not evidence of a completed runtime check.

Source review of released WAI instrumentation 1.0.0.0 found raw query capture in legacy
`http.target` and stable `url.query` attributes. A safe access logger alone does not satisfy
the privacy contract. The response callback does rename the server span from `http.route`;
no additional span or independent route-name implementation is required for that behavior.


The compatibility pin's library builds on API 1.0, but its bundled example executable
still calls the old one-argument shutdown API. Cabal consumes only its library; Nix
would build that unrelated executable too. The project-owned Nix override marks only
the example unbuildable, preserving the exact library source and pin.

The semantic configuration is memoized by the SDK. `python3 scripts/http-telemetry.py`
runs separate processes for all three modes, asserting the expected legacy/stable keys,
query-free exported attributes/events/status and unchanged handler query values. It also
runs buffered-export subprocesses with a 60-second batch schedule, forcing bracket
shutdown to provide the flush proof. No external collector is involved.


## Decision Log

On 2026-10-15, keep pipeline metrics in Prometheus and make OTel HTTP instrumentation follow
the existing explicit exporter opt-in. Access logging is available independently of exporting;
it omits absent/invalid correlation IDs. Do not add a collector requirement or convert pipeline
metrics to OTel as a side effect.

On 2026-10-15, group HTTP span setup and access logging in one child because middleware order
and request context are one integration boundary. Durable cross-queue trace propagation is
outside this work; do not claim writer batches are children of ingest requests without evidence.

On 2026-10-15, sanitize the request view before HTTP instrumentation records attributes, restore
the original application query inside that boundary, and prove privacy at the exported-span
boundary in all supported HTTP semantic-convention modes. Access-output checks alone are insufficient.


## Outcomes & Retrospective

Production HTTP middleware, bounded correlated access logging, and provider lifetime
are implemented. Six HTTP cases pass independently in each of legacy, http and http/dup
modes; two focused access-log cases pass. Four subprocess checks prove buffered spans
flush on normal and exceptional exit and remain unexported when disabled/unconfigured.
Cabal builds every component with tests. The final Nix server acceptance is running after
excluding the dependency's unused example executable; M3 remains open until it passes.


## Context and Orientation

`kansoku-core/src/Kansoku/Telemetry.hs` returns a tracer and shutdown action; exporter setup
is opt-in through OTEL_EXPORTER_OTLP_ENDPOINT or OTEL_TRACES_EXPORTER. It is bracketed in
`kansoku-server/app/Main.hs`, which passes the tracer to the writer. `Kansoku.Logging` emits
application messages, not per-request access records. `kansoku-core/src/Kansoku/Server.hs`
assembles CORS, body limits, authentication and analytics routing, without HTTP tracing/logging.
The preceding probe child adds `Kansoku.Health` and a typed operational proxy.

[ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) chooses seven Prometheus
pipeline instruments and explicit tracer lifetime. Extend it with HTTP middleware ordering and
the optional OTel meter lifecycle while preserving these decisions. [ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md)'s body-limit/CORS order and
[ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)'s authentication
and tenancy remain relevant constraints. Private causes belong
in application logs; access logs use a small fixed field set.

Read `mori://shinzui/haskell-jitsurei/docs/api-opentelemetry-integration` and
`mori://shinzui/haskell-jitsurei/docs/api-request-logging`. Discover the SDK through
`mori://iand675/hs-opentelemetry` and its context, instrumentation and provider guides.
The Servant fork is `mori://shinzui/hs-opentelemetry-instrumentation-servant`;
commit `5e99a7857032484abc669076704dee4335e7d0ad` adds MultiVerb/AuthProtect endpoint instances
and admits the 1.0 API cohort. Its branch still resolves to that commit as of 2026-10-15.
The local default checkout inspected during planning still showed the old bound, so use git
show at the pin. Released WAI instrumentation 1.0.0.0 was verified on Hackage; inspect upstream
1.0 tags and all consumed package bounds again before making cohort edits.


## Plan of Work

### M1: Integrate providers and trace the actual applications

Wait for the entirety of `docs/plans/24-adopt-shared-liveness-and-readiness-probes.md` to be
Complete. Inspect the pinned SDK source and WAI instrumentation before invoking APIs; use Mori
registry paths, never /nix/store. Add WAI instrumentation on the compatible 1.0 cohort and the
verified immutable Servant fork in Cabal and Nix. Keep source pins identical across build paths,
and record fetch hashes actually computed by the package manager. Do not use a branch pin or a
blanket allow-newer workaround. If published versions have changed, compare current registry,
upstream tags and tested cohort before deliberately revising this plan.

Extend the telemetry handle to own the tracer provider, optional meter provider, constructed WAI
middleware and flush/shutdown actions. Install configured global providers before constructing
WAI instrumentation; the middleware captures providers at construction time. Initialize once
per process. Preserve disabled/zero-configuration behavior and OTEL_SDK_DISABLED precedence.
Keep `-threaded` on every executable/test using the SDK. Explicitly flush then shut down on
normal exit and exceptions, including meter shutdown when initialized.

Compose outer WAI tracing, Servant route annotation, request logging, the existing exception
boundary, and the actual application. Use the exact analytics proxy that is served, including
its authentication combinators, and the separate typed operational proxy for canonical probes.
Do not annotate a root Raw fallback as an empty route. Unmatched paths retain a bounded method-only
span. Keep operations outside public OpenAPI even though the outer WAI span observes them.
Prove incoming W3C traceparent becomes the parent of exactly one server span before adding the
full logging behavior. Confirm a metric route, a typed problem and a canonical probe all compile
and trace through their production wiring.

Add a service-owned adapter in `Kansoku.Telemetry` around the constructed WAI middleware.
For each request, retain the original request in the request-local closure and pass a copy
with empty `rawQueryString` and `queryString` to instrumentation. Its inner application restores
the original request fields while retaining the instrumented request's vault, so handlers and
authentication receive the original parameters and the access logger still sees the server
context. Both the initial instrumentation and its response callback must capture the sanitized
copy. Do not mutate shared state or erase queries on the request delivered to Servant. Bound
the instrumentation copy's path and user-agent inputs to the same limits as the access logger;
preserve W3C propagation headers. Trace attribute capture must not be expanded to arbitrary
headers, bodies or query values. Verify the exact middleware's use of these request fields
before implementing the adapter, using the Mori-discovered source at the selected cohort.

This adapter prevents raw query data from entering HTTP span attributes before processors or
exporters see them. It must cover default/legacy, `http`, and `http/dup` values of
`OTEL_SEMCONV_STABILITY_OPT_IN`. Keep `http.target` path-only and `url.query` absent or empty.
The telemetry handle must expose only the wrapped middleware for production assembly, so the
packaged executable cannot accidentally install the unsanitized middleware.

### M2: Add safe access records under the serving span

Create `kansoku-core/src/Kansoku/RequestLog.hs`. Adapt the small middleware from the catalog,
using only the required method, raw path without query, numeric status, UTC time, monotonic
duration_ms, optional user_agent and valid lowercase trace_id/span_id. Never capture bodies,
response content, credentials, cookies, arbitrary headers or parsed query strings. Bound the
encoded user-agent and path inputs (512 and 2048 input bytes respectively), truncate with a
visible flag, and emit one encoded line in one handle operation to avoid interleaving. Do not
invent metric labels from raw paths or customer values. Exclude the exact canonical and legacy
probe paths from EP-24's inventory; keep authenticated traffic included.

Provide a small injectable sink for deterministic tests; production writes access JSON to stdout
and application diagnostics remain on stderr. Place the logger inside WAI tracing and route
annotation so it can observe the request-vault server context. It must see actual auth, CORS,
size-limit and exception-boundary statuses without reading response bodies. Test a fixed
traceparent and compare the access IDs with the exported server span; never fabricate zero IDs
in disabled mode. Keep non-recording propagation context only when the SDK supplies valid IDs.

### M3: Verify lifetime, isolation and operator configuration

Add `kansoku-core/test/Kansoku/RequestLogSpec.hs` and HTTP telemetry tests using an in-memory
exporter or injected SDK processor, found through Mori source. If the in-memory exporter becomes
a test dependency, keep its version on the verified cohort. Pin success/error route annotations,
low-cardinality labels, concurrent-request context separation, absent/disabled exporter behavior,
and flush-before-exit with a subprocess test where needed. Reuse the existing exception boundary
from the error-contract child rather than implementing another renderer. Make cancellation
propagate so termination cannot be swallowed by a broad exception handler.

Update `docs/guides/operations.md`, `docs/guides/configuration.md`, the README and ADR-2 to state
exact fields, exclusions, trace opt-in, sampling, service identity and shutdown semantics. Document
Prometheus pipeline metrics and OTel HTTP instruments separately. Use the cohort-supported base
OTLP endpoint and verify exporter path behavior instead of copying obsolete per-signal workarounds.


## Concrete Steps

From the repository root inside `nix develop`, discover dependencies and verify the fork:

```bash
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
mori registry show shinzui/hs-opentelemetry-instrumentation-servant --full
curl -fsSL https://hackage.haskell.org/package/hs-opentelemetry-instrumentation-wai/preferred.json
```

After implementation:

```bash
cabal build all --enable-tests
cabal test kansoku-core-test --test-options='--match Kansoku.RequestLog' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.HttpTelemetry' --test-show-details=direct
cabal test kansoku-probe-test --test-show-details=direct
nix build .#kansoku-server
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The new named test groups must be wired into `kansoku-core/test/Spec.hs` and its Cabal
other-modules. Expected outcome is zero failures and deterministic assertions over captured
access records and spans, without requiring an external collector.


## Validation and Acceptance

A request with traceparent `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` must
produce the same trace ID in the access record and a new server span with that remote parent.
Representative span names include `GET metrics/events`; raw query values never enter names or
labels. A 503 records the actual status and error span state. Credentials placed in headers,
query and body must be absent from captured access output and exported span attributes, events
and status descriptions, including oversized/invalid requests. Exercise the default/legacy,
`http`, and `http/dup` modes independently. Send a unique sentinel in an otherwise ignored query
parameter alongside valid metric parameters; inspect complete exported spans and console-export
output for the sentinel, and assert legacy `http.target` has no query while `url.query` is absent
or empty. A handler-level assertion must prove the original raw and parsed query reach the
application unchanged; concurrent distinct queries must not cross-contaminate requests. Verify
traceparent correlation still works through the sanitizing adapter. Repeat the packaged-server
sentinel check in the final acceptance child.
Probe requests emit no access records. Concurrent requests must not inherit each other's context.
All retained records remain independently parseable JSON lines. A configured exporter flushes
buffered spans on shutdown, and disabled/unconfigured runs remain functional without network
export attempts. Existing Prometheus names and values remain covered by ObservabilitySpec.


## Idempotence and Recovery

Provider registration is once per process, never per request. Tests must restore any altered
global provider/environment state and run global-mutating cases serially or in subprocesses.
No database migrations or queue envelope changes occur. Keep dependency and lifecycle changes
in coherent commits; turning export off restores local no-export behavior without disabling logs.


## Interfaces and Dependencies

Hard dependency: all of `docs/plans/24-adopt-shared-liveness-and-readiness-probes.md`.
That child supplies the real application/probe seam and exact exclusion inventory; its own
prerequisite supplies the error boundary. This child owns `Kansoku.RequestLog`, telemetry handle
extensions and the final middleware composition. EP-28 consumes the same executable and asserts
wire behavior and absence of query sentinels from console-exported spans. The sanitizing adapter
is owned here alongside telemetry, not by the access logger or the acceptance harness. Use all
plan/intention trailers from frontmatter on implementation commits.
