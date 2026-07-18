{-# LANGUAGE TypeApplications #-}

-- | Pins every analytics-contract path to a distinct sentinel handler.
--
-- Nine metric routes have exactly the same handler type. Neither their current
-- positional @:<|>@ chain nor the upcoming NamedRoutes record can detect a
-- same-typed transposition statically, so these runtime assertions are the
-- load-bearing dispatch guard. Deliberately swapping the @users@ and
-- @organizations@ sentinels makes the users assertion observe
-- @"organizations"@ and fail.
module Kansoku.Metrics.RoutingSpec
  ( sentinelIngestServer,
    sentinelKansokuServer,
    sentinelMetricsServer,
    spec,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Time (Day)
import Kansoku.Api qualified as Api
import Kansoku.Api.Ingest qualified as Ingest
import Kansoku.Api.Metrics qualified as Metrics
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    EventName (..),
    EventSource (..),
    baseEvent,
  )
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
  ( hContentType,
    methodPost,
    status200,
    status202,
  )
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant
  ( Handler,
    serve,
  )
import Servant.Server.Generic (AsServerT)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku analytics route dispatch" $ do
  it "routes all eleven metrics and both ingest operations to their own handlers" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_ (assertMetricRoute manager port) metricRoutes
      assertIngestRoutes manager port

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
  HTTP.responseStatus response `shouldBe` status200
  result <- decodeBody @Metrics.MetricResult (HTTP.responseBody response)
  Metrics.metric result `shouldBe` expected

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
  let Ingest.BatchAck batchAccepted = batchAck
  batchAccepted `shouldBe` 2

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
  serve Api.kansokuAPI sentinelKansokuServer

sentinelKansokuServer :: Api.KansokuAPI (AsServerT Handler)
sentinelKansokuServer =
  Api.KansokuAPI
    { Api.ingest = sentinelIngestServer,
      Api.metrics = sentinelMetricsServer
    }

sentinelIngestServer :: Ingest.IngestRoutes (AsServerT Handler)
sentinelIngestServer =
  Ingest.IngestRoutes
    { Ingest.postEvent = \_event -> pure Ingest.IngestAck {Ingest.accepted = 1, Ingest.eventId = "events"},
      Ingest.postBatch = \_events -> pure Ingest.BatchAck {Ingest.accepted = 2}
    }

sentinelMetricsServer :: Metrics.MetricsRoutes (AsServerT Handler)
sentinelMetricsServer =
  Metrics.MetricsRoutes
    { Metrics.events = metricSentinel "events",
      Metrics.pageViews = metricSentinel "page-views",
      Metrics.sessions = metricSentinel "sessions",
      Metrics.funnel = funnelSentinel,
      Metrics.retention = retentionSentinel,
      Metrics.acquisition = metricSentinel "acquisition",
      Metrics.featureAdoption = metricSentinel "feature-adoption",
      Metrics.conversion = metricSentinel "conversion",
      Metrics.users = metricSentinel "users",
      Metrics.organizations = metricSentinel "organizations",
      Metrics.custom = metricSentinel "custom"
    }
  where
    metricSentinel :: Text -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> Handler Metrics.MetricResult
    metricSentinel name _fromDay _toDay _groupBy _timeGrain = pure (sentinelResult name)

    funnelSentinel :: Day -> Day -> Text -> Handler Metrics.MetricResult
    funnelSentinel _fromDay _toDay _steps = pure (sentinelResult "funnel")

    retentionSentinel :: Day -> Day -> Maybe Text -> Handler Metrics.MetricResult
    retentionSentinel _fromDay _toDay _days = pure (sentinelResult "retention")

sentinelResult :: Text -> Metrics.MetricResult
sentinelResult name = Metrics.MetricResult {Metrics.metric = name, Metrics.points = []}
