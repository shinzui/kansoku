{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( batchLengthError,
    ingestServer,
    partitionBatch,
    stampAuthenticatedEvent,
  )
where

import Control.Monad (replicateM_)
import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static qualified as Error
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
  ( KansokuResult (..),
    ProblemDetails,
    badRequest,
    tooLarge,
    unavailable,
  )
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (AuthenticatedPrincipal, IngestPrincipal (..))
import Kansoku.Config (Config)
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    ValidationError,
    renderValidationError,
    validateEvent,
    validationReason,
  )
import Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestEvent (..),
    IngestRoutes (..),
    RejectedEvent (..),
  )
import Kansoku.Ingest.Producer (enqueueMany)
import Kansoku.Ingest.Quarantine (captureRejections)
import Kansoku.Ingest.Timestamp
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude
import Pgmq.Effectful (Pgmq, QueueName, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Prometheus qualified as P
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

type HandlerEff =
  '[ Pgmq,
     Error.Error PgmqRuntimeError,
     IOE
   ]

ingestServer :: Config -> PipelineMetrics -> Pool.Pool -> QueueName -> IngestRoutes (AsServerT Handler)
ingestServer cfg metrics pool queueName =
  IngestRoutes
    { postEvent = \(IngestPrincipal principal) raw -> do
        (events, rejectedEvents) <- prepare "single" principal [raw]
        case rejectedEvents of
          (_, errs) : _ -> pure (validationFailure errs)
          [] -> do
            result <- enqueue "single" events
            pure (fmap (\_ -> IngestAck {accepted = 1, eventId = unEventId (parsedEvent raw ^. #eventId)}) result),
      postBatch = \(IngestPrincipal principal) raw ->
        case batchLengthError (cfg ^. #ingestMaxBatchLength) (length raw) of
          Just err -> pure (KansokuTooLarge err)
          Nothing -> do
            (events, rejectedEvents) <- prepare "batch" principal raw
            result <- enqueue "batch" events
            pure (fmap (\_ -> BatchAck {accepted = length events, rejected = [rejection eventIndex event errs | ((eventIndex, event), errs) <- rejectedEvents]}) result)
    }
  where
    prepare transport principal raw = do
      now <- liftIO getCurrentTime
      let checked =
            [ (i, original, originalPayload input, adjusted, adjustment, validateEvent adjusted)
            | (i, input) <- zip [0 ..] raw,
              let original = parsedEvent input,
              let (adjusted, adjustment) = normalizeOccurredAt (fromIntegral (cfg ^. #ingestFutureToleranceSec)) now (stampAuthenticatedEvent now principal original)
            ]
      liftIO $ forM_ checked $ \(_, _, _, _, adjustment, verdict) -> do
        forM_ adjustment $ \kind ->
          P.withLabel
            (metrics ^. #ingestTimestampAdjustmentsTotal)
            (case kind of SkewCorrected -> "skew_corrected"; Clamped -> "clamped", transport)
            P.incCounter
        case verdict of
          Right _ -> pure ()
          Left errs -> do
            P.withLabel (metrics ^. #ingestEventsTotal) ("rejected", transport) P.incCounter
            forM_ (nub (validationReason <$> errs)) $ \reason ->
              P.withLabel (metrics ^. #ingestRejectionsTotal) (reason, transport) P.incCounter
      liftIO $
        captureRejections
          cfg
          metrics
          transport
          (principal ^. #accountId)
          now
          [(original, originalObject, errs) | (_, original, originalObject, _, _, Left errs) <- checked]
      pure ([event | (_, _, _, _, _, Right event) <- checked], [((i, original), errs) | (i, original, _, _, _, Left errs) <- checked])

    enqueue transport events = do
      result <- effToHandler pool (enqueueMany queueName events)
      case result of
        KansokuOk _ ->
          liftIO $
            replicateM_ (length events) $
              P.withLabel (metrics ^. #ingestEventsTotal) ("accepted", transport) P.incCounter
        _ -> pure ()
      pure result

rejection :: Int -> AnalyticsEvent -> [ValidationError] -> RejectedEvent
rejection eventIndex event errs =
  RejectedEvent
    { index = eventIndex,
      eventId = let value = unEventId (event ^. #eventId) in if Text.null value then Nothing else Just value,
      errors = renderValidationError <$> errs
    }

-- | Make the authenticated account authoritative before validation or queueing.
stampAuthenticatedEvent :: UTCTime -> AuthenticatedPrincipal -> AnalyticsEvent -> AnalyticsEvent
stampAuthenticatedEvent receivedAt principal event =
  event
    & #receivedAt
    .~ receivedAt
    & #accountId
    ?~ (principal ^. #accountId)

-- | Build the non-retryable 413 envelope for an overlong batch.
batchLengthError :: Int -> Int -> Maybe ProblemDetails
batchLengthError maxBatchLength actualLength
  | actualLength > maxBatchLength =
      Just
        ( tooLarge
            "batch_too_large"
            ( "batch of "
                <> Text.pack (show actualLength)
                <> " events exceeds the limit of "
                <> Text.pack (show maxBatchLength)
            )
        )
  | otherwise = Nothing

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
    Left _ -> do
      liftIO . runEff . runLogStderr $
        logError "ingest enqueue failed"
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
