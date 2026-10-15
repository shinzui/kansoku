{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( batchLengthError,
    ingestServer,
    partitionBatch,
    stampAuthenticatedEvent,
  )
where

import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.List (nub)
import Data.Text qualified as Text
import Effectful (runEff)
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
    ValidationError (..),
    renderValidationError,
    validateEvent,
    validationReason,
  )
import Kansoku.Ingest.Acceptance (Acceptance (..), acceptBatch)
import Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestEvent (..),
    IngestRoutes (..),
    RejectedEvent (..),
  )
import Kansoku.Ingest.Quarantine (captureRejections)
import Kansoku.Ingest.Timestamp
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude
import Pgmq.Types (QueueName)
import Prometheus qualified as P
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

ingestServer :: Config -> PipelineMetrics -> Pool.Pool -> QueueName -> IngestRoutes (AsServerT Handler)
ingestServer cfg metrics pool queueName =
  IngestRoutes
    { postEvent = \(IngestPrincipal principal) raw -> do
        result <- submit "single" principal [raw]
        pure $ case result of
          KansokuOk [Rejected errs] -> validationFailure errs
          _ -> (\_ -> IngestAck {accepted = 1, eventId = unEventId (parsedEvent raw ^. #eventId)}) <$> result,
      postBatch = \(IngestPrincipal principal) raw ->
        case batchLengthError (cfg ^. #ingestMaxBatchLength) (length raw) of
          Just err -> pure (KansokuTooLarge err)
          Nothing -> do
            result <- submit "batch" principal raw
            pure $
              ( \outcomes ->
                  BatchAck
                    { accepted = length [() | outcome <- outcomes, case outcome of Rejected _ -> False; _ -> True],
                      rejected = [rejection i (parsedEvent input) errs | (i, input, Rejected errs) <- zip3 [0 ..] raw outcomes]
                    }
              )
                <$> result
    }
  where
    submit transport principal raw = do
      now <- liftIO getCurrentTime
      let validate input =
            let (adjusted, adjustment) = normalizeOccurredAt (fromIntegral (cfg ^. #ingestFutureToleranceSec)) now (stampAuthenticatedEvent now principal (parsedEvent input))
             in (\event -> (event, adjustment)) <$> validateEvent adjusted
      result <- liftIO $ acceptBatch pool queueName (principal ^. #accountId) validate raw
      case result of
        Left _ -> do
          liftIO . runEff . runLogStderr $ logError "ingest enqueue failed"
          pure (KansokuUnavailable (unavailable "queue_unavailable" "analytics queue is unavailable"))
        Right outcomes -> do
          liftIO $ forM_ outcomes $ \case
            NewEvent _ adjustment -> do
              accepted transport
              forM_ adjustment $ \kind ->
                P.withLabel
                  (metrics ^. #ingestTimestampAdjustmentsTotal)
                  (case kind of SkewCorrected -> "skew_corrected"; Clamped -> "clamped", transport)
                  P.incCounter
            Replay -> accepted transport
            Rejected errs -> do
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
              [(parsedEvent input, originalPayload input, errs) | (input, Rejected errs) <- zip raw outcomes]
          pure (KansokuOk outcomes)
    accepted transport = P.withLabel (metrics ^. #ingestEventsTotal) ("accepted", transport) P.incCounter

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

validationFailure :: [ValidationError] -> KansokuResult a
validationFailure validationErrs =
  KansokuBadRequest
    ( badRequest
        (if EventIdConflict `elem` validationErrs then "event_id_conflict" else "validation_failed")
        ("validation failed: " <> Text.intercalate "; " (renderValidationError <$> validationErrs))
    )
