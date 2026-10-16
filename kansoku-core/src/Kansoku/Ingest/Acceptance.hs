-- | Immutable logical event identity and queue publication on one connection.
module Kansoku.Ingest.Acceptance
  ( Acceptance (..),
    acceptBatch,
    acceptQueuedBatch,
    producerPayloadHash,
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.RFC8785 (encodeCanonical)
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as T
import Hasql.Transaction.Sessions qualified as T
import Kansoku.Event (AccountId (..), AnalyticsEvent, EventId (..), ValidationError (..))
import Kansoku.Ingest.Api (IngestEvent (..))
import Kansoku.Ingest.Queue (encodeQueuedEvent)
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Ingest.Timestamp (TimestampAdjustment)
import Kansoku.Prelude
import Pgmq.Hasql.Statements.Message qualified as Pgmq
import Pgmq.Hasql.Statements.Types (SendMessage (..))
import Pgmq.Types (QueueName)

data Acceptance
  = NewEvent !AnalyticsEvent !(Maybe TimestampAdjustment)
  | Replay
  | Rejected ![ValidationError]
  deriving stock (Eq, Show)

-- | Preserve producer content, including unknown fields. Authentication and
-- delivery clocks are not content. RFC8785 orders nested objects and normalizes
-- numeric representations without converting Scientific values to Double.
producerPayloadHash :: IngestEvent -> Text
producerPayloadHash input =
  Text.pack (show (hashlazy (encodeCanonical stable) :: Digest SHA256))
  where
    stable = Object (foldr KM.delete (originalPayload input) ["accountId", "receivedAt", "sentAt"])

-- | Validation/normalization is lazy: equal retries never evaluate it. A failed
-- queue send rolls back the claim, including every earlier event in this batch.
-- Stable lock order avoids opposing batches deadlocking on their unique keys.
acceptBatch ::
  Pool.Pool ->
  QueueName ->
  AccountId ->
  (IngestEvent -> Either [ValidationError] (AnalyticsEvent, Maybe TimestampAdjustment)) ->
  [IngestEvent] ->
  IO (Either Pool.UsageError [Acceptance])
acceptBatch pool queue account validate =
  acceptQueuedBatch pool queue account (fmap (\(event, adjustment) -> (enrichedQueuedEvent emptyRequestContext event, adjustment)) . validate)

acceptQueuedBatch ::
  Pool.Pool ->
  QueueName ->
  AccountId ->
  (IngestEvent -> Either [ValidationError] (QueuedEvent, Maybe TimestampAdjustment)) ->
  [IngestEvent] ->
  IO (Either Pool.UsageError [Acceptance])
acceptQueuedBatch _ _ _ _ [] = pure (Right [])
acceptQueuedBatch pool queue account validate inputs =
  fmap (fmap (fmap snd . sortOn fst)) $
    Pool.use pool $
      T.transaction T.ReadCommitted T.Write $ do
        void (T.statement () trafficLock)
        traverse accept (sortOn (identity . snd) (zip [0 :: Int ..] inputs))
  where
    identity input = (unAccountId account, unEventId (parsedEvent input ^. #eventId))
    accept (eventIndex, input) = do
      let key = identity input
          digest = producerPayloadHash input
          replay stored = if stored == digest then Replay else Rejected [EventIdConflict]
      existing <- T.statement key lookupHash
      result <- case existing of
        Just stored -> pure (replay stored)
        Nothing -> case validate input of
          Left errors -> pure (Rejected errors)
          Right (candidate, adjustment) -> do
            let event = candidate ^. #event & #accountId ?~ account & #eventId .~ (parsedEvent input ^. #eventId)
                queued = candidate & #event .~ event
            claimed <- T.statement (fst key, snd key, digest) claimIdentity
            case claimed of
              Just _ -> do
                void $ T.statement (SendMessage queue (encodeQueuedEvent queued) Nothing) Pgmq.sendMessage
                pure (NewEvent event adjustment)
              Nothing -> do
                -- ON CONFLICT waits for a concurrent creator. ReadCommitted's
                -- next statement sees its committed hash. Ledger rows never
                -- expire, including erasure tombstones.
                stored <- T.statement key lookupHash
                pure (maybe (Rejected [EventIdConflict]) replay stored)
      pure (eventIndex, result)

trafficLock :: Statement.Statement () Bool
trafficLock =
  Statement.preparable
    "SELECT kansoku.require_traffic_lock() IS NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

lookupHash :: Statement.Statement (Text, Text) (Maybe Text)
lookupHash =
  Statement.preparable
    "SELECT producer_payload_hash FROM kansoku.accepted_events WHERE account_id = $1 AND event_id = $2 UNION ALL SELECT '' FROM kansoku.event_dispositions WHERE account_id=$1 AND event_id=$2 AND NOT EXISTS (SELECT 1 FROM kansoku.accepted_events WHERE account_id=$1 AND event_id=$2) LIMIT 1"
    ((fst >$< textParam) <> (snd >$< textParam))
    (D.rowMaybe (D.column (D.nonNullable D.text)))

claimIdentity :: Statement.Statement (Text, Text, Text) (Maybe Text)
claimIdentity =
  Statement.preparable
    """
    INSERT INTO kansoku.accepted_events (account_id, event_id, producer_payload_hash)
    VALUES ($1, $2, $3)
    ON CONFLICT (account_id, event_id) DO NOTHING
    RETURNING event_id
    """
    ( ((\(account, _, _) -> account) >$< textParam)
        <> ((\(_, event, _) -> event) >$< textParam)
        <> ((\(_, _, digest) -> digest) >$< textParam)
    )
    (D.rowMaybe (D.column (D.nonNullable D.text)))

textParam :: E.Params Text
textParam = E.param (E.nonNullable E.text)
