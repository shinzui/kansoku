-- | Batch handler that writes decoded pgmq messages into ClickHouse.
module Kansoku.Writer.Batch
  ( writerBatchHandler,
  )
where

import ClickHaskell (Connection)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (IOE, type (:>))
import GHC.Clock (getMonotonicTime)
import Kansoku.ClickHouse (insertEvents)
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.Queue (decodeEvent)
import Kansoku.Observability
  ( PipelineMetrics,
    WriterHeartbeat,
    beatWriter,
  )
import Kansoku.Prelude
import Prometheus qualified
import Shibuya.Batch
  ( BatchHandler,
    ackExcept,
    withFallback,
  )
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..), MessageId)

writerBatchHandler ::
  (IOE :> es) =>
  PipelineMetrics ->
  WriterHeartbeat ->
  Connection ->
  BatchHandler es Value
writerBatchHandler metrics heartbeat conn _info messages = do
  let decoded = decodeMessage <$> toList messages
      bad = [(messageId, AckDeadLetter reason) | Left (messageId, reason) <- decoded]
      good = [event | Right event <- decoded]
  liftIO $ do
    Prometheus.incCounter (metrics ^. #writerBatchesTotal)
    unless (null bad) $
      void $
        Prometheus.addCounter
          (metrics ^. #writerDeadLettersTotal)
          (fromIntegral (length bad))
  if null good
    then do
      liftIO (beatWriter heartbeat)
      pure (ackExcept bad)
    else do
      result <- liftIO $ do
        startedAt <- getMonotonicTime
        inserted <- try (insertEvents conn good)
        finishedAt <- getMonotonicTime
        Prometheus.observe
          (metrics ^. #writerBatchFlushSeconds)
          (finishedAt - startedAt)
        pure inserted
      case result of
        Right () -> do
          liftIO $ do
            void $
              Prometheus.addCounter
                (metrics ^. #writerEventsWrittenTotal)
                (fromIntegral (length good))
            beatWriter heartbeat
          pure (ackExcept bad)
        Left (err :: SomeException) -> do
          liftIO $ Prometheus.incCounter (metrics ^. #writerInsertFailuresTotal)
          pure
            ( withFallback
                (AckRetry (RetryDelay 5))
                (annotateInsertFailure err bad)
            )

decodeMessage :: Message es Value -> Either (MessageId, DeadLetterReason) AnalyticsEvent
decodeMessage Message {envelope = Envelope {messageId, payload}} =
  case decodeEvent payload of
    Just event -> Right event
    Nothing ->
      Left
        ( messageId,
          InvalidPayload "could not decode AnalyticsEvent from pgmq message body"
        )

annotateInsertFailure ::
  SomeException ->
  [(MessageId, AckDecision)] ->
  [(MessageId, AckDecision)]
annotateInsertFailure err =
  fmap $ \(messageId, decision) ->
    case decision of
      AckDeadLetter (InvalidPayload reason) ->
        (messageId, AckDeadLetter (InvalidPayload (reason <> "; insert failed: " <> errText)))
      other ->
        (messageId, other)
  where
    errText = Text.pack (displayException err)
