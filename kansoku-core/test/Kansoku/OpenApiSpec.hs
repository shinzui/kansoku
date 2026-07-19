{-# LANGUAGE TypeApplications #-}

module Kansoku.OpenApiSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (traverse_)
import Data.Foldable qualified as Foldable
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.OpenApi (ToSchema, validateToJSON)
import Data.Text qualified as Text
import Kansoku.Api (kansokuAPI)
import Kansoku.Api.OpenApi (kansokuOpenApi)
import Kansoku.Api.Response (ErrorEnvelopeWire (..))
import Kansoku.Event
import Kansoku.Ingest.Api qualified as Ingest
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.RoutingSpec (sentinelKansokuServer)
import Kansoku.Prelude
import Kansoku.Server (ReadyProbe (..), envelopeFormatters, waiWrapper)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
  ( Status,
    hContentType,
    methodPost,
    status200,
    status202,
    status404,
  )
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (Context (..), serveWithContext)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Api.OpenApi.kansokuOpenApi" $ do
  it "reports OpenAPI 3.1 and keeps lowercase enum wire tags" $ do
    lookupText ["openapi"] documentValue `shouldSatisfy` maybe False (Text.isPrefixOf "3.1")
    lookupTextArray ["components", "schemas", "EventSource", "enum"] documentValue
      `shouldSatisfy` maybe False (elem "web")
    documentValue `shouldSatisfy` containsEnumValue "hour"

  it "documents exactly the thirteen analytics paths with stable operation IDs" $ do
    documentedPaths `shouldBe` expectedServedPaths
    fmap operationIdentity operationValues `shouldMatchList` expectedOperationIds

  it "declares one success and the shared error tail on every operation" $
    traverse_ assertStatuses operationValues

  it "documents ordered funnel semantics and the optional window parameter" $ do
    let funnelOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/funnel", "get"] documentValue)
    lookupText ["description"] funnelOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "performed steps 1..N in order")
    operationParameterNames funnelOperation `shouldContain` ["window"]

  it "labels retention as new-in-window cohorts with offset zero included" $ do
    let retentionOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/retention", "get"] documentValue)
    lookupText ["description"] retentionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "new-in-window cohorts")
    lookupText ["description"] retentionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "Offset 0")

  it "keeps every wire DTO's ToJSON representation within its ToSchema" $ do
    conforms "AnalyticsEvent" sampleEvent
    conforms "IngestAck" Ingest.IngestAck {Ingest.accepted = 1, Ingest.eventId = "evt_openapi"}
    conforms "BatchAck" Ingest.BatchAck {Ingest.accepted = 1, Ingest.rejected = []}
    conforms
      "RejectedEvent"
      Ingest.RejectedEvent
        { Ingest.index = 0,
          Ingest.eventId = Nothing,
          Ingest.errors = ["eventId must not be empty"]
        }
    conforms "MetricPoint" sampleMetricPoint
    conforms "MetricResult" Metrics.MetricResult {Metrics.metric = "events", Metrics.points = [sampleMetricPoint]}
    conforms "TimeGrain" Metrics.Hour
    conforms "ErrorEnvelopeWire" ErrorEnvelopeWire {code = "not_found", message = "no such endpoint", retryable = False}
    conforms "EventId" (EventId "evt_openapi")
    conforms "EventName" (EventName "page_view")
    conforms "AnonymousId" (AnonymousId "anon_openapi")
    conforms "UserId" (UserId "user_openapi")
    conforms "OrganizationId" (OrganizationId "org_openapi")
    conforms "AccountId" (AccountId "acct_openapi")
    conforms "SessionId" (SessionId "sess_openapi")
    conforms "CorrelationId" (CorrelationId "corr_openapi")
    conforms "CausationId" (CausationId "cause_openapi")
    conforms "SourceEventId" (SourceEventId "source_openapi")

  it "documents the partial batch acknowledgement components" $ do
    List.sort (Key.toText <$> KeyMap.keys (objectAt ["components", "schemas", "BatchAck", "properties"] documentValue))
      `shouldBe` ["accepted", "rejected"]
    List.sort (Key.toText <$> KeyMap.keys (objectAt ["components", "schemas", "RejectedEvent", "properties"] documentValue))
      `shouldBe` ["errors", "eventId", "index"]

  it "keeps the Servant-routed and documented path sets equal" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_ (assertRouted manager port) expectedServedPaths
      missing <- get manager port "/v1/definitely-missing"
      HTTP.responseStatus missing `shouldBe` status404
      envelope <- decodeBody @ErrorEnvelopeWire (HTTP.responseBody missing)
      code envelope `shouldBe` "not_found"

  it "pins health, readiness, and OpenAPI as the only WAI-level allowlist" $ do
    traverse_ (\path -> path `shouldNotSatisfy` (`elem` documentedPaths)) operationalPaths
    Warp.testWithApplication (pure (waiWrapper alwaysReadyProbe sentinelApplication)) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      health <- get manager port "/health"
      HTTP.responseStatus health `shouldBe` status200
      HTTP.responseBody health `shouldBe` "OK"

      ready <- get manager port "/ready"
      HTTP.responseStatus ready `shouldBe` status200
      readyBody <- decodeBody @Aeson.Value (HTTP.responseBody ready)
      lookupText ["status"] readyBody `shouldBe` Just "ready"

      openapi <- get manager port "/openapi.json"
      HTTP.responseStatus openapi `shouldBe` status200
      decodeBody @Aeson.Value (HTTP.responseBody openapi) `shouldReturn` documentValue

expectedServedPaths :: [Text]
expectedServedPaths =
  List.sort
    [ "/metrics/acquisition",
      "/metrics/conversion",
      "/metrics/custom",
      "/metrics/events",
      "/metrics/feature-adoption",
      "/metrics/funnel",
      "/metrics/organizations",
      "/metrics/page-views",
      "/metrics/retention",
      "/metrics/sessions",
      "/metrics/users",
      "/v1/batch",
      "/v1/events"
    ]

operationalPaths :: [Text]
operationalPaths = ["/health", "/ready", "/openapi.json"]

expectedOperationIds :: [(Text, Text, Text)]
expectedOperationIds =
  [ ("/metrics/acquisition", "get", "getMetricsAcquisition"),
    ("/metrics/conversion", "get", "getMetricsConversion"),
    ("/metrics/custom", "get", "getMetricsCustom"),
    ("/metrics/events", "get", "getMetricsEvents"),
    ("/metrics/feature-adoption", "get", "getMetricsFeatureAdoption"),
    ("/metrics/funnel", "get", "getMetricsFunnel"),
    ("/metrics/organizations", "get", "getMetricsOrganizations"),
    ("/metrics/page-views", "get", "getMetricsPageViews"),
    ("/metrics/retention", "get", "getMetricsRetention"),
    ("/metrics/sessions", "get", "getMetricsSessions"),
    ("/metrics/users", "get", "getMetricsUsers"),
    ("/v1/batch", "post", "postV1Batch"),
    ("/v1/events", "post", "postV1Events")
  ]

type OperationValue = (Text, Text, Aeson.Value)

documentValue :: Aeson.Value
documentValue = Aeson.toJSON kansokuOpenApi

documentedPaths :: [Text]
documentedPaths =
  List.sort (Key.toText <$> KeyMap.keys (objectAt ["paths"] documentValue))

operationValues :: [OperationValue]
operationValues =
  [ (path, method, operation)
  | (pathKey, Aeson.Object pathItem) <- KeyMap.toList (objectAt ["paths"] documentValue),
    let path = Key.toText pathKey,
    (methodKey, operation) <- KeyMap.toList pathItem,
    let method = Key.toText methodKey,
    method `elem` (["get", "post", "put", "patch", "delete"] :: [Text])
  ]

operationIdentity :: OperationValue -> (Text, Text, Text)
operationIdentity (path, method, operation) =
  (path, method, fromMaybe "" (lookupText ["operationId"] operation))

assertStatuses :: OperationValue -> Expectation
assertStatuses (path, method, operation) = do
  let actual = List.sort (Key.toText <$> KeyMap.keys (objectAt ["responses"] operation))
      success = if method == "post" then "202" else "200"
  actual `shouldBe` List.sort [success, "400", "404", "413", "503"]
  path `shouldSatisfy` (`elem` expectedServedPaths)

conforms :: (ToJSON a, ToSchema a) => String -> a -> Expectation
conforms label value =
  case validateToJSON value of
    [] -> pure ()
    errors -> expectationFailure (label <> " does not match its schema: " <> show errors)

sampleMetricPoint :: Metrics.MetricPoint
sampleMetricPoint =
  Metrics.MetricPoint
    { Metrics.bucket = Just "2026-06-01T00:00:00Z",
      Metrics.group = Map.singleton "plan" "pro",
      Metrics.value = 1
    }

sampleEvent :: AnalyticsEvent
sampleEvent =
  baseEvent
    (EventId "evt_openapi")
    (EventName "page_view")
    Web
    (read "2026-06-01 09:00:00 UTC")
    (read "2026-06-01 09:00:01 UTC")

sentinelApplication :: Application
sentinelApplication =
  serveWithContext
    kansokuAPI
    (envelopeFormatters :. EmptyContext)
    sentinelKansokuServer

alwaysReadyProbe :: ReadyProbe
alwaysReadyProbe =
  ReadyProbe
    { writerAlive = pure True,
      pgmqReachable = pure (Right ())
    }

assertRouted :: HTTP.Manager -> Warp.Port -> Text -> Expectation
assertRouted manager port path = do
  response <- requestForPath manager port path
  HTTP.responseStatus response `shouldBe` expectedStatus path
  when (HTTP.responseStatus response == status404) $ do
    envelope <- decodeBody @ErrorEnvelopeWire (HTTP.responseBody response)
    code envelope `shouldBe` "not_implemented"

expectedStatus :: Text -> Status
expectedStatus path
  | path `elem` ["/v1/events", "/v1/batch"] = status202
  | path `elem` ["/metrics/acquisition", "/metrics/feature-adoption", "/metrics/organizations", "/metrics/custom"] = status404
  | otherwise = status200

requestForPath :: HTTP.Manager -> Warp.Port -> Text -> IO (HTTP.Response BSL.ByteString)
requestForPath manager port path
  | path == "/v1/events" = post manager port path (Aeson.encode sampleEvent)
  | path == "/v1/batch" = post manager port path (Aeson.encode [sampleEvent])
  | otherwise = get manager port (path <> metricQuery path)

metricQuery :: Text -> Text
metricQuery path
  | path == "/metrics/funnel" = base <> "&steps=signup_started,signup_completed"
  | path == "/metrics/retention" = base <> "&days=1,7"
  | otherwise = base
  where
    base = "?from=2026-06-01&to=2026-06-02"

get :: HTTP.Manager -> Warp.Port -> Text -> IO (HTTP.Response BSL.ByteString)
get manager port path =
  HTTP.parseRequest (baseUrl port <> Text.unpack path) >>= (`HTTP.httpLbs` manager)

post :: HTTP.Manager -> Warp.Port -> Text -> BSL.ByteString -> IO (HTTP.Response BSL.ByteString)
post manager port path body = do
  initial <- HTTP.parseRequest (baseUrl port <> Text.unpack path)
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

lookupText :: [Text] -> Aeson.Value -> Maybe Text
lookupText path value =
  case valueAt path value of
    Just (Aeson.String text) -> Just text
    _ -> Nothing

lookupTextArray :: [Text] -> Aeson.Value -> Maybe [Text]
lookupTextArray path value =
  case valueAt path value of
    Just (Aeson.Array values) -> Just [text | Aeson.String text <- Foldable.toList values]
    _ -> Nothing

objectAt :: [Text] -> Aeson.Value -> Aeson.Object
objectAt path value =
  case valueAt path value of
    Just (Aeson.Object object) -> object
    _ -> mempty

valueAt :: [Text] -> Aeson.Value -> Maybe Aeson.Value
valueAt [] value = Just value
valueAt (key : rest) (Aeson.Object object) =
  KeyMap.lookup (Key.fromText key) object >>= valueAt rest
valueAt _ _ = Nothing

containsEnumValue :: Text -> Aeson.Value -> Bool
containsEnumValue expected = \case
  Aeson.Object object ->
    enumHasExpected object || any (containsEnumValue expected) object
  Aeson.Array values ->
    any (containsEnumValue expected) values
  _ ->
    False
  where
    enumHasExpected object =
      case KeyMap.lookup "enum" object of
        Just (Aeson.Array values) ->
          expected `elem` [text | Aeson.String text <- Foldable.toList values]
        _ ->
          False

operationParameterNames :: Aeson.Value -> [Text]
operationParameterNames operation =
  case valueAt ["parameters"] operation of
    Just (Aeson.Array values) ->
      [ name
      | Aeson.Object parameter <- Foldable.toList values,
        Just (Aeson.String name) <- [KeyMap.lookup "name" parameter]
      ]
    _ -> []
