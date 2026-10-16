module Kansoku.Ingest.AcceptanceSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.UUID qualified as UUID
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as S
import Hasql.Statement qualified as Statement
import Kansoku.Api.Response
import Kansoku.Auth.Types
import Kansoku.Config (loadConfig)
import Kansoku.Event
import Kansoku.Ingest.Acceptance
import Kansoku.Ingest.Api
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Ingest.Service (newIngestService)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Postgres (createPool)
import Kansoku.PostgresTestSupport (withCommitFault, withMigratedPool, withMigratedStore)
import Kansoku.Prelude
import Pgmq qualified
import Servant (runHandler)
import System.IO (hGetLine)
import System.Timeout (timeout)
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Ingest.Acceptance" $ do
  it "rejects incompatible JSON before claiming an ID and accepts corrected content" $ withMigratedPool $ \pool -> do
    provision pool
    let object = KM.fromList [("a.b", Aeson.Number 1), ("a", Aeson.object ["b" Aeson..= (2 :: Int)])]
        bad = sample & #properties .~ object
    accept pool [raw bad] `shouldReturn` [Rejected [IncompatibleJsonPaths "properties"]]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 0
    count pool "kansoku.accepted_events" `shouldReturn` 0
    accept pool [raw sample] `shouldReturn` [NewEvent sample Nothing]
    acceptBatch pool queue account (error "equal retry must not revalidate") [raw sample] `shouldReturn` Right [Replay]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1
    count pool "kansoku.accepted_events" `shouldReturn` 1

  it "returns permanent single rejection and indexed mixed batch JSON rejection" $ withMigratedPool $ \pool -> do
    provision pool
    cfg <- loadConfig >>= either (fail . show) pure
    service <- newIngestService cfg metrics pool queue
    let routes = ingestServer service
        principal = IngestPrincipal (AuthenticatedPrincipal (ApiKeyId UUID.nil) WriteKey account) emptyRequestContext
        object = KM.fromList [("a.b", Aeson.Number 1), ("a", Aeson.object ["b" Aeson..= (2 :: Int)])]
        bad = raw (sample & #context .~ object)
        good = raw (sample & #eventId .~ EventId "valid-sibling")
    result <- runHandler (postEvent routes principal bad)
    case result of
      Right (KansokuBadRequest details) -> details ^. #code `shouldBe` "validation_failed"
      other -> expectationFailure (show other)
    batch <- runHandler (postBatch routes principal [bad, good])
    case batch of
      Right (KansokuOk ack) -> do
        ack ^. #accepted `shouldBe` 1
        fmap (view #index) (ack ^. #rejected) `shouldBe` [0]
      other -> expectationFailure (show other)
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1
    count pool "kansoku.accepted_events" `shouldReturn` 1

  it "canonicalizes nested ordering and numbers while excluding delivery clocks/account" $ do
    let first = raw sample
        other = first {originalPayload = KM.insert "sentAt" (Aeson.String "new clock") (KM.insert "accountId" (Aeson.String "ignored") (originalPayload first))}
        object json = case Aeson.eitherDecode json of Right (Aeson.Object value) -> value; _ -> error "invalid test JSON"
        a = first {originalPayload = object "{\"properties\":{\"b\":1.00,\"a\":{\"x\":2,\"y\":3}}}"}
        b = first {originalPayload = object "{\"properties\":{\"a\":{\"y\":3,\"x\":2.0},\"b\":1}}"}
    producerPayloadHash first `shouldBe` producerPayloadHash other
    producerPayloadHash a `shouldBe` producerPayloadHash b
    producerPayloadHash first `shouldNotBe` producerPayloadHash a

  it "acknowledges immutable retries without reevaluating normalization and retains tombstones" $ withMigratedPool $ \pool -> do
    provision pool
    accepted <- accept pool [raw sample]
    accepted `shouldBe` [NewEvent sample Nothing]
    acceptBatch pool queue account (error "retry must not normalize again") [raw sample] `shouldReturn` Right [Replay]
    command pool "UPDATE kansoku.accepted_events SET erased_at = now(); DELETE FROM pgmq.q_acceptance_spec"
    acceptBatch pool queue account (error "erased retry must not enqueue") [raw sample] `shouldReturn` Right [Replay]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 0
    count pool "kansoku.accepted_events" `shouldReturn` 1

  it "converges concurrent duplicates and opposing batch orders without duplicate publication" $ withMigratedPool $ \pool -> do
    provision pool
    let second = sample & #eventId .~ EventId "second"
        inputs = take 24 (cycle [[raw sample, raw second], [raw second, raw sample]])
    results <- mapConcurrently (accept pool) inputs
    length [() | NewEvent _ _ <- concat results] `shouldBe` 2
    length [() | Replay <- concat results] `shouldBe` 46
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 2
    count pool "kansoku.accepted_events" `shouldReturn` 2

  it "rejects changed producer content under the same ID and scopes identity by account" $ withMigratedPool $ \pool -> do
    provision pool
    let original = raw sample
        changed = original {originalPayload = KM.insert "unknownProducerField" (Aeson.String "changed") (originalPayload original)}
    accept pool [original, original, changed] `shouldReturn` [NewEvent sample Nothing, Replay, Rejected [EventIdConflict]]
    acceptBatch pool queue (AccountId "other-account") validate [changed] `shouldReturn` Right [NewEvent (sample & #accountId ?~ AccountId "other-account") Nothing]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 2

  it "rolls back ledger claims when queue publication fails and accepts the later retry" $ withMigratedPool $ \pool -> do
    provision pool
    result <- acceptBatch pool (eventsQueueName "absent_acceptance_queue") account validate [raw sample]
    result `shouldSatisfy` isLeft
    count pool "kansoku.accepted_events" `shouldReturn` 0
    accept pool [raw sample] `shouldReturn` [NewEvent sample Nothing]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1

  it "acknowledges a retry after acceptance committed but its confirmation was discarded" $ withMigratedStore $ \settings _ pool -> do
    provision pool
    withCommitFault settings $ \proxiedSettings output ->
      bracket (createPool proxiedSettings) Pool.release $ \proxied -> do
        first <- acceptBatch proxied queue account validate [raw sample]
        first `shouldSatisfy` isLeft
        timeout 1_000_000 (hGetLine output) `shouldReturn` Just "dropped-commit"
    acceptBatch pool queue account (error "ambiguous commit retry must reuse the first normalization") [raw sample] `shouldReturn` Right [Replay]
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1
    count pool "kansoku.accepted_events" `shouldReturn` 1

  it "elects one immutable payload when conflicting submissions race" $ withMigratedPool $ \pool -> do
    provision pool
    results <- mapConcurrently (accept pool . pure . raw) [sample, sample & #eventName .~ EventName "racing-content"]
    length [() | NewEvent _ _ <- concat results] `shouldBe` 1
    length [() | Rejected [EventIdConflict] <- concat results] `shouldBe` 1
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1

  it "returns a single 400 conflict and batch per-event conflict with original indices" $ withMigratedPool $ \pool -> do
    provision pool
    cfg <- loadConfig >>= either (fail . show) pure
    service <- newIngestService cfg metrics pool queue
    let routes = ingestServer service
        principal = IngestPrincipal (AuthenticatedPrincipal (ApiKeyId UUID.nil) WriteKey account) emptyRequestContext
        original = raw sample
        changed = raw (sample & #eventName .~ EventName "changed")
    runHandler (postEvent routes principal original) `shouldReturn` Right (KansokuOk (IngestAck 1 "accepted-event"))
    result <- runHandler (postEvent routes principal changed)
    case result of
      Right (KansokuBadRequest details) -> details ^. #code `shouldBe` "event_id_conflict"
      other -> expectationFailure (show other)
    batch <- runHandler (postBatch routes principal [original, changed, original])
    case batch of
      Right (KansokuOk ack) -> do
        ack ^. #accepted `shouldBe` 2
        fmap (view #index) (ack ^. #rejected) `shouldBe` [1]
      other -> expectationFailure (show other)
    count pool "pgmq.q_acceptance_spec" `shouldReturn` 1

queue :: Pgmq.QueueName
queue = eventsQueueName "acceptance_spec"

account :: AccountId
account = AccountId "acceptance-account"

sample :: AnalyticsEvent
sample = (baseEvent (EventId "accepted-event") (EventName "custom") Web (read "2026-07-01 12:00:00 UTC") (read "2026-07-01 12:00:01 UTC")) & #accountId ?~ account

raw :: AnalyticsEvent -> IngestEvent
raw event = IngestEvent event (case Aeson.toJSON event of Aeson.Object object -> object; _ -> error "event is not an object")

validate :: IngestEvent -> Either [ValidationError] (AnalyticsEvent, Maybe a)
validate input = (\event -> (event, Nothing)) <$> validateEvent (parsedEvent input)

accept :: Pool.Pool -> [IngestEvent] -> IO [Acceptance]
accept pool inputs = acceptBatch pool queue account validate inputs >>= either (fail . show) pure

provision :: Pool.Pool -> IO ()
provision pool = Pool.use pool (Pgmq.createQueue queue) >>= either (fail . show) pure

command :: Pool.Pool -> Text -> IO ()
command pool sql = Pool.use pool (S.script sql) >>= either (fail . show) pure

count :: Pool.Pool -> Text -> IO Integer
count pool table = fromIntegral <$> (Pool.use pool (S.statement () (Statement.preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))) >>= either (fail . show) pure)
