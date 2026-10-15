# Use the Haskell SDK

`kansoku-client` is the currently supported producer SDK. It derives its HTTP routes and wire
types from `kansoku-api`, buffers events in memory, sends batches in a background worker, retries
delivery, and exposes typed metric clients. Browser, React, and other language SDKs are not yet
shipped; use the [HTTP ingestion guide](send-events.md) from those environments.

## Add the packages

The packages are currently version `0.1.0.0` and are not published to Hackage. Pin a Kansoku
checkout in your source tree, then add both package directories to `cabal.project`:

```cabal
packages:
    .
    vendor/kansoku/kansoku-api
    vendor/kansoku/kansoku-client
```

Add the client and the libraries used by your producer to its Cabal component:

```cabal
build-depends:
    , aeson
    , kansoku-client ==0.1.0.0
    , text
```

Pin the vendored checkout to a reviewed commit rather than following the repository's moving
default branch.

## Track an event

The checked-in [`kansoku-client-example`](../../kansoku-client/example/Main.hs) reads a credential
from `KANSOKU_API_KEY`, starts a client, queues a schema-valid event, and flushes before exit:

```haskell
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kansoku.Client
import System.Environment (getEnv)

main :: IO ()
main = do
  credential <- Text.pack <$> getEnv "KANSOKU_API_KEY"
  withClient (defaultClientConfig "http://localhost:8080" credential) $ \client -> do
    trackEvent
      client
      emptyIds {userId = Just "user_42"}
      "user_registered"
      ["userId" Aeson..= ("user_42" :: Text.Text)]
    flush client
```

Run it against a local server with either a write key or service token:

```bash
export KANSOKU_API_KEY='ksk_w_…'
cabal run kansoku-client-example
```

`defaultClientConfig` uses batches of 100, a five-second flush interval, a 10,000-event buffer,
five retries, and a 100-millisecond exponential-backoff base. Override record fields before
calling `newClient` or `withClient` when those defaults do not fit the service.

Set `sourceService` in `ClientConfig` to identify the emitting service. `EventIds` supplies
optional `userId`, `anonymousId`, `identifiers`, `organizationId`, `accountId`, and `sessionId`.
The authenticated credential remains authoritative for account scoping, so the server overwrites
the SDK's optional `accountId`.

## Lifecycle and loss accounting

`track` and `trackEvent` enqueue without blocking. When the bounded in-memory buffer is full, the
client drops the new event and increments `droppedCount`. The background worker drains one batch
per interval. Permanent delivery failure and server-side per-event batch rejection also add to
the dropped count.

Use `withClient` for a bounded application lifetime. Its `close` action flushes queued events
before stopping the worker. Call `flush` at request-independent durability boundaries and before
process termination; it waits for the currently drained batches but returns no per-event result.
Monitor `droppedCount` and expose it through your application's own telemetry.

## Schema versions and catalog discovery

`trackEvent` omits `schemaVersion`, which means version 1. Pin the version a producer implements
when the event is governed:

```haskell
trackEventWithVersion
  client
  emptyIds {userId = Just "user_42"}
  "page_view"
  1
  ["url" Aeson..= ("https://example.test/docs" :: Text.Text)]
```

`fetchSchemaCatalog client` loads the public catalog and returns
`Either ClientError SchemaCatalog`. Use it in CI or at startup when a service needs to verify its
pinned contracts. The deterministic copy is also available at
[`docs/contracts/events.json`](../contracts/events.json).

## Identity helpers

- `identify client userId anonymousId traits` emits `identify` with the explicit user and
  optional cookie-like anonymous ID.
- `alias client previousId newId properties` emits `alias` and supplies both IDs.
- `group client ids organizationId properties` emits `group` with an organization.

For additional `cookie`, `device`, `fingerprint`, or `email_sha256` signals, set the
`identifiers` map in `EventIds`. See [Send events](send-events.md) for validation and binding
semantics.

## Typed metric clients

`Kansoku.Client.Metrics.metricsClient` exposes the complete generated route record. Authenticate
each operation with `kansokuMetricsCredential` and run the resulting `ClientM` action in a `ClientEnv`.
For example, `Metrics.events metricsClient credential fromDay toDay Nothing Nothing` supplies
the credential to the selected leaf operation (`Metrics` is `Kansoku.Metrics.Api`).
Convenience functions are currently provided for:

- `experimentsClient`
- `experimentConversionClient`
- `experimentFunnelClient`

These return the same typed `KansokuResult MetricResult` alternatives as the HTTP API. See
[Query metrics](query-metrics.md) before interpreting exposure and stitched conversion counts.

## Problem response migration

Errors now use `Kansoku.Api.Response.ProblemDetails` and `application/problem+json`.
The fields are `type`, `title`, `status`, `detail`, `code`, and `retryable`; the old
`ErrorEnvelopeWire` and its `message` field are removed. Generated clients advertise JSON and
problem JSON, decode handler errors into `KansokuResult`, and retain the existing retry policy:
permanent problems are dropped and retryable 429/503 problems use bounded backoff. Typed 429
responses include `Retry-After`; the buffering client waits at least that many seconds before
retrying the same event IDs, within its configured retry count. Partial 202 batches
remain acknowledgements, including per-event rejections.

Authentication runs before the typed handler. Its 401/403/503 responses may arrive as a
Servant `FailureResponse`; decode that response body as `ProblemDetails`. The buffering client
uses HTTP status for those failures: 401/403 are permanent and 503 is retried. The generated
`ingestClient` and `metricsClient` records now take a credential on each protected operation;
the experiment convenience functions keep their credential-first signatures.

Upgrade the API, server and client from the same checkout. There is no legacy error decoder.

[Documentation index](../README.md)
