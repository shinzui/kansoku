-- | Bounded, opt-in diagnostic storage independent of queue transactions.
module Kansoku.Ingest.Quarantine
  ( captureRejections,
    cleanupQuarantine,
    runQuarantineCleanup,
    boundedPayload,
  )
where

import Control.Concurrent (threadDelay, threadWaitRead, threadWaitWrite)
import Control.Exception (bracket)
import Data.Aeson (Object, Value (Object))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.List (nub)
import Data.Text.Encoding qualified as Text
import Data.Time (diffUTCTime)
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Config (Config)
import Kansoku.Event
import Kansoku.Exception (trySynchronous)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude
import Prometheus qualified as P
import System.Timeout (timeout)

-- | Oversized objects are replaced, never cut through JSON or UTF-8. Byte
-- length and truncation are separate metadata. Configuration requires at least
-- two bytes so the replacement empty object fits.
boundedPayload :: Int -> Object -> (Aeson.Value, Bool, Int64)
boundedPayload limit event =
  let value = Object event
      bytes = LBS.length (Aeson.encode value)
   in if bytes > fromIntegral limit
        then (Aeson.object [], True, bytes)
        else (value, False, bytes)

captureRejections :: Config -> PipelineMetrics -> Text -> AccountId -> UTCTime -> [(AnalyticsEvent, Object, [ValidationError])] -> IO ()
captureRejections cfg metrics transport account received rejected =
  when (cfg ^. #ingestQuarantine && not (null rows)) $
    void $
      bestEffort metrics $
        diagnosticCommand cfg insertRejections (Aeson.toJSON rows)
  where
    rows =
      [ Aeson.object
          [ "account_id" Aeson..= unAccountId account,
            "received_at" Aeson..= received,
            "event_name" Aeson..= unEventName (original ^. #eventName),
            "schema_version" Aeson..= (original ^. #schemaVersion),
            "reason_codes" Aeson..= nub (validationReason <$> errors),
            "payload" Aeson..= payload,
            "transport" Aeson..= transport,
            "payload_truncated" Aeson..= truncated,
            "original_payload_bytes" Aeson..= bytes
          ]
      | (original, originalObject, errors) <- rejected,
        isJust (lookupVersions (original ^. #eventName) defaultRegistry),
        any declaredSchemaError errors,
        let (payload, truncated, bytes) = boundedPayload (cfg ^. #quarantineMaxPayloadBytes) originalObject
      ]

insertRejections :: ByteString
insertRejections =
  """
  WITH gate AS MATERIALIZED (SELECT kansoku.require_traffic_lock())
  INSERT INTO kansoku.ingest_rejections
    (account_id,received_at,event_name,schema_version,reason_codes,payload,transport,payload_truncated,original_payload_bytes)
  SELECT account_id,received_at,event_name,schema_version,reason_codes,payload,transport,payload_truncated,original_payload_bytes
  FROM jsonb_to_recordset($1) AS r(account_id text,received_at timestamptz,event_name text,schema_version bigint,
    reason_codes jsonb,payload jsonb,transport text,payload_truncated boolean,original_payload_bytes bigint)
  CROSS JOIN gate
  """

-- | Cleanup on startup and hourly thereafter. Lag is refreshed once a minute,
-- and failures retry in a minute. Retention/caps are eventual within an hour.
runQuarantineCleanup :: Config -> PipelineMetrics -> IO ()
runQuarantineCleanup cfg metrics = getCurrentTime >>= loop Nothing
  where
    loop lastSuccess started = do
      now <- getCurrentTime
      P.setGauge (metrics ^. #quarantineCleanupLagSeconds) (realToFrac (diffUTCTime now (fromMaybe started lastSuccess)))
      next <-
        if maybe True ((>= 3600) . diffUTCTime now) lastSuccess
          then do
            ok <- bestEffort metrics (cleanupQuarantine cfg)
            pure (if ok then Just now else lastSuccess)
          else pure lastSuccess
      threadDelay 60_000_000
      loop next started

cleanupQuarantine :: Config -> IO (Either () ())
cleanupQuarantine cfg =
  diagnosticCommand
    cfg
    """
    DELETE FROM kansoku.ingest_rejections WHERE id IN (
      SELECT id FROM (
        SELECT id, received_at, row_number() OVER (PARTITION BY account_id ORDER BY received_at DESC, id DESC) AS position
        FROM kansoku.ingest_rejections
      ) ranked WHERE received_at < now() - ((($1->>'days')::bigint) * interval '1 day')
        OR position > ($1->>'rows')::bigint
    )
    """
    (Aeson.object ["days" Aeson..= (cfg ^. #quarantineRetentionDays), "rows" Aeson..= (cfg ^. #quarantineMaxRows)])

bestEffort :: PipelineMetrics -> IO (Either e ()) -> IO Bool
bestEffort metrics action = do
  result <- timeout 250_000 (trySynchronous action)
  case result of
    Just (Right (Right ())) -> pure True
    _ -> P.incCounter (metrics ^. #quarantineFailuresTotal) >> pure False

-- | Dedicated nonblocking libpq connections keep diagnostic deadlines under
-- this service's control. Released driver cleanup at
-- mori://hasql/hasql/packages/hasql cannot provide this boundary. All dynamic values travel as one JSONB parameter.
diagnosticCommand :: Config -> ByteString -> Aeson.Value -> IO (Either () ())
diagnosticCommand cfg sql params = bracket
  (PQ.connectStart (Text.encodeUtf8 (cfg ^. #pgConnectionString)))
  PQ.finish
  $ \connection -> do
    connected <- connect connection PQ.PollingWriting
    if not connected
      then pure (Left ())
      else do
        nonblocking <- PQ.setnonblocking connection True
        initialized <-
          if nonblocking
            then command connection "SET client_encoding TO 'UTF8'" []
            else pure False
        if not initialized
          then pure (Left ())
          else do
            ok <- command connection sql [Just (PQ.Oid 3802, LBS.toStrict (Aeson.encode params), PQ.Text)]
            pure (if ok then Right () else Left ())

connect :: PQ.Connection -> PQ.PollingStatus -> IO Bool
connect connection polling = case polling of
  PQ.PollingOk -> pure True
  PQ.PollingFailed -> pure False
  _ -> do
    descriptor <- PQ.socket connection
    case descriptor of
      Nothing -> pure False
      Just fd -> do
        case polling of
          PQ.PollingReading -> threadWaitRead fd
          _ -> threadWaitWrite fd
        PQ.connectPoll connection >>= connect connection

command :: PQ.Connection -> ByteString -> [Maybe (PQ.Oid, ByteString, PQ.Format)] -> IO Bool
command connection sql params = do
  sent <- PQ.sendQueryParams connection sql params PQ.Text
  if not sent
    then pure False
    else do
      flushed <- flush connection
      if flushed then results True else pure False
  where
    results ok = do
      ready <- waitResult connection
      if not ready
        then pure False
        else
          PQ.getResult connection >>= \case
            Nothing -> pure ok
            Just result -> do
              status <- PQ.resultStatus result
              results (ok && status == PQ.CommandOk)

flush :: PQ.Connection -> IO Bool
flush connection =
  PQ.flush connection >>= \case
    PQ.FlushOk -> pure True
    PQ.FlushFailed -> pure False
    PQ.FlushWriting -> do
      _ <- PQ.consumeInput connection
      descriptor <- PQ.socket connection
      case descriptor of
        Nothing -> pure False
        Just fd -> threadWaitWrite fd >> flush connection

waitResult :: PQ.Connection -> IO Bool
waitResult connection = do
  ok <- PQ.consumeInput connection
  busy <- PQ.isBusy connection
  if not ok
    then pure False
    else
      if not busy
        then pure True
        else do
          descriptor <- PQ.socket connection
          case descriptor of
            Nothing -> pure False
            Just fd -> threadWaitRead fd >> waitResult connection
