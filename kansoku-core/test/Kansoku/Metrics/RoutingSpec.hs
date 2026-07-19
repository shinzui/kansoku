{-# LANGUAGE TypeApplications #-}

-- | Pins every analytics-contract path to a distinct sentinel handler.
--
-- Nine metric routes have exactly the same handler type. The NamedRoutes record
-- cannot detect a same-typed transposition statically, so these runtime assertions
-- are the load-bearing dispatch guard. Deliberately swapping the @users@ and
-- @organizations@ sentinels makes the users assertion observe
-- @"organizations"@ and fail.
module Kansoku.Metrics.RoutingSpec
  ( sentinelIngestServer,
    sentinelKansokuServer,
    sentinelMetricsServer,
    sentinelContext,
    sentinelPrincipal,
    spec,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day)
import Data.UUID qualified as UUID
import Kansoku.Api qualified as Api
import Kansoku.Api.Response qualified as Response
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types
  ( ApiKeyId (..),
    AuthenticatedPrincipal (..),
    CredentialKind (..),
    IngestPrincipal (..),
    MetricsPrincipal (..),
  )
import Kansoku.Event
  ( AccountId (..),
    AnalyticsEvent,
    EventId (..),
    EventName (..),
    EventSource (..),
    baseEvent,
  )
import Kansoku.Ingest.Api qualified as Ingest
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Server (envelopeFormatters)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
  ( hContentType,
    methodPost,
    status200,
    status202,
    status400,
    status404,
  )
import Network.Wai (Application, Request)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
  ( Context (..),
    Handler,
    serveWithContext,
  )
import Servant.Server (ErrorFormatters)
import Servant.Server.Experimental.Auth (AuthHandler, mkAuthHandler)
import Servant.Server.Generic (AsServerT)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku analytics route dispatch" $ do
  it "routes all eleven metrics and both ingest operations to their own handlers" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_ (assertMetricRoute manager port) metricRoutes
      assertIngestRoutes manager port

  it "wraps malformed bodies and unknown paths in the shared error envelope" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      malformed <- postJson manager port "/v1/events" "{"
      HTTP.responseStatus malformed `shouldBe` status400
      malformedEnvelope <- decodeBody @Response.ErrorEnvelopeWire (HTTP.responseBody malformed)
      Response.code malformedEnvelope `shouldBe` "malformed_request"

      request <- HTTP.parseRequest (baseUrl port <> "/not-a-route")
      missing <- HTTP.httpLbs request manager
      HTTP.responseStatus missing `shouldBe` status404
      missingEnvelope <- decodeBody @Response.ErrorEnvelopeWire (HTTP.responseBody missing)
      Response.code missingEnvelope `shouldBe` "not_found"

metricRoutes :: [(String, Text)]
metricRoutes =
  [ ("events", "events"),
    ("page-views", "page-views"),
    ("sessions", "sessions"),
    ("funnel", "funnel"),
    ("retention", "retention"),
    ("acquisition", "acquisition"),
    ("feature-adoption", "feature-adoption"),
    ("conversion", "conversion"),
    ("users", "users"),
    ("organizations", "organizations"),
    ("custom", "custom")
  ]

assertMetricRoute :: HTTP.Manager -> Warp.Port -> (String, Text) -> Expectation
assertMetricRoute manager port (path, expected) = do
  let extraQuery
        | path == "funnel" = "&steps=signup_started,signup_completed"
        | path == "retention" = "&days=1,7"
        | otherwise = ""
      url =
        baseUrl port
          <> "/metrics/"
          <> path
          <> "?from=2026-06-01&to=2026-06-02"
          <> extraQuery
  request <- HTTP.parseRequest url
  response <- HTTP.httpLbs request manager
  if path `elem` stubPaths
    then do
      HTTP.responseStatus response `shouldBe` status404
      envelope <- decodeBody @Response.ErrorEnvelopeWire (HTTP.responseBody response)
      Response.code envelope `shouldBe` "not_implemented"
      Response.message envelope `shouldSatisfy` Text.isSuffixOf expected
    else do
      HTTP.responseStatus response `shouldBe` status200
      result <- decodeBody @Metrics.MetricResult (HTTP.responseBody response)
      Metrics.metric result `shouldBe` expected

stubPaths :: [String]
stubPaths = ["acquisition", "organizations", "custom"]

assertIngestRoutes :: HTTP.Manager -> Warp.Port -> Expectation
assertIngestRoutes manager port = do
  eventResponse <- postJson manager port "/v1/events" (Aeson.encode sampleEvent)
  HTTP.responseStatus eventResponse `shouldBe` status202
  eventAck <- decodeBody @Ingest.IngestAck (HTTP.responseBody eventResponse)
  let Ingest.IngestAck eventAccepted eventIdentifier = eventAck
  eventAccepted `shouldBe` 1
  eventIdentifier `shouldBe` "events"

  batchResponse <- postJson manager port "/v1/batch" (Aeson.encode [sampleEvent])
  HTTP.responseStatus batchResponse `shouldBe` status202
  batchAck <- decodeBody @Ingest.BatchAck (HTTP.responseBody batchResponse)
  let Ingest.BatchAck batchAccepted batchRejected = batchAck
  batchAccepted `shouldBe` 2
  batchRejected `shouldBe` []

postJson :: HTTP.Manager -> Warp.Port -> String -> BSL.ByteString -> IO (HTTP.Response BSL.ByteString)
postJson manager port path body = do
  initial <- HTTP.parseRequest (baseUrl port <> path)
  HTTP.httpLbs
    initial
      { HTTP.method = methodPost,
        HTTP.requestHeaders = [(hContentType, "application/json")],
        HTTP.requestBody = HTTP.RequestBodyLBS body
      }
    manager

baseUrl :: Warp.Port -> String
baseUrl port = "http://127.0.0.1:" <> show port

decodeBody :: (Aeson.FromJSON a) => BSL.ByteString -> IO a
decodeBody body =
  case Aeson.eitherDecode body of
    Right value -> pure value
    Left err -> expectationFailure ("JSON decode failed: " <> err <> "; body: " <> show body) >> fail err

sampleEvent :: AnalyticsEvent
sampleEvent =
  baseEvent
    (EventId "evt_routing")
    (EventName "page_view")
    Web
    (read "2026-06-01 09:00:00 UTC")
    (read "2026-06-01 09:00:01 UTC")

sentinelApplication :: Application
sentinelApplication =
  serveWithContext
    Api.kansokuAPI
    sentinelContext
    sentinelKansokuServer

sentinelContext :: Context '[ErrorFormatters, AuthHandler Request IngestPrincipal, AuthHandler Request MetricsPrincipal]
sentinelContext =
  envelopeFormatters
    :. mkAuthHandler (const (pure (IngestPrincipal sentinelPrincipal)))
    :. mkAuthHandler (const (pure (MetricsPrincipal sentinelPrincipal)))
    :. EmptyContext

sentinelPrincipal :: AuthenticatedPrincipal
sentinelPrincipal =
  AuthenticatedPrincipal
    { keyId = ApiKeyId UUID.nil,
      kind = ServiceToken,
      accountId = AccountId "acct_sentinel"
    }

sentinelKansokuServer :: Api.KansokuAPI (AsServerT Handler)
sentinelKansokuServer =
  Api.KansokuAPI
    { Api.ingest = const sentinelIngestServer,
      Api.metrics = const sentinelMetricsServer
    }

sentinelIngestServer :: Ingest.IngestRoutes (AsServerT Handler)
sentinelIngestServer =
  Ingest.IngestRoutes
    { Ingest.postEvent = \_event -> pure (Response.KansokuOk Ingest.IngestAck {Ingest.accepted = 1, Ingest.eventId = "events"}),
      Ingest.postBatch = \_events -> pure (Response.KansokuOk Ingest.BatchAck {Ingest.accepted = 2, Ingest.rejected = []})
    }

sentinelMetricsServer :: Metrics.MetricsRoutes (AsServerT Handler)
sentinelMetricsServer =
  Metrics.MetricsRoutes
    { Metrics.events = metricSentinel "events",
      Metrics.pageViews = metricSentinel "page-views",
      Metrics.sessions = metricSentinel "sessions",
      Metrics.funnel = funnelSentinel,
      Metrics.retention = retentionSentinel,
      Metrics.acquisition = stubSentinel "acquisition",
      Metrics.featureAdoption = metricSentinel "feature-adoption",
      Metrics.conversion = metricSentinel "conversion",
      Metrics.users = metricSentinel "users",
      Metrics.organizations = stubSentinel "organizations",
      Metrics.custom = stubSentinel "custom"
    }
  where
    metricSentinel :: Text -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> Handler (Response.KansokuResult Metrics.MetricResult)
    metricSentinel name _fromDay _toDay _groupBy _timeGrain = pure (Response.KansokuOk (sentinelResult name))

    stubSentinel :: Text -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> Handler (Response.KansokuResult Metrics.MetricResult)
    stubSentinel name _fromDay _toDay _groupBy _timeGrain =
      pure (Response.KansokuNotFound (Response.notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name)))

    funnelSentinel :: Day -> Day -> Text -> Maybe Int -> Handler (Response.KansokuResult Metrics.MetricResult)
    funnelSentinel _fromDay _toDay _steps _window = pure (Response.KansokuOk (sentinelResult "funnel"))

    retentionSentinel :: Day -> Day -> Maybe Text -> Handler (Response.KansokuResult Metrics.MetricResult)
    retentionSentinel _fromDay _toDay _days = pure (Response.KansokuOk (sentinelResult "retention"))

sentinelResult :: Text -> Metrics.MetricResult
sentinelResult name = Metrics.MetricResult {Metrics.metric = name, Metrics.points = []}
