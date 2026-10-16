---
id: 39
slug: beacon-ingest-route-for-page-exit-delivery
title: "Beacon ingest route for page-exit delivery"
kind: exec-plan
created_at: 2026-10-15T14:22:40Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T14:22:40Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T03:27:17Z
      mode: "implement"
      note: "Implement write-key-only beacon body authentication and shared fenced ingest, then prove media/origin/quota behavior with the pinned browser consumer after EP-37 acceptance."
---

# Beacon ingest route for page-exit delivery


## Purpose / Big Picture


Support best-effort page-exit delivery through a dedicated write-key-only body-authenticated
route. A queued beacon is not an acknowledgement: it can still be lost, rejected or rate limited.
Session semantics cannot depend on a page-leave event always arriving.

## Progress


- [x] M1: Both media types use shared authenticated ingest validation, rate limits and counters.
- [x] M2: OpenAPI/client and the SDK browser test prove envelope, origin and quota behavior.

## Surprises & Discoveries


Released dependency source verification: Mori indexed Aeson 2.3.1.0 while Hackage and
upstream tags already publish 2.3.2.0. This change adds no latest-version pin; the public token
decoder was checked in the resolved 2.2.4.1 source (Cabal uses 2.2.5.1) and the API lower
bound is explicit. wai-cors 0.2.7 rejects unsupported origins before invoking the application.

The default Playwright headless-shell delegate reports BFCacheDisabledForDelegate. Full
Chromium with its default BFCache-disabling argument removed preserves the document; restoration
must wait for navigation commit rather than a load event. The proof checks a retained document
token, two view IDs and one pre-restore leave. The owned browser fixture uses a 1 MiB body cap
so normal delivery of an event above the exit budget is exercised independently of the public
perimeter fixture's 4 KiB cap. A pre-browser packaged attempt was deliberately stopped to fix
that fixture mismatch; only the final complete run above is acceptance evidence.

The beacon standard permits preflight for non-safelisted content types; it does not categorically
forbid it. text/plain avoids that dependency. The 64 KiB keepalive budget is shared in flight,
not a fresh allowance per split call. Batch-length enforcement currently lives in the handler,
not generic /v1 middleware. CORS response visibility alone is not ingest authorization.

## Decision Log


On 2026-10-15 keep body credentials only on /v1/beacon and only for public write keys.
Use the same post-auth ingest service as normal requests. Enforce configured origin policy
before side effects, including simple requests; do not rely on the browser reading a response.

On 2026-10-16 retain the SDK mirror after beacon true and count it separately from accepted.
Use one conservative complete-body byte reservation across client instances in a document;
beacon reservations last for that document because completion is unobservable. Keepalive is
the default, and false/missing/throw fallback remains best effort. Pending queue capacity is
bounded without a silent time expiry. Page leaves use monotonic time and original view identity;
privacy transitions retire snapshots. These browser decisions are accepted in
`mori://shinzui/kansoku-ts/okf/adrs/concepts/ADR-2` and
`mori://shinzui/kansoku-ts/okf/adrs/concepts/ADR-4`.

## Outcomes & Retrospective


Complete. `POST /v1/beacon` accepts both JSON media types through the same authenticated
admission, immutable acceptance, normalization, enrichment and quarantine service. Its deferred
body authentication rejects competing headers, missing/ambiguous keys, unknown/revoked keys
and service credentials with the documented status algebra. Duplicate escaped envelope keys
are rejected before object construction and neither decoder exposes producer parser details.

Source `just check` passed 364 core, 19 client and four probe cases; seven HTTP telemetry cases
passed in each semantic mode and four exporter lifecycle checks passed. The native PostgreSQL
perimeter test covers both generic media clients, credentials, origins, byte/count bounds,
partial rejection, cross-route admission and diagnostic credential exclusion. The public
Haskell client helper independently proves both wire media and absent auth headers.

Final packaged acceptance passed in `.dev/acceptance/run-0bzk67yc/sanitized`: 426 core,
20 client, four probe and 58 actual Hurl requests (43 safe, 14 stateful and one disabled-metrics
request), plus native recovery/limits/replay/identity and every public analytics workflow in
legacy, http and http/dup modes. Required SDK governed traits passed one non-skipped live case
in each mode. All seven packaged administration families passed after the browser scenarios.

Six required Chromium cases prove same/cross-origin text/plain without OPTIONS, denied-origin
zero rows, actual shared keepalive quota refusal with fallback, oversized Unicode envelope
retention, acknowledged retry deduplication and a genuinely restored BFCache document with
separate view intervals. The harness records runtime consumer commit
0a4eea715b5f34fad8593e3dfd123ce407976c95 and built artifact SHA-256 in its private consumer
manifest; source package ownership is `mori://shinzui/kansoku-ts/packages/kansoku-js`.
The source contract pin is server commit 3d0e3d8 (containing this route); gate commit is
942af8c. Source iteration evidence is `.dev/acceptance/beacon-smoke-p9i3jo3j`.

SDK M1/M2/M4 are complete. Its full unit suite has 77 passing cases plus two explicit no-DOM/SSR
cases; source types/lint/format/contracts/packages/strict ADRs pass. JavaScript/React gzip
outputs are 10150/1843 bytes within their 10240/3072 budgets. The additional privacy case proves
opt-out and suppressed exits retire page snapshots rather than resurrect old identity on opt-in.
Bot and final cross-origin/release conformance remain owned by
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`
and server EP-38. This evidence establishes built source/package behavior, not a published
package or deployed endpoint. Accepted ADRs 1 and 3 and the send-events guide describe the boundary.

## Context and Orientation


`kansoku-api/src/Kansoku/Ingest/Api.hs` declares routes; `Auth/Handler.hs` resolves header keys;
`Auth/Store.hs` verifies hashes; `Server.hs` wraps CORS/body limits; `Ingest/Handler.hs` enforces
batch limits. Read [ADR-1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) and
[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md).
[W3C Beacon](https://www.w3.org/TR/beacon/) defines queueing, CORS and shared keepalive quotas.

## Plan of Work


### M1: Route and perimeter


Define BeaconEnvelope with writeKey and batch, and PlainTextJSON whose encoder/decoder uses
JSON with media type text/plain (accept a UTF-8 charset parameter). POST /v1/beacon accepts
PlainTextJSON and JSON, returning the batch 202/problem algebra. Do not add header IngestAuth;
resolve the bounded envelope body key with the same verification primitives, require WriteKey,
return 401 for unknown/revoked and 403 for service credentials. Missing or ambiguous credentials
are 400; header credentials do not substitute for a missing body key. Document deterministic
handling of a body plus credential header (reject to avoid competing principals).

After credential verification call EP-30's shared admission/idempotency and EP-29's
normalization/validation/quarantine service; EP-33 enrichment context also passes through it.
Enforce body bytes before decode, batch length after bounded decode, and rate limits before
side effects. The JSON envelope adds bytes to payload budgeting. Single/batch/beacon use the
same key bucket, so the beacon route cannot bypass throttling.

Verify the actual wai-cors policy rejects disallowed Origin on simple POST before queueing;
add explicit origin admission if necessary. Missing Origin remains allowed for nonbrowser
clients, because a public key is the credential and Origin is forgeable. No keys, envelopes,
raw payloads or forwarded addresses enter logs/traces/quarantine. Extend generated 429
Retry-After behavior and tests to this route.

### M2: Publish and exercise


Regenerate OpenAPI and the generic Haskell client, testing both media types through that client.
Write transport examples in send-events.md with no query-string credential. Browser work is
owned by `mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`:
one outstanding exit attempt per page lifecycle, total serialized envelope below a conservative
60 KiB, false return fallback, and no server-delivered claim on true return. Retaining a mirror
for later retry is safe only with EP-30 deduplication. Test visibilitychange followed by pagehide,
BFCache restoration and same-origin/cross-origin behavior. The server does not need a separate
SDK demonstration committed here.

## Validation and Acceptance


Both media types return the same accepted/rejected results as batch; test unknown/revoked/service
keys, missing key, competing header, malformed JSON, 413 byte/count limits, 429 and partial invalid
batches. No rejected perimeter request enqueues anything. A real browser from an allowed origin
sends text/plain without OPTIONS; a disallowed origin causes zero stored rows. Simulate shared
quota refusal and verify fallback. Inspect exported logs/spans and quarantine for credential
absence. Required final SDK conformance cannot silently skip a missing beacon route.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Additive route, but first-release SDK enablement is coordinated with a server containing it. A browser cannot detect HTTP 404/429 from a successful sendBeacon return; never advertise automatic server-failure fallback.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`, `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`.

Hard dependencies: EP-29, EP-30 and EP-33 Complete. Shared ingest/admission is owned by EP-29/30; EP-33 owns request enrichment; this child owns only transport/auth adaptation. EP-38 owns final cross-repository release acceptance.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
