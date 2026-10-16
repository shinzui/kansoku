{-# LANGUAGE TypeApplications #-}

module Kansoku.OpenApiSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (traverse_)
import Data.Foldable qualified as Foldable
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.OpenApi (ToSchema, validateToJSON)
import Data.Text qualified as Text
import Kansoku.Api (kansokuAPI)
import Kansoku.Api.OpenApi (kansokuOpenApi)
import Kansoku.Api.Response (ProblemDetails (..), problem)
import Kansoku.Cohort.Types qualified as Cohort
import Kansoku.Event
import Kansoku.Ingest.Api qualified as Ingest
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.RoutingSpec (sentinelContext, sentinelKansokuServer)
import Kansoku.Prelude
import Kansoku.Readiness (ReadyCheckFailure (..))
import Kansoku.Server (ReadyProbe (..), internalMetrics, waiWrapper)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
  ( Status,
    hContentType,
    methodPost,
    status200,
    status202,
    status404,
    status503,
  )
import Network.Wai (Application)
import Network.Wai.Handler.Warp qualified as Warp
import Servant (serveWithContext)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Api.OpenApi.kansokuOpenApi" $ do
  it "reports OpenAPI 3.1 and keeps lowercase enum wire tags" $ do
    lookupText ["openapi"] documentValue `shouldSatisfy` maybe False (Text.isPrefixOf "3.1")
    lookupTextArray ["components", "schemas", "EventSource", "enum"] documentValue
      `shouldSatisfy` maybe False (elem "web")
    documentValue `shouldSatisfy` containsEnumValue "hour"

  it "declares write-key and service-token security schemes" $ do
    lookupText ["components", "securitySchemes", "writeKey", "type"] documentValue `shouldBe` Just "apiKey"
    lookupText ["components", "securitySchemes", "writeKey", "name"] documentValue `shouldBe` Just "X-Api-Key"
    lookupText ["components", "securitySchemes", "serviceToken", "scheme"] documentValue `shouldBe` Just "bearer"
    traverse_ assertSecurity operationValues

  it "documents exactly the analytics and cohort paths with stable operation IDs" $ do
    documentedPaths `shouldBe` expectedServedPaths
    fmap operationIdentity operationValues `shouldMatchList` expectedOperationIds

  it "declares one success and the shared error tail on every operation" $
    traverse_ assertStatuses operationValues

  it "documents problem JSON with schemas on every error, including authentication" $
    traverse_
      ( \(path, method, operation) ->
          traverse_
            ( \(key, response) ->
                if Key.toText key < "400"
                  then pure ()
                  else
                    if isRelayPage path method && Key.toText key == "400"
                      then do
                        KeyMap.keys (objectAt ["content"] response) `shouldMatchList` ["application/json", "application/json;charset=utf-8"]
                        lookupText ["content", "application/json", "schema", "$ref"] response `shouldBe` Just "#/components/schemas/RelayPageError"
                      else do
                        let contents = objectAt ["content"] response
                        KeyMap.keys contents `shouldBe` ["application/problem+json"]
                        lookupText ["content", "application/problem+json", "schema", "$ref"] response
                          `shouldBe` Just "#/components/schemas/ProblemDetails"
            )
            (KeyMap.toList (objectAt ["responses"] operation))
      )
      operationValues

  it "documents ordered funnel semantics and the optional window parameter" $ do
    let funnelOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/funnel", "get"] documentValue)
    lookupText ["description"] funnelOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "millisecond occurred_at then event_id")
    operationParameterNames funnelOperation `shouldContain` ["window", "mode", "measure", "exclude", "groupBy", "filter"]

  it "documents closed-day retained-history retention modes and offset zero" $ do
    let retentionOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/retention", "get"] documentValue)
    lookupText ["description"] retentionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "first matching activity in retained history")
    lookupText ["description"] retentionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "Offset 0")

  it "documents declared-property grouping and the two-dimension limit" $ do
    let revenueOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/revenue", "get"] documentValue)
    lookupText ["description"] revenueOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "prop:")
    lookupText ["description"] revenueOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "one or two distinct dimensions")

  it "documents exposure accuracy and post-exposure conversion semantics" $ do
    let exposuresOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/experiments", "get"] documentValue)
        conversionOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/experiments/conversion", "get"] documentValue)
        funnelOperation = fromMaybe Aeson.Null (valueAt ["paths", "/metrics/experiments/funnel", "get"] documentValue)
    lookupText ["description"] exposuresOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "uniqCombined raw-identity exposure counts")
    lookupText ["description"] conversionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "at or after their first exposure")
    lookupText ["description"] conversionOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "no significance testing")
    lookupText ["description"] funnelOperation
      `shouldSatisfy` maybe False (Text.isInfixOf "at or after that user/variant first exposure")
    operationParameterNames funnelOperation `shouldContain` ["window", "mode", "measure", "exclude", "groupBy", "filter"]

  it "keeps every wire DTO's ToJSON representation within its ToSchema" $ do
    conforms "AnalyticsEvent" sampleEvent
    conforms "IngestAck" Ingest.IngestAck {Ingest.accepted = 1, Ingest.eventId = "evt_openapi"}
    conforms "BeaconEnvelope" (Ingest.BeaconEnvelope "ksk_w_fixture" [Ingest.ingestEvent sampleEvent])
    conforms "BatchAck" Ingest.BatchAck {Ingest.accepted = 1, Ingest.rejected = []}
    conforms
      "RejectedEvent"
      Ingest.RejectedEvent
        { Ingest.index = 0,
          Ingest.eventId = Nothing,
          Ingest.errors = ["eventId must not be empty"]
        }
    conforms "CohortDefinition" (Cohort.CohortDefinition "beta" "static" [] [])
    conforms "CohortCondition" (Cohort.CohortCondition (Just "feature_used") Nothing (Just 3) Nothing 30 [])
    conforms "CohortMembers" (Cohort.CohortMembers ["alice", "bob"])
    conforms "CohortSize" (Cohort.CohortSize 2)
    conforms "MetricPoint" sampleMetricPoint
    conforms "MetricResult" Metrics.MetricResult {Metrics.metric = "events", Metrics.points = [sampleMetricPoint]}
    conforms "TimeGrain" Metrics.Hour
    conforms "ProblemDetails" (problem 404 "not_found" "no such endpoint")
    conforms "SchemaCatalog" (schemaCatalog defaultRegistry)
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

  it "documents identifiers as an optional string-valued object" $ do
    lookupText ["components", "schemas", "AnalyticsEvent", "properties", "identifiers", "type"] documentValue
      `shouldBe` Just "object"
    lookupText ["components", "schemas", "AnalyticsEvent", "properties", "identifiers", "additionalProperties", "type"] documentValue
      `shouldBe` Just "string"
    lookupTextArray ["components", "schemas", "AnalyticsEvent", "required"] documentValue
      `shouldSatisfy` maybe True (notElem "identifiers")

  it "documents schemaVersion as an optional integer" $ do
    lookupText ["components", "schemas", "AnalyticsEvent", "properties", "schemaVersion", "type"] documentValue
      `shouldBe` Just "integer"
    lookupTextArray ["components", "schemas", "AnalyticsEvent", "required"] documentValue
      `shouldSatisfy` maybe True (notElem "schemaVersion")

  it "keeps the Servant-routed and documented path sets equal" $
    Warp.testWithApplication (pure sentinelApplication) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      traverse_ (assertRouted manager port) expectedServedPaths
      missing <- get manager port "/v1/definitely-missing"
      HTTP.responseStatus missing `shouldBe` status404
      envelope <- decodeBody @ProblemDetails (HTTP.responseBody missing)
      code envelope `shouldBe` "not_found"

  it "pins health, readiness, internal metrics, and OpenAPI as the WAI-level allowlist" $ do
    traverse_ (\path -> path `shouldNotSatisfy` (`elem` documentedPaths)) operationalPaths
    Warp.testWithApplication (pure (waiWrapper alwaysReadyProbe (internalMetrics True sentinelApplication))) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      health <- get manager port "/health"
      HTTP.responseStatus health `shouldBe` status200
      HTTP.responseBody health `shouldBe` "OK"

      ready <- get manager port "/ready"
      HTTP.responseStatus ready `shouldBe` status200
      readyBody <- decodeBody @Aeson.Value (HTTP.responseBody ready)
      lookupText ["status"] readyBody `shouldBe` Just "ready"
      checkNames readyBody
        `shouldBe` ["writer_alive", "pgmq_reachable", "clickhouse_query_reachable", "queue_depth", "writer_flush_stale"]

      openapi <- get manager port "/openapi.json"
      HTTP.responseStatus openapi `shouldBe` status200
      decodeBody @Aeson.Value (HTTP.responseBody openapi) `shouldReturn` documentValue

      metrics <- get manager port "/internal/metrics"
      HTTP.responseStatus metrics `shouldBe` status200
      BSL.toStrict (HTTP.responseBody metrics)
        `shouldSatisfy` BS8.isInfixOf "kansoku_queue_length"

  it "renders named pipeline readiness failures with observations"
    $ Warp.testWithApplication
      (pure (waiWrapper failingPipelineProbe sentinelApplication))
    $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      ready <- get manager port "/ready"
      HTTP.responseStatus ready `shouldBe` status503
      readyBody <- decodeBody @Aeson.Value (HTTP.responseBody ready)
      lookupText ["status"] readyBody `shouldBe` Just "unavailable"
      valueAt ["checks"] readyBody
        `shouldSatisfy` maybe False (containsFailedCheck "queue_depth" 101)

expectedServedPaths :: [Text]
expectedServedPaths =
  List.sort
    [ "/cohorts",
      "/cohorts/{id}",
      "/cohorts/{id}/members",
      "/cohorts/{id}/size",
      "/metrics/acquisition",
      "/metrics/conversion",
      "/metrics/custom",
      "/metrics/events",
      "/metrics/experiments",
      "/metrics/experiments/conversion",
      "/metrics/experiments/funnel",
      "/metrics/feature-adoption",
      "/metrics/funnel",
      "/metrics/lifecycle",
      "/metrics/organizations",
      "/metrics/page-views",
      "/metrics/paths",
      "/metrics/retention",
      "/metrics/revenue",
      "/metrics/sessions",
      "/metrics/stickiness",
      "/metrics/users",
      "/v1/batch",
      "/v1/beacon",
      "/v1/events",
      "/v1/schemas"
    ]

operationalPaths :: [Text]
operationalPaths = ["/health/live", "/health/ready", "/health", "/ready", "/internal/metrics", "/openapi.json"]

expectedOperationIds :: [(Text, Text, Text)]
expectedOperationIds =
  [ ("/cohorts", "get", "getCohorts"),
    ("/cohorts", "post", "postCohorts"),
    ("/cohorts/{id}", "get", "getCohortsId"),
    ("/cohorts/{id}", "put", "putCohortsId"),
    ("/cohorts/{id}", "delete", "deleteCohortsId"),
    ("/cohorts/{id}/members", "get", "getCohortsIdMembers"),
    ("/cohorts/{id}/members", "put", "putCohortsIdMembers"),
    ("/cohorts/{id}/size", "get", "getCohortsIdSize"),
    ("/metrics/acquisition", "get", "getMetricsAcquisition"),
    ("/metrics/conversion", "get", "getMetricsConversion"),
    ("/metrics/custom", "get", "getMetricsCustom"),
    ("/metrics/events", "get", "getMetricsEvents"),
    ("/metrics/experiments", "get", "getMetricsExperiments"),
    ("/metrics/experiments/conversion", "get", "getMetricsExperimentsConversion"),
    ("/metrics/experiments/funnel", "get", "getMetricsExperimentsFunnel"),
    ("/metrics/feature-adoption", "get", "getMetricsFeatureAdoption"),
    ("/metrics/funnel", "get", "getMetricsFunnel"),
    ("/metrics/lifecycle", "get", "getMetricsLifecycle"),
    ("/metrics/organizations", "get", "getMetricsOrganizations"),
    ("/metrics/page-views", "get", "getMetricsPageViews"),
    ("/metrics/paths", "get", "getMetricsPaths"),
    ("/metrics/retention", "get", "getMetricsRetention"),
    ("/metrics/revenue", "get", "getMetricsRevenue"),
    ("/metrics/sessions", "get", "getMetricsSessions"),
    ("/metrics/stickiness", "get", "getMetricsStickiness"),
    ("/metrics/users", "get", "getMetricsUsers"),
    ("/v1/batch", "post", "postV1Batch"),
    ("/v1/beacon", "post", "postV1Beacon"),
    ("/v1/events", "post", "postV1Events"),
    ("/v1/schemas", "get", "getV1Schemas")
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
      success = if method == "post" && not ("/cohorts" `Text.isPrefixOf` path) then "202" else "200"
      authStatuses
        | "/metrics/" `Text.isPrefixOf` path || "/cohorts" `Text.isPrefixOf` path || path == "/v1/beacon" = ["401", "403"]
        | otherwise = ["401"]
      expected
        | path == "/v1/schemas" = ["200", "405", "406", "413", "500"]
        | isRelayPage path method = ["200", "400", "401", "403", "404", "405", "406", "413", "500", "503"]
        | otherwise = [success, "400", "404", "405", "406", "413", "429", "500", "503"] <> authStatuses <> ["415" | method `elem` ["post", "put"]]
  actual `shouldBe` List.sort expected
  when (path /= "/v1/schemas") $ do
    lookupText ["responses", "401", "headers", "WWW-Authenticate", "schema", "type"] operation
      `shouldBe` Just "string"
    valueAt ["responses", "401", "headers", "WWW-Authenticate", "required"] operation
      `shouldBe` Just (Aeson.Bool True)
  when (path /= "/v1/schemas" && not (isRelayPage path method)) $ do
    lookupText ["responses", "429", "headers", "Retry-After", "schema", "type"] operation
      `shouldBe` Just "integer"
    valueAt ["responses", "429", "headers", "Retry-After", "required"] operation
      `shouldBe` Just (Aeson.Bool True)
  path `shouldSatisfy` (`elem` expectedServedPaths)

assertSecurity :: OperationValue -> Expectation
assertSecurity (path, _method, operation) =
  case (path, valueAt ["security"] operation) of
    ("/v1/beacon", Nothing) -> pure ()
    ("/v1/schemas", Nothing) -> pure ()
    ("/v1/schemas", Just (Aeson.Array requirements))
      | null requirements -> pure ()
    ("/v1/schemas", securityValue) ->
      expectationFailure ("public schema operation unexpectedly secured: " <> show securityValue)
    (_, Just (Aeson.Array requirements))
      | "/metrics/" `Text.isPrefixOf` path || "/cohorts" `Text.isPrefixOf` path ->
          requirements `shouldSatisfy` any (containsObjectKey "serviceToken")
      | otherwise ->
          requirements `shouldSatisfy` any (containsObjectKey "writeKey")
    (_, securityValue) -> expectationFailure ("missing operation security for " <> Text.unpack path <> ": " <> show securityValue)

containsObjectKey :: Text -> Aeson.Value -> Bool
containsObjectKey key = \case
  Aeson.Object object -> KeyMap.member (Key.fromText key) object
  _ -> False

conforms :: (ToJSON a, ToSchema a) => String -> a -> Expectation
conforms label value =
  case validateToJSON value of
    [] -> pure ()
    errors -> expectationFailure (label <> " does not match its schema: " <> show errors)

sampleMetricPoint :: Metrics.MetricPoint
sampleMetricPoint =
  Metrics.MetricPoint
    { Metrics.bucket = Just "2026-06-01T00:00:00Z",
      Metrics.group = Map.fromList [("prop:plan", Just "pro"), ("host", Nothing)],
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
    sentinelContext
    sentinelKansokuServer

alwaysReadyProbe :: ReadyProbe
alwaysReadyProbe =
  ReadyProbe
    { writerAlive = pure True,
      pgmqReachable = pure (Right ()),
      clickhouseReachable = pure True,
      pipelineReady = pure []
    }

failingPipelineProbe :: ReadyProbe
failingPipelineProbe =
  alwaysReadyProbe & #pipelineReady .~ pure [QueueDepthExceeded {observed = 101, limit = 100}]

assertRouted :: HTTP.Manager -> Warp.Port -> Text -> Expectation
assertRouted manager port path = do
  response <- requestForPath manager port path
  HTTP.responseStatus response `shouldBe` expectedStatus path
  when (HTTP.responseStatus response == status404) $ do
    envelope <- decodeBody @ProblemDetails (HTTP.responseBody response)
    code envelope `shouldBe` "not_implemented"

expectedStatus :: Text -> Status
expectedStatus path
  | path `elem` ["/v1/events", "/v1/batch", "/v1/beacon"] = status202
  | path `elem` ["/metrics/organizations", "/metrics/custom"] = status404
  | otherwise = status200

requestForPath :: HTTP.Manager -> Warp.Port -> Text -> IO (HTTP.Response BSL.ByteString)
requestForPath manager port path
  | path == "/v1/events" = post manager port path (Aeson.encode sampleEvent)
  | path == "/v1/beacon" = post manager port path (Aeson.encode (Ingest.BeaconEnvelope "ksk_w_fixture" [Ingest.ingestEvent sampleEvent]))
  | path == "/v1/batch" = post manager port path (Aeson.encode [sampleEvent])
  | otherwise = get manager port (Text.replace "{id}" "00000000-0000-0000-0000-000000000000" path <> metricQuery path)

metricQuery :: Text -> Text
metricQuery path
  | path == "/metrics/funnel" = base <> "&steps=signup_started,signup_completed"
  | path == "/metrics/retention" = base <> "&days=1,7"
  | path == "/metrics/experiments/conversion" = base <> "&experiment=checkout_v2&event=purchase_completed"
  | path == "/metrics/experiments/funnel" = base <> "&experiment=checkout_v2&steps=checkout_started,purchase_completed"
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

checkNames :: Aeson.Value -> [Text]
checkNames body =
  case valueAt ["checks"] body of
    Just (Aeson.Array checks) ->
      [ name
      | check <- Foldable.toList checks,
        Just name <- [lookupText ["check"] check]
      ]
    _ -> []

containsFailedCheck :: Text -> Int -> Aeson.Value -> Bool
containsFailedCheck expectedName expectedObserved = \case
  Aeson.Array checks -> any matches (Foldable.toList checks)
  _ -> False
  where
    matches check =
      lookupText ["check"] check == Just expectedName
        && valueAt ["ok"] check == Just (Aeson.Bool False)
        && valueAt ["observed"] check == Just (Aeson.toJSON expectedObserved)

-- These two Relay endpoints use the released pagination 400 JSON exemption.
isRelayPage :: Text -> Text -> Bool
isRelayPage path method = method == "get" && path `elem` ["/cohorts", "/cohorts/{id}/members"]
