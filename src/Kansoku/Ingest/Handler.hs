{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for HTTP ingestion.
module Kansoku.Ingest.Handler
  ( ingestApp,
    ingestServer,
  )
where

import Data.Aeson qualified as Aeson
import Data.Either (partitionEithers)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, type (:>))
import Effectful.Error.Static qualified as Error
import Hasql.Pool qualified as Pool
import Kansoku.Api.Ingest
  ( BatchAck (..),
    IngestAPI,
    IngestAck (..),
  )
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    ValidationError,
    validateEvent,
  )
import Kansoku.Ingest.Producer (enqueueMany, enqueueOne)
import Kansoku.Prelude
import Network.Wai (Application)
import Pgmq.Effectful (Pgmq, QueueName, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Servant
  ( Handler,
    Server,
    ServerError (..),
    err400,
    err503,
    serve,
    throwError,
    type (:<|>) (..),
  )

type HandlerEff =
  '[ Error.Error [ValidationError],
     Pgmq,
     Error.Error PgmqRuntimeError,
     IOE
   ]

ingestApp :: Pool.Pool -> QueueName -> Application
ingestApp pool queueName =
  serve (Proxy @IngestAPI) (ingestServer pool queueName)

ingestServer :: Pool.Pool -> QueueName -> Server IngestAPI
ingestServer pool queueName =
  postEvent :<|> postBatch
  where
    postEvent :: AnalyticsEvent -> Handler IngestAck
    postEvent raw = effToHandler pool $ do
      now <- liftIO getCurrentTime
      event <- validateOrThrow (raw & #receivedAt .~ now)
      _ <- enqueueOne queueName event
      pure
        IngestAck
          { accepted = 1,
            eventId = unEventId (event ^. #eventId)
          }

    postBatch :: [AnalyticsEvent] -> Handler BatchAck
    postBatch raw = effToHandler pool $ do
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
    Left pgErr ->
      throwError (jsonError err503 "queue unavailable" [Text.pack (show pgErr)])
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
