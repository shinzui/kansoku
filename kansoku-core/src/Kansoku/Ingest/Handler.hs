{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( ingestServer,
    partitionBatch,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static qualified as Error
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
  ( KansokuResult (..),
    badRequest,
    unavailable,
  )
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    ValidationError,
    renderValidationError,
    validateEvent,
  )
import Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
    RejectedEvent (..),
  )
import Kansoku.Ingest.Producer (enqueueMany, enqueueOne)
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Prelude
import Pgmq.Effectful (Pgmq, QueueName, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

type HandlerEff =
  '[ Pgmq,
     Error.Error PgmqRuntimeError,
     IOE
   ]

ingestServer :: Pool.Pool -> QueueName -> IngestRoutes (AsServerT Handler)
ingestServer pool queueName =
  IngestRoutes
    { postEvent = postEventHandler,
      postBatch = postBatchHandler
    }
  where
    postEventHandler :: AnalyticsEvent -> Handler (KansokuResult IngestAck)
    postEventHandler raw = do
      now <- liftIO getCurrentTime
      case validateEvent (raw & #receivedAt .~ now) of
        Left errs -> pure (validationFailure errs)
        Right event ->
          effToHandler pool $ do
            _ <- enqueueOne queueName event
            pure
              IngestAck
                { accepted = 1,
                  eventId = unEventId (event ^. #eventId)
                }

    postBatchHandler :: [AnalyticsEvent] -> Handler (KansokuResult BatchAck)
    postBatchHandler raw = do
      now <- liftIO getCurrentTime
      let (events, rejectedEvents) = partitionBatch ((& #receivedAt .~ now) <$> raw)
      effToHandler pool $ do
        _ <- enqueueMany queueName events
        pure BatchAck {accepted = length events, rejected = rejectedEvents}

-- | Partition a received-at-stamped batch while preserving submission order.
-- Rejection indices refer to the original zero-based positions.
partitionBatch :: [AnalyticsEvent] -> ([AnalyticsEvent], [RejectedEvent])
partitionBatch events =
  foldr verdict ([], []) (zip [0 ..] events)
  where
    verdict (eventIndex, event) (acceptedEvents, rejectedEvents) =
      case validateEvent event of
        Right acceptedEvent -> (acceptedEvent : acceptedEvents, rejectedEvents)
        Left validationErrs ->
          ( acceptedEvents,
            RejectedEvent
              { index = eventIndex,
                eventId =
                  let rawEventId = unEventId (event ^. #eventId)
                   in if Text.null rawEventId then Nothing else Just rawEventId,
                errors = renderValidationError <$> validationErrs
              }
              : rejectedEvents
          )

effToHandler :: Pool.Pool -> Eff HandlerEff a -> Handler (KansokuResult a)
effToHandler pool action = do
  result <-
    liftIO $
      runEff $
        Error.runErrorNoCallStack @PgmqRuntimeError $
          runPgmq pool action
  case result of
    Left pgErr -> do
      liftIO . runEff . runLogStderr $
        logError ("ingest enqueue failed: " <> Text.pack (show pgErr))
      pure (KansokuUnavailable (unavailable "queue_unavailable" "analytics queue is unavailable"))
    Right value ->
      pure (KansokuOk value)

validationFailure :: [ValidationError] -> KansokuResult a
validationFailure validationErrs =
  KansokuBadRequest
    ( badRequest
        "validation_failed"
        ("validation failed: " <> Text.intercalate "; " (renderValidationError <$> validationErrs))
    )
