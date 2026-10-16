{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Pins every analytics-contract path to a distinct sentinel handler.
--
-- Six metric routes have exactly the same handler type. The NamedRoutes record
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
import Kansoku.Auth.Api (IngestAuth)
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types
  ( ApiKeyId (..),
    AuthenticatedPrincipal (..),
    CredentialKind (..),
    IngestPrincipal (..),
    MetricsPrincipal (..),
  )
import Kansoku.Cohort.Api qualified as Cohort
import Kansoku.Cohort.Types qualified as Cohort
import Kansoku.Event
  ( AccountId (..),
    AnalyticsEvent,
    EventId (..),
    EventName (..),
    EventSource (..),
    baseEvent,
    defaultRegistry,
    schemaCatalog,
  )
import Kansoku.Ingest.Api qualified as Ingest
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.Filter (MetricFilter)
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
import Relay.Pagination qualified as Relay
import Servant
  ( Context (..),
    Handler,
    serveWithContext,
  )
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Client (ClientM, mkClientEnv, parseBaseUrl, runClientM)
import Servant.Client.Core.Auth (AuthClientData, mkAuthenticatedRequest)
import Servant.Client.Generic (genericClient)
import Servant.Server (ErrorFormatters)
import Servant.Server.Experimental.Auth (AuthHandler, mkAuthHandler)
import Servant.Server.Generic (AsServerT)
import Test.Hspec

type instance AuthClientData (AuthProtect "kansoku-ingest") = ()

type instance AuthClientData (AuthProtect "kansoku-metrics") = ()

type instance AuthClientData (AuthProtect "kansoku-beacon") = ()

spec :: Spec
spec = describe "Kansoku analytics route dispatch" $ do
  it "routes all eighteen metrics, both ingest operations, and the public schema catalog" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_ (assertMetricRoute manager port) metricRoutes
      assertIngestRoutes manager port
      schemaRequest <- HTTP.parseRequest (baseUrl port <> "/v1/schemas")
      schemaResponse <- HTTP.httpLbs schemaRequest manager
      HTTP.responseStatus schemaResponse `shouldBe` status200
      decodeBody (HTTP.responseBody schemaResponse) `shouldReturn` schemaCatalog defaultRegistry

  it "wraps malformed bodies and unknown paths in the shared error envelope" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      malformed <- postJson manager port "/v1/events" "{"
      HTTP.responseStatus malformed `shouldBe` status400
      malformedEnvelope <- decodeBody @Response.ProblemDetails (HTTP.responseBody malformed)
      Response.code malformedEnvelope `shouldBe` "malformed_request"

      request <- HTTP.parseRequest (baseUrl port <> "/not-a-route")
      missing <- HTTP.httpLbs request manager
      HTTP.responseStatus missing `shouldBe` status404
      missingEnvelope <- decodeBody @Response.ProblemDetails (HTTP.responseBody missing)
      Response.code missingEnvelope `shouldBe` "not_found"

  it "decodes a typed 400 problem through the actual generated Haskell client" $ do
    let problem = Response.badRequest "validation_failed" "invalid event"
        server =
          sentinelKansokuServer
            { Api.ingest =
                sentinelIngestServer
                  { Ingest.postEvent = \_ _ -> pure (Response.KansokuBadRequest problem)
                  }
            }
        app = serveWithContext Api.kansokuAPI sentinelContext server
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      url <- parseBaseUrl (baseUrl port)
      let client = genericClient @Api.KansokuAPI @ClientM
          credential = mkAuthenticatedRequest @IngestAuth () (const id)
      result <- runClientM (Ingest.postEvent (Api.ingest client) credential (Ingest.ingestEvent sampleEvent)) (mkClientEnv manager url)
      result `shouldBe` Right (Response.KansokuBadRequest problem)
      success <- runClientM (Ingest.postBatch (Api.ingest client) credential []) (mkClientEnv manager url)
      success `shouldBe` Right (Response.KansokuOk Ingest.BatchAck {Ingest.accepted = 2, Ingest.rejected = []})

metricRoutes :: [(String, Text)]
metricRoutes =
  [ ("events", "events"),
    ("page-views", "page-views"),
    ("sessions", "sessions"),
    ("funnel", "funnel"),
    ("paths", "paths"),
    ("retention", "retention"),
    ("acquisition", "acquisition"),
    ("feature-adoption", "feature-adoption"),
    ("conversion", "conversion"),
    ("users", "users"),
    ("stickiness", "stickiness"),
    ("lifecycle", "lifecycle"),
    ("revenue", "revenue"),
    ("organizations", "organizations"),
    ("custom", "custom"),
    ("experiments", "experiments"),
    ("experiments/conversion", "experiment-conversion"),
    ("experiments/funnel", "experiment-funnel")
  ]

assertMetricRoute :: HTTP.Manager -> Warp.Port -> (String, Text) -> Expectation
assertMetricRoute manager port (path, expected) = do
  let extraQuery
        | path == "funnel" = "&steps=signup_started,signup_completed"
        | path == "retention" = "&days=1,7"
        | path == "experiments/conversion" = "&experiment=checkout_v2&event=purchase_completed"
        | path == "experiments/funnel" = "&experiment=checkout_v2&steps=checkout_started,purchase_completed"
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
      envelope <- decodeBody @Response.ProblemDetails (HTTP.responseBody response)
      Response.code envelope `shouldBe` "not_implemented"
      Response.detail envelope `shouldSatisfy` Text.isSuffixOf expected
    else do
      HTTP.responseStatus response `shouldBe` status200
      result <- decodeBody @Metrics.MetricResult (HTTP.responseBody response)
      Metrics.metric result `shouldBe` expected

stubPaths :: [String]
stubPaths = ["organizations", "custom"]

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

sentinelContext :: Context '[ErrorFormatters, AuthHandler Request IngestPrincipal, AuthHandler Request MetricsPrincipal, AuthHandler Request (Text -> Handler IngestPrincipal)]
sentinelContext =
  envelopeFormatters
    :. mkAuthHandler (const (pure (IngestPrincipal sentinelPrincipal emptyRequestContext)))
    :. mkAuthHandler (const (pure (MetricsPrincipal sentinelPrincipal)))
    :. mkAuthHandler (const (pure (const (pure (IngestPrincipal sentinelPrincipal emptyRequestContext)))))
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
    { Api.ingest = sentinelIngestServer,
      Api.metrics = sentinelMetricsServer,
      Api.cohorts = sentinelCohorts,
      Api.schemas = pure (schemaCatalog defaultRegistry)
    }

sentinelIngestServer :: Ingest.IngestRoutes (AsServerT Handler)
sentinelIngestServer =
  Ingest.IngestRoutes
    { Ingest.postEvent = \_principal _event -> pure (Response.KansokuOk Ingest.IngestAck {Ingest.accepted = 1, Ingest.eventId = "events"}),
      Ingest.postBatch = \_principal _events -> pure (Response.KansokuOk Ingest.BatchAck {Ingest.accepted = 2, Ingest.rejected = []}),
      Ingest.postBeacon = \_context _envelope -> pure (Response.KansokuOk Ingest.BatchAck {Ingest.accepted = 3, Ingest.rejected = []})
    }

sentinelMetricsServer :: Metrics.MetricsRoutes (AsServerT Handler)
sentinelMetricsServer =
  Metrics.MetricsRoutes
    { Metrics.events = standardSentinel "events",
      Metrics.pageViews = webSentinel "page-views",
      Metrics.sessions = \principal fromDay toDay groupBy grain filters _measure _bots -> standardSentinel "sessions" principal fromDay toDay groupBy grain filters,
      Metrics.paths = \_ _ _ _ _ _ _ _ _ _ _ _ -> pure (Response.KansokuOk (sentinelResult "paths")),
      Metrics.funnel = funnelSentinel,
      Metrics.retention = retentionSentinel,
      Metrics.acquisition = \principal fromDay toDay groupBy grain filters _measure _bots -> standardSentinel "acquisition" principal fromDay toDay groupBy grain filters,
      Metrics.featureAdoption = standardSentinel "feature-adoption",
      Metrics.conversion = standardSentinel "conversion",
      Metrics.users = \principal fromDay toDay groupBy grain filters _window _bots -> standardSentinel "users" principal fromDay toDay groupBy grain filters,
      Metrics.stickiness = webSentinel "stickiness",
      Metrics.lifecycle = webSentinel "lifecycle",
      Metrics.revenue = standardSentinel "revenue",
      Metrics.organizations = stubSentinel "organizations",
      Metrics.custom = stubSentinel "custom",
      Metrics.experiments = \principal fromDay toDay experiment grain _measure _group _filters -> metricSentinel "experiments" principal fromDay toDay experiment grain,
      Metrics.experimentConversion = experimentConversionSentinel,
      Metrics.experimentFunnel = experimentFunnelSentinel
    }
  where
    webSentinel name principal fromDay toDay groupBy grain filters _bots = standardSentinel name principal fromDay toDay groupBy grain filters

    standardSentinel :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> [MetricFilter] -> Handler (Response.KansokuResult Metrics.MetricResult)
    standardSentinel name principal fromDay toDay groupBy grain _filters = metricSentinel name principal fromDay toDay groupBy grain

    metricSentinel :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> Handler (Response.KansokuResult Metrics.MetricResult)
    metricSentinel name _principal _fromDay _toDay _groupBy _timeGrain = pure (Response.KansokuOk (sentinelResult name))

    stubSentinel :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> [MetricFilter] -> Handler (Response.KansokuResult Metrics.MetricResult)
    stubSentinel name _principal _fromDay _toDay _groupBy _timeGrain _filters =
      pure (Response.KansokuNotFound (Response.notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name)))

    funnelSentinel :: MetricsPrincipal -> Day -> Day -> Text -> Maybe Int -> Maybe Metrics.FunnelMode -> Maybe Metrics.FunnelMeasure -> Maybe Metrics.FunnelCounting -> Maybe Metrics.FunnelAttribution -> [Text] -> Maybe Text -> [MetricFilter] -> Handler (Response.KansokuResult Metrics.MetricResult)
    funnelSentinel _principal _fromDay _toDay _steps _window _mode _measure _counting _attribution _exclude _group _filters = pure (Response.KansokuOk (sentinelResult "funnel"))

    retentionSentinel :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe Metrics.TimeGrain -> [MetricFilter] -> Maybe Text -> Maybe Metrics.RetentionMode -> Maybe Metrics.CohortMode -> Maybe Bool -> Handler (Response.KansokuResult Metrics.MetricResult)
    retentionSentinel _principal _fromDay _toDay _group _grain _filters _days _mode _cohort _bots = pure (Response.KansokuOk (sentinelResult "retention"))

    experimentConversionSentinel :: MetricsPrincipal -> Text -> Text -> Day -> Day -> Maybe Text -> [MetricFilter] -> Handler (Response.KansokuResult Metrics.MetricResult)
    experimentConversionSentinel _principal _experiment _event _fromDay _toDay _group _filters =
      pure (Response.KansokuOk (sentinelResult "experiment-conversion"))

    experimentFunnelSentinel :: MetricsPrincipal -> Text -> Text -> Day -> Day -> Maybe Int -> Maybe Metrics.FunnelMode -> Maybe Metrics.FunnelMeasure -> Maybe Metrics.FunnelCounting -> Maybe Metrics.FunnelAttribution -> [Text] -> Maybe Text -> [MetricFilter] -> Handler (Response.KansokuResult Metrics.MetricResult)
    experimentFunnelSentinel _principal _experiment _steps _fromDay _toDay _window _mode _measure _counting _attribution _exclude _group _filters =
      pure (Response.KansokuOk (sentinelResult "experiment-funnel"))

sentinelResult :: Text -> Metrics.MetricResult
sentinelResult name = Metrics.MetricResult {Metrics.metric = name, Metrics.points = []}

sentinelCohorts :: Cohort.Cohorts (AsServerT Handler)
sentinelCohorts =
  Cohort.Cohorts
    { Cohort.createCohort = \_ definition -> pure (Response.KansokuOk (sample definition)),
      Cohort.getCohort = \_ _ -> pure (Response.KansokuOk (sample definition)),
      Cohort.listCohorts = \_ _ -> pure (Cohort.PageOk emptyPage),
      Cohort.updateCohort = \_ _ input -> pure (Response.KansokuOk (sample input)),
      Cohort.deleteCohort = \_ _ -> pure (Response.KansokuOk True),
      Cohort.putMembers = \_ _ _ -> pure (Response.KansokuOk (Cohort.CohortSize 0)),
      Cohort.getMembers = \_ _ _ _ _ -> pure (Cohort.PageOk emptyPage),
      Cohort.getSize = \_ _ _ _ -> pure (Response.KansokuOk (Cohort.CohortSize 0))
    }
  where
    definition = Cohort.CohortDefinition "sentinel" "static" [] []
    sample input = Cohort.Cohort UUID.nil input (read "2026-07-01 00:00:00 UTC") (read "2026-07-01 00:00:00 UTC")
    emptyPage = Relay.Connection [] (Relay.PageInfo False False Nothing Nothing)
