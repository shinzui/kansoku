module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlphaNum)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTime)
import Kansoku.Api.Response (KansokuResult (..), problem)
import Kansoku.Api.Response qualified as Response
import Kansoku.Client
import Kansoku.Client.Metrics
import Kansoku.Event
import Kansoku.Metrics.Api (MetricResult (..), TimeGrain (Day))
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types (Status, status200, status202, status400, status401, status404, status413, status429, status503, statusCode)
import Network.HTTP.Types.Header (hAuthorization)
import Network.Wai (Application, Request, pathInfo, queryString, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import Servant.Client (mkClientEnv, parseBaseUrl, runClientM)
import System.Environment (lookupEnv)
import System.Process (readProcess)
import Test.Hspec
import Text.Read (readMaybe)

main :: IO ()
main =
  hspec spec

spec :: Spec
spec = describe "Kansoku.Client" $ do
  it "trackEvent builds service-source events with identity fields outside properties" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      let ids =
            emptyIds
              & #userId
              ?~ "user-1"
              & #anonymousId
              ?~ "anon-1"
              & #identifiers
              ?~ Map.fromList [("fingerprint", "fp-1"), ("device", "dev-1"), ("email_hmac", "v1:opaque")]
              & #organizationId
              ?~ "org-1"
              & #accountId
              ?~ "acct-1"
              & #sessionId
              ?~ "sess-1"
      withClient (testConfig port) $ \client -> do
        trackEvent client ids "user_registered" ["plan" Aeson..= ("pro" :: Text), "userId" Aeson..= ("property-only" :: Text)]
        flush client
      [event] <- readEvents received
      event ^. #eventName `shouldBe` EventName "user_registered"
      event ^. #source `shouldBe` Service
      event ^. #userId `shouldBe` Just (UserId "user-1")
      event ^. #anonymousId `shouldBe` Just (AnonymousId "anon-1")
      event ^. #identifiers
        `shouldBe` Just (Map.fromList [("fingerprint", "fp-1"), ("device", "dev-1"), ("email_hmac", "v1:opaque")])
      event ^. #organizationId `shouldBe` Just (OrganizationId "org-1")
      event ^. #accountId `shouldBe` Just (AccountId "acct-1")
      event ^. #sessionId `shouldBe` Just (SessionId "sess-1")
      KeyMap.lookup (Key.fromString "plan") (event ^. #properties) `shouldBe` Just (Aeson.String "pro")
      KeyMap.lookup (Key.fromString "userId") (event ^. #properties) `shouldBe` Just (Aeson.String "property-only")

  it "trackEventWithVersion pins the shared wire field" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      withClient (testConfig port) $ \client -> do
        trackEventWithVersion client emptyIds "page_view" 1 ["url" Aeson..= ("https://example.com" :: Text)]
        flush client
      [event] <- readEvents received
      event ^. #schemaVersion `shouldBe` Just 1

  it "round-trips a helper-built event through the shared AnalyticsEvent JSON type" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      withClient (testConfig port) $ \client -> do
        identify client "user-2" (Just "anon-2") ["trait" Aeson..= ("value" :: Text)]
        flush client
      [event] <- readEvents received
      Aeson.decode (Aeson.encode event) `shouldBe` Just event
      event ^. #eventName `shouldBe` EventName "identify"
      event ^. #userId `shouldBe` Just (UserId "user-2")
      event ^. #anonymousId `shouldBe` Just (AnonymousId "anon-2")

  it "flushes batches at batch size" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      withClient ((testConfig port) & #batchMaxSize .~ 100 & #batchMaxIntervalMicros .~ 10000000) $ \client -> do
        traverse_ (\n -> trackEvent client emptyIds ("event_" <> Text.pack (show n)) []) [1 :: Int .. 250]
        flush client
      lengths <- fmap length <$> readBatches received
      lengths `shouldBe` [100, 100, 50]

  it "flushes on interval" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      client <- newClient ((testConfig port) & #batchMaxSize .~ 100 & #batchMaxIntervalMicros .~ 50000)
      trackEvent client emptyIds "interval_event" []
      threadDelay 200_000
      close client
      lengths <- fmap length <$> readBatches received
      lengths `shouldBe` [1]

  it "retries failed batch delivery with the same event id" $
    withRecorder (failNTimes 2) $ \port received attempts -> do
      withClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000) $ \client -> do
        trackEvent client emptyIds "retry_event" []
        flush client
      readTVarIO attempts `shouldReturn` 3
      batches <- readBatches received
      fmap length batches `shouldBe` [1, 1, 1]
      length (uniqueEventIds (concat batches)) `shouldBe` 1

  it "honors a real 429 Retry-After header and retries the same event ID" $
    withRecorder (\attempts -> do n <- readTVarIO attempts; pure (if n == 1 then status429 else status202)) $ \port received attempts -> do
      started <- getMonotonicTime
      withClient ((testConfig port) & #maxRetries .~ 2 & #retryBaseDelayMicros .~ 1_000) $ \client -> do
        trackEvent client emptyIds "rate_limited_event" []
        flush client
        droppedCount client `shouldReturn` 0
      elapsed <- subtract started <$> getMonotonicTime
      elapsed `shouldSatisfy` (>= 1)
      readTVarIO attempts `shouldReturn` 2
      batches <- readBatches received
      fmap length batches `shouldBe` [1, 1]
      length (uniqueEventIds (concat batches)) `shouldBe` 1

  it "does not retry a non-retryable API rejection" $
    withRecorder (const (pure status400)) $ \port _ attempts -> do
      client <- newClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000)
      trackEvent client emptyIds "invalid_event" []
      flush client
      readTVarIO attempts `shouldReturn` 1
      droppedCount client `shouldReturn` 1
      close client

  it "does not retry an authentication rejection received before the typed handler" $
    withRecorder (const (pure status401)) $ \port _ attempts -> do
      client <- newClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000)
      trackEvent client emptyIds "unauthorized_event" []
      flush client
      readTVarIO attempts `shouldReturn` 1
      droppedCount client `shouldReturn` 1
      close client

  it "counts a per-event batch rejection as dropped without retrying" $
    withRecorder (const (pure status202)) $ \port _ attempts -> do
      client <- newClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000)
      trackEvent client emptyIds "server_rejected_event" []
      flush client
      readTVarIO attempts `shouldReturn` 1
      droppedCount client `shouldReturn` 1
      close client

  it "does not retry an oversized-batch API rejection" $
    withRecorder (const (pure status413)) $ \port _ attempts -> do
      client <- newClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000)
      trackEvent client emptyIds "oversized_batch" []
      flush client
      readTVarIO attempts `shouldReturn` 1
      droppedCount client `shouldReturn` 1
      close client

  it "drops newest events on buffer overflow" $
    withRecorder (const (pure status202)) $ \port _ _ -> do
      client <- newClient ((testConfig port) & #bufferCapacity .~ 2 & #batchMaxIntervalMicros .~ 10000000)
      trackEvent client emptyIds "overflow_1" []
      trackEvent client emptyIds "overflow_2" []
      trackEvent client emptyIds "overflow_3" []
      droppedCount client `shouldReturn` 1
      close client

  it "derives authenticated experiment metrics clients from the shared route record" $
    Warp.testWithApplication (pure metricsRecorderApp) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      base <- parseBaseUrl ("http://127.0.0.1:" <> show port)
      let env = mkClientEnv manager base
          credential = kansokuMetricsCredential "test-service-token"
          fromDay = read "2026-08-01"
          toDay = read "2026-08-08"
      exposureResult <-
        runClientM
          (experimentsClient credential fromDay toDay (Just "checkout_v2") (Just Day))
          env
      case exposureResult of
        Right (KansokuOk result) -> metric result `shouldBe` "experiment_exposures"
        other -> expectationFailure ("unexpected exposure client result: " <> show other)
      conversionResult <-
        runClientM
          (experimentConversionClient credential "checkout_v2" "purchase_completed" fromDay toDay)
          env
      case conversionResult of
        Right (KansokuOk result) -> metric result `shouldBe` "experiment_conversion"
        other -> expectationFailure ("unexpected conversion client result: " <> show other)
      funnelResult <-
        runClientM
          (experimentFunnelClient credential "checkout_v2" "checkout_started,purchase_completed" fromDay toDay (Just 604800))
          env
      case funnelResult of
        Right (KansokuOk result) -> metric result `shouldBe` "experiment_funnel"
        other -> expectationFailure ("unexpected funnel client result: " <> show other)

  it "sends typed repeatable JSON filters and decodes nullable namespaced groups" $ do
    captured <- newTVarIO []
    let app request respond = do
          atomically (modifyTVar' captured (const (queryString request)))
          respond
            ( responseLBS
                status200
                [("content-type", "application/json")]
                "{\"metric\":\"events\",\"points\":[{\"bucket\":null,\"group\":{\"source\":\"web\",\"prop:plan\":null},\"value\":1}]}"
            )
    input <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "source_service" Filter.FilterEq (Just (Aeson.String "é:|,\"\\")))
    secondInput <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "source" Filter.FilterEq (Just (Aeson.String "web")))
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      base <- parseBaseUrl ("http://127.0.0.1:" <> show port)
      result <-
        runClientM
          (Metrics.events metricsClient (kansokuMetricsCredential "test-service-token") (read "2026-07-01") (read "2026-07-02") (Just "source,prop:plan") Nothing [input, secondInput])
          (mkClientEnv manager base)
      case result of
        Right (KansokuOk payload) -> case points payload of
          [point] -> Map.lookup "prop:plan" (point ^. #group) `shouldBe` Just Nothing
          other -> expectationFailure (show other)
        other -> expectationFailure (show other)
      parameters <- readTVarIO captured
      let encodedFilters = [bytes | ("filter", Just bytes) <- parameters]
      traverse Aeson.eitherDecodeStrict' encodedFilters `shouldBe` Right [input, secondInput]

  it "decodes permanent metric limit problems through the generated client" $ do
    attempts <- newTVarIO (0 :: Int)
    let app _ respond = do
          atomically (modifyTVar' attempts (+ 1))
          respond (responseLBS status400 [("content-type", "application/problem+json")] (Aeson.encode (problem 400 "metric_result_too_large" "narrow the query")))
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- HTTP.newManager HTTP.defaultManagerSettings
      base <- parseBaseUrl ("http://127.0.0.1:" <> show port)
      result <- runClientM (experimentsClient (kansokuMetricsCredential "test-service-token") (read "2026-07-01") (read "2026-07-02") Nothing Nothing) (mkClientEnv manager base)
      case result of
        Right (KansokuBadRequest rejection) -> do
          Response.code rejection `shouldBe` "metric_result_too_large"
          Response.retryable rejection `shouldBe` False
        other -> expectationFailure (show other)
      readTVarIO attempts `shouldReturn` 1

  it "reserves alias IDs against custom property overrides" $
    withRecorder (const (pure status202)) $ \port received _ -> do
      withClient (testConfig port) $ \client -> do
        alias client "anon" "user" ["previousId" Aeson..= ("spoof" :: Text), "newId" Aeson..= ("spoof" :: Text)]
        flush client
      events <- readEvents received
      case events of
        [event] -> validateEvent event `shouldBe` Right event
        other -> expectationFailure (show other)

  it "fetches the public schema catalog through the shared route type" $
    Warp.testWithApplication (pure schemaRecorderApp) $ \port ->
      withClient (testConfig port) $ \client ->
        fetchSchemaCatalog client `shouldReturn` Right (schemaCatalog defaultRegistry)

  it "skips the live integration test unless KANSOKU_SERVER_URL is set" $ do
    required <- lookupEnv "KANSOKU_REQUIRED_INTEGRATION"
    server <- lookupEnv "KANSOKU_SERVER_URL"
    credential <- lookupEnv "KANSOKU_API_KEY"
    case (server, credential) of
      (Nothing, _) -> if required == Just "1" then expectationFailure "required KANSOKU_SERVER_URL is not set" else pendingWith "KANSOKU_SERVER_URL is not set"
      (_, Nothing) -> if required == Just "1" then expectationFailure "required KANSOKU_API_KEY is not set" else pendingWith "KANSOKU_API_KEY is not set"
      (Just url, Just apiKey) -> do
        now <- getCurrentTime
        let eventName = "kansoku_client_integration_" <> Text.pack (filter isAlphaNum (formatTime defaultTimeLocale "%FT%T%QZ" now))
        withClient ((defaultClientConfig (Text.pack url) (Text.pack apiKey)) & #batchMaxSize .~ 2) $ \client -> do
          trackEvent client emptyIds eventName []
          flush client
        pollClickHouseCount eventName `shouldReturn` 1

testConfig :: Int -> ClientConfig
testConfig port =
  (defaultClientConfig ("http://127.0.0.1:" <> Text.pack (show port)) "test-write-key")
    & #batchMaxIntervalMicros
    .~ 1000000
    & #retryBaseDelayMicros
    .~ 1000

withRecorder :: (TVar Int -> IO Status) -> (Int -> TVar [LBS.ByteString] -> TVar Int -> IO ()) -> IO ()
withRecorder status action = do
  received <- newTVarIO []
  attempts <- newTVarIO 0
  Warp.testWithApplication (pure (recorderApp received attempts status)) $ \port ->
    action port received attempts

recorderApp :: TVar [LBS.ByteString] -> TVar Int -> (TVar Int -> IO Status) -> Application
recorderApp received attempts nextStatus request respond = do
  if lookup hAuthorization (requestHeaders request) /= Just "Bearer test-write-key"
    then respond (responseLBS status401 [("content-type", "application/json")] "{}")
    else do
      atomically (modifyTVar' attempts (+ 1))
      body <- strictRequestBody request
      status <- nextStatus attempts
      when (requestMethod request == "POST" && pathInfo request == ["v1", "batch"]) $
        atomically (modifyTVar' received (<> [body]))
      respond (responseLBS status ([("content-type", if statusCode status >= 400 then "application/problem+json" else "application/json")] <> [("Retry-After", "1") | status == status429]) (responseBodyFor status request body))

responseBodyFor :: Status -> Request -> LBS.ByteString -> LBS.ByteString
responseBodyFor status _request _body
  | status == status401 = Aeson.encode (problem 401 "unauthorized" "missing or unknown credential")
  | status == status400 =
      Aeson.encode (problem 400 "validation_failed" "validation failed")
  | status == status429 = Aeson.encode (problem 429 "rate_limited" "ingest rate exceeded")
  | status == status503 =
      Aeson.encode (problem 503 "queue_unavailable" "analytics queue is unavailable")
  | status == status413 =
      Aeson.encode (problem 413 "batch_too_large" "batch exceeds limit")
responseBodyFor _status request body
  | pathInfo request == ["v1", "events"] = "{\"accepted\":1,\"eventId\":\"test\"}"
  | otherwise =
      case Aeson.decode body :: Maybe [AnalyticsEvent] of
        Just events
          | any ((== EventName "server_rejected_event") . (^. #eventName)) events ->
              Aeson.encode
                ( Aeson.object
                    [ "accepted" Aeson..= (length events - 1),
                      "rejected"
                        Aeson..= [ Aeson.object
                                     [ "index" Aeson..= (0 :: Int),
                                       "eventId" Aeson..= Aeson.Null,
                                       "errors" Aeson..= ["rejected by test" :: Text]
                                     ]
                                 ]
                    ]
                )
          | otherwise -> Aeson.encode (Aeson.object ["accepted" Aeson..= length events, "rejected" Aeson..= ([] :: [Aeson.Value])])
        Nothing -> "{\"accepted\":0,\"rejected\":[]}"

metricsRecorderApp :: Application
metricsRecorderApp request respond =
  if lookup hAuthorization (requestHeaders request) /= Just "Bearer test-service-token"
    then respond (responseLBS status401 [("content-type", "application/json")] "{}")
    else case pathInfo request of
      ["metrics", "experiments"]
        | queryValue "experiment" request == Just "checkout_v2",
          queryValue "timeGrain" request == Just "day" ->
            ok "experiment_exposures"
      ["metrics", "experiments", "conversion"]
        | queryValue "experiment" request == Just "checkout_v2",
          queryValue "event" request == Just "purchase_completed" ->
            ok "experiment_conversion"
      ["metrics", "experiments", "funnel"]
        | queryValue "experiment" request == Just "checkout_v2",
          queryValue "steps" request == Just "checkout_started,purchase_completed",
          queryValue "window" request == Just "604800" ->
            ok "experiment_funnel"
      _ -> respond (responseLBS status400 [("content-type", "application/json")] (Aeson.encode (problem 400 "bad_request" "unexpected metrics request")))
  where
    ok name =
      respond
        ( responseLBS
            status200
            [("content-type", "application/json")]
            (Aeson.encode MetricResult {metric = name, points = []})
        )

schemaRecorderApp :: Application
schemaRecorderApp request respond
  | requestMethod request == "GET",
    pathInfo request == ["v1", "schemas"] =
      respond
        ( responseLBS
            status200
            [("content-type", "application/json")]
            (Aeson.encode (schemaCatalog defaultRegistry))
        )
  | otherwise =
      respond (responseLBS status404 [("content-type", "application/json")] "{}")

queryValue :: ByteString -> Request -> Maybe ByteString
queryValue name request =
  lookup name (queryString request) >>= id

failNTimes :: Int -> TVar Int -> IO Status
failNTimes n attempts = do
  count <- readTVarIO attempts
  pure (if count <= n then status503 else status202)

readEvents :: TVar [LBS.ByteString] -> IO [AnalyticsEvent]
readEvents received =
  concat <$> readBatches received

readBatches :: TVar [LBS.ByteString] -> IO [[AnalyticsEvent]]
readBatches received = do
  bodies <- readTVarIO received
  pure (fromMaybe [] . Aeson.decode <$> bodies)

uniqueEventIds :: [AnalyticsEvent] -> [EventId]
uniqueEventIds =
  foldr add []
  where
    add event seen
      | event ^. #eventId `elem` seen = seen
      | otherwise = event ^. #eventId : seen

pollClickHouseCount :: Text -> IO Int
pollClickHouseCount eventName =
  go (20 :: Int)
  where
    go 0 = clickHouseCount eventName
    go remaining = do
      count <- clickHouseCount eventName
      if count == 1
        then pure count
        else threadDelay 250000 >> go (remaining - 1)

clickHouseCount :: Text -> IO Int
clickHouseCount eventName = do
  port <- fromMaybe "9000" <$> lookupEnv "CLICKHOUSE_TCP_PORT"
  raw <-
    readProcess
      "clickhouse-client"
      ["--port", port, "--query", "SELECT count(DISTINCT event_id) FROM analytics.events_raw FINAL WHERE event_name = '" <> Text.unpack eventName <> "'"]
      ""
  pure (fromMaybe 0 (readMaybe raw))
