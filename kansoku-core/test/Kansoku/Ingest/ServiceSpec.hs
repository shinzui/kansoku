module Kansoku.Ingest.ServiceSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, bracket_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID qualified as UUID
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Api.Response
import Kansoku.Auth.Types
import Kansoku.Config (loadConfig)
import Kansoku.Event
import Kansoku.Ingest.Api
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Ingest.Quarantine
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Ingest.Service (newIngestService)
import Kansoku.Observability
import Kansoku.PostgresTestSupport
import Kansoku.Prelude
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as Socket
import Pgmq qualified
import Prometheus qualified as P
import Servant (runHandler)
import System.Timeout (timeout)
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Ingest.Service" $ do
  it "commits normalization, counts outcomes and isolates bounded quarantine failures" $ withMigratedStore $ \settings connection pool -> do
    cfg <- loadConfig >>= either (fail . show) pure
    let enabled = cfg & #pgConnectionString .~ settings & #ingestQuarantine .~ True & #quarantineMaxRows .~ 2 & #quarantineMaxPayloadBytes .~ 2048
        queue = eventsQueueName "ingest_service_spec"
    service <- newIngestService enabled metrics pool queue
    let routes = ingestServer service
        single = postEvent routes principal . ingestEvent
        batch = postBatch routes principal . fmap ingestEvent
    Pool.use pool (Pgmq.createQueue queue) `shouldReturn` Right ()
    acceptedBefore <- counter (metrics ^. #ingestEventsTotal) ("accepted", "single")
    rejectedBefore <- counter (metrics ^. #ingestEventsTotal) ("rejected", "batch")
    now <- getCurrentTime
    let future = event "future" "custom" now & #occurredAt .~ addUTCTime 90 now & #sentAt ?~ addUTCTime 100 now
    runHandler (single future) `shouldReturn` Right (KansokuOk (IngestAck 1 "future"))
    stored <- Pool.use pool (Session.statement () queued) >>= either (fail . show) pure
    case Aeson.fromJSON stored of
      Aeson.Error err -> expectationFailure err
      Aeson.Success value -> do
        let elapsed = value ^. #receivedAt
        (value :: AnalyticsEvent) ^. #occurredAt `shouldBe` addUTCTime (-10) elapsed
        value ^. #sentAt `shouldBe` Nothing
        value ^. #accountId `shouldBe` Just (AccountId "ingest-service-account")
    counter (metrics ^. #ingestEventsTotal) ("accepted", "single") `shouldReturn` (acceptedBefore + 1)
    let bad = event "rejected" "page_view" now
    allInvalid <- runHandler (batch [bad, bad])
    case allInvalid of
      Right (KansokuOk ack) -> do
        ack ^. #accepted `shouldBe` 0
        length (ack ^. #rejected) `shouldBe` 2
      other -> expectationFailure (show other)
    counter (metrics ^. #ingestEventsTotal) ("rejected", "batch") `shouldReturn` (rejectedBefore + 2)
    countRows pool `shouldReturn` 2
    -- Preserve unknown fields and original client clocks, rather than the
    -- normalized/stamped representation.
    let original = case Aeson.toJSON bad of Aeson.Object object -> KM.insert "futureField" (Aeson.String "retained") object; _ -> mempty
    _ <- runHandler (postEvent routes principal (IngestEvent bad original))
    Pool.use pool (Session.statement () preserved) `shouldReturn` Right True
    _ <- runHandler (single (bad & #context .~ KM.singleton "large" (Aeson.String (mconcat (replicate 3000 "x")))))
    Pool.use pool (Session.statement () truncated) `shouldReturn` Right True
    -- A blocked diagnostic store is bounded per request and still permits
    -- asynchronous cancellation. The lock belongs to this isolated database.
    let diagnostic = captureRejections enabled metrics "single" (AccountId "ingest-service-account") now [(bad, original, [MissingRequiredProperty (EventName "page_view") "url"])]
        control sql = Connection.use connection (Session.script sql) >>= either (fail . show) pure
    bracket_ (control "BEGIN; LOCK TABLE kansoku.ingest_rejections IN ACCESS EXCLUSIVE MODE") (control "ROLLBACK") $ do
      beforeTimeout <- P.getCounter (metrics ^. #quarantineFailuresTotal)
      timeout 1_000_000 diagnostic `shouldReturn` Just ()
      P.getCounter (metrics ^. #quarantineFailuresTotal) `shouldReturn` (beforeTimeout + 1)
      interrupted <- async diagnostic
      threadDelay 20_000
      cancel interrupted
      waitCatch interrupted >>= (`shouldSatisfy` isLeft)
    -- Disabled capture does not touch a deliberately unavailable store.
    Pool.use pool (Session.script "ALTER TABLE kansoku.ingest_rejections RENAME TO held_rejections") `shouldReturn` Right ()
    failures <- P.getCounter (metrics ^. #quarantineFailuresTotal)
    disabledService <- newIngestService (enabled & #ingestQuarantine .~ False) metrics pool queue
    _ <- runHandler (postEvent (ingestServer disabledService) principal (ingestEvent bad))
    P.getCounter (metrics ^. #quarantineFailuresTotal) `shouldReturn` failures
    mixed <- runHandler (batch [bad, event "valid-during-quarantine-failure" "custom" now])
    case mixed of Right (KansokuOk ack) -> ack ^. #accepted `shouldBe` 1; other -> expectationFailure (show other)
    P.getCounter (metrics ^. #quarantineFailuresTotal) `shouldReturn` (failures + 1)
    Pool.use pool (Session.script "ALTER TABLE kansoku.held_rejections RENAME TO ingest_rejections") `shouldReturn` Right ()
    -- Queue failure cannot increment acceptance.
    beforeFailure <- counter (metrics ^. #ingestEventsTotal) ("accepted", "single")
    failingService <- newIngestService enabled metrics pool (eventsQueueName "missing_queue")
    failed <- runHandler (postEvent (ingestServer failingService) principal (ingestEvent (event "queue-fail" "custom" now)))
    case failed of Right (KansokuUnavailable _) -> pure (); other -> expectationFailure (show other)
    counter (metrics ^. #ingestEventsTotal) ("accepted", "single") `shouldReturn` beforeFailure
    -- Startup catches up expiry and the account cap automatically.
    Pool.use pool (Session.script "UPDATE kansoku.ingest_rejections SET received_at = now() - interval '30 days' WHERE transport = 'batch'") `shouldReturn` Right ()
    worker <- async (runQuarantineCleanup enabled metrics)
    cleanupResult <- timeout 2_000_000 (waitUntilCapped pool)
    cancel worker
    cleanupResult `shouldBe` Just ()
    countRows pool `shouldReturn` 2
    -- Cancellation must escape both background and timed database paths.
    waitCatch worker >>= (`shouldSatisfy` isLeft)
  it "bounds stalled database handshakes and closes the diagnostic socket" $ do
    cfg <- loadConfig >>= either (fail . show) pure
    bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
      Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.listen listener 1
      address <- Socket.getSocketName listener
      port <- case address of Socket.SockAddrInet value _ -> pure value; _ -> fail "expected IPv4 listener"
      connected <- newEmptyMVar
      withAsync (bracket (fst <$> Socket.accept listener) Socket.close (\peer -> putMVar connected peer >> threadDelay 5_000_000)) $ \_ -> do
        let diagnosticConfig =
              cfg
                & #ingestQuarantine
                .~ True
                & #pgConnectionString
                .~ ("host=127.0.0.1 port=" <> Text.pack (show port) <> " dbname=quarantine sslmode=disable")
        now <- getCurrentTime
        let bad = baseEvent (EventId "handshake") (EventName "page_view") Web now now
            payload = case Aeson.toJSON bad of Aeson.Object object -> object; _ -> mempty
        timeout 1_000_000 (captureRejections diagnosticConfig metrics "single" (AccountId "test") now [(bad, payload, [MissingRequiredProperty (EventName "page_view") "url"])]) `shouldReturn` Just ()
        peer <- takeMVar connected
        let drain = do chunk <- Socket.recv peer 8192; unless (BS.null chunk) drain
        timeout 500_000 drain `shouldReturn` Just ()
  where
    principal = IngestPrincipal (AuthenticatedPrincipal (ApiKeyId UUID.nil) WriteKey (AccountId "ingest-service-account"))
    event eid name now = baseEvent (EventId eid) (EventName name) Web now now
    queued = Statement.preparable "SELECT message FROM pgmq.q_ingest_service_spec ORDER BY msg_id LIMIT 1" E.noParams (D.singleRow (D.column (D.nonNullable D.jsonb)))
    preserved = Statement.preparable "SELECT EXISTS (SELECT 1 FROM kansoku.ingest_rejections WHERE payload->>'futureField' = 'retained')" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))
    truncated = Statement.preparable "SELECT EXISTS (SELECT 1 FROM kansoku.ingest_rejections WHERE payload_truncated AND payload = '{}'::jsonb AND original_payload_bytes > 2048)" E.noParams (D.singleRow (D.column (D.nonNullable D.bool)))

counter :: P.Vector (Text, Text) P.Counter -> (Text, Text) -> IO Double
counter vector labels = fromMaybe 0 . lookup labels <$> P.getVectorWith vector P.getCounter

countRows :: Pool.Pool -> IO Integer
countRows pool = do
  result <- Pool.use pool (Session.statement () (Statement.preparable "SELECT count(*) FROM kansoku.ingest_rejections" E.noParams (D.singleRow (D.column (D.nonNullable D.int8)))))
  fromIntegral <$> either (fail . show) pure result

waitUntilCapped :: Pool.Pool -> IO ()
waitUntilCapped pool = do
  count <- countRows pool
  unless (count <= 2) (threadDelay 10_000 >> waitUntilCapped pool)
