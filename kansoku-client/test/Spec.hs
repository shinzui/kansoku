module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlphaNum)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Format (defaultTimeLocale, formatTime)
import Kansoku.Api.Response (ErrorEnvelopeWire (..))
import Kansoku.Client
import Kansoku.Event
import Kansoku.Prelude
import Network.HTTP.Types (Status, status202, status400, status503)
import Network.Wai (Application, Request, pathInfo, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
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
      event ^. #organizationId `shouldBe` Just (OrganizationId "org-1")
      event ^. #accountId `shouldBe` Just (AccountId "acct-1")
      event ^. #sessionId `shouldBe` Just (SessionId "sess-1")
      KeyMap.lookup (Key.fromString "plan") (event ^. #properties) `shouldBe` Just (Aeson.String "pro")
      KeyMap.lookup (Key.fromString "userId") (event ^. #properties) `shouldBe` Just (Aeson.String "property-only")

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

  it "does not retry a non-retryable API rejection" $
    withRecorder (const (pure status400)) $ \port _ attempts -> do
      client <- newClient ((testConfig port) & #maxRetries .~ 3 & #retryBaseDelayMicros .~ 1_000)
      trackEvent client emptyIds "invalid_event" []
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

  it "skips the live integration test unless KANSOKU_SERVER_URL is set" $ do
    server <- lookupEnv "KANSOKU_SERVER_URL"
    case server of
      Nothing -> pendingWith "KANSOKU_SERVER_URL is not set"
      Just url -> do
        now <- getCurrentTime
        let eventName = "kansoku_client_integration_" <> Text.pack (filter isAlphaNum (formatTime defaultTimeLocale "%FT%T%QZ" now))
        withClient ((defaultClientConfig (Text.pack url)) & #batchMaxSize .~ 2) $ \client -> do
          trackEvent client emptyIds eventName []
          flush client
        pollClickHouseCount eventName `shouldReturn` 1

testConfig :: Int -> ClientConfig
testConfig port =
  (defaultClientConfig ("http://127.0.0.1:" <> Text.pack (show port)))
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
  atomically (modifyTVar' attempts (+ 1))
  body <- strictRequestBody request
  status <- nextStatus attempts
  when (requestMethod request == "POST" && pathInfo request == ["v1", "batch"]) $
    atomically (modifyTVar' received (<> [body]))
  respond (responseLBS status [("content-type", "application/json")] (responseBodyFor status request body))

responseBodyFor :: Status -> Request -> LBS.ByteString -> LBS.ByteString
responseBodyFor status _request _body
  | status == status400 =
      Aeson.encode ErrorEnvelopeWire {code = "validation_failed", message = "validation failed", retryable = False}
  | status == status503 =
      Aeson.encode ErrorEnvelopeWire {code = "queue_unavailable", message = "analytics queue is unavailable", retryable = True}
responseBodyFor _status request body
  | pathInfo request == ["v1", "events"] = "{\"accepted\":1,\"eventId\":\"test\"}"
  | otherwise =
      case Aeson.decode body :: Maybe [AnalyticsEvent] of
        Just events -> Aeson.encode (Aeson.object ["accepted" Aeson..= length events])
        Nothing -> "{\"accepted\":0}"

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
