{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( ingestServer,
  )
where

import Data.Aeson qualified as Aeson
import Data.Either (partitionEithers)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, type (:>))
import Effectful.Error.Static qualified as Error
import Hasql.Pool qualified as Pool
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    ValidationError,
    validateEvent,
  )
import Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
  )
import Kansoku.Ingest.Producer (enqueueMany, enqueueOne)
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Prelude
import Pgmq.Effectful (Pgmq, QueueName, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Servant
  ( Handler,
    ServerError (..),
    err400,
    err503,
    throwError,
  )
import Servant.Server.Generic (AsServerT)

type HandlerEff =
  '[ Error.Error [ValidationError],
     Pgmq,
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
    postEventHandler :: AnalyticsEvent -> Handler IngestAck
    postEventHandler raw = effToHandler pool $ do
      now <- liftIO getCurrentTime
      event <- validateOrThrow (raw & #receivedAt .~ now)
      _ <- enqueueOne queueName event
      pure
        IngestAck
          { accepted = 1,
            eventId = unEventId (event ^. #eventId)
          }

    postBatchHandler :: [AnalyticsEvent] -> Handler BatchAck
    postBatchHandler raw = effToHandler pool $ do
      now <- liftIO getCurrentTime
      events <- validateBatchOrThrow ((& #receivedAt .~ now) <$> raw)
      _ <- enqueueMany queueName events
      pure BatchAck {accepted = length events}

validateOrThrow ::
  (Error.Error [ValidationError] :> es) =>
  AnalyticsEvent ->
  Eff es AnalyticsEvent
validateOrThrow event =
  case validateEvent event of
    Right ok -> pure ok
    Left errs -> Error.throwError errs

validateBatchOrThrow ::
  (Error.Error [ValidationError] :> es) =>
  [AnalyticsEvent] ->
  Eff es [AnalyticsEvent]
validateBatchOrThrow events =
  case partitionEithers (validateEvent <$> events) of
    ([], ok) -> pure ok
    (errs, _) -> Error.throwError (concat errs)

effToHandler :: Pool.Pool -> Eff HandlerEff a -> Handler a
effToHandler pool action = do
  result <-
    liftIO $
      runEff $
        Error.runErrorNoCallStack @PgmqRuntimeError $
          runPgmq pool $
            Error.runErrorNoCallStack @[ValidationError] action
  case result of
    Left pgErr -> do
      liftIO . runEff . runLogStderr $
        logError ("ingest enqueue failed: " <> Text.pack (show pgErr))
      throwError (jsonError err503 "queue unavailable" [])
    Right (Left validationErrs) ->
      throwError (jsonError err400 "validation failed" (validationErrorText <$> validationErrs))
    Right (Right value) ->
      pure value

jsonError :: ServerError -> Text -> [Text] -> ServerError
jsonError err message details =
  err
    { errBody =
        Aeson.encode
          ( Aeson.object
              [ "error" Aeson..= message,
                "details" Aeson..= details
              ]
          ),
      errHeaders = [("content-type", "application/json")]
    }

validationErrorText :: ValidationError -> Text
validationErrorText = Text.pack . show
