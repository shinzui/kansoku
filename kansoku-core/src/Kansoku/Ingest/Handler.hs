{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( batchLengthError,
    ingestServer,
    partitionBatch,
    stampAuthenticatedEvent,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Kansoku.Api.Response
  ( KansokuResult (..),
    badRequest,
  )
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (IngestPrincipal (..))
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    ValidationError (..),
    renderValidationError,
    validateEvent,
  )
import Kansoku.Ingest.Acceptance (Acceptance (..))
import Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestEvent (..),
    IngestRoutes (..),
    RejectedEvent (..),
  )
import Kansoku.Ingest.Service (IngestService, batchLengthError, stampAuthenticatedEvent)
import Kansoku.Ingest.Service qualified as Service
import Kansoku.Prelude
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

ingestServer :: IngestService -> IngestRoutes (AsServerT Handler)
ingestServer service =
  IngestRoutes
    { postEvent = \(IngestPrincipal principal request) raw -> do
        result <- Service.submitIngest service Service.Single principal request [raw]
        pure $ case result of
          KansokuOk [Rejected errs] -> validationFailure errs
          _ -> (\_ -> IngestAck {accepted = 1, eventId = unEventId (parsedEvent raw ^. #eventId)}) <$> result,
      postBatch = \(IngestPrincipal principal request) raw -> do
        result <- Service.submitIngest service Service.Batch principal request raw
        pure $
          ( \outcomes ->
              BatchAck
                { accepted = length [() | outcome <- outcomes, case outcome of Rejected _ -> False; _ -> True],
                  rejected = [rejection i (parsedEvent input) errs | (i, input, Rejected errs) <- zip3 [0 ..] raw outcomes]
                }
          )
            <$> result
    }

rejection :: Int -> AnalyticsEvent -> [ValidationError] -> RejectedEvent
rejection eventIndex event errs =
  RejectedEvent
    { index = eventIndex,
      eventId = let value = unEventId (event ^. #eventId) in if Text.null value then Nothing else Just value,
      errors = renderValidationError <$> errs
    }

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
