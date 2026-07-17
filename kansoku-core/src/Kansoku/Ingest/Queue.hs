-- | pgmq queue names, message encoding, and bootstrap.
module Kansoku.Ingest.Queue
  ( provisionQueue,
    decodeEvent,
    encodeEvent,
    eventsQueueName,
  )
where

import Data.Aeson.Types (Value, parseMaybe)
import Hasql.Pool qualified as Pool
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Pgmq qualified
import Pgmq.Types (MessageBody (..), QueueName, parseQueueName)

eventsQueueName :: Text -> QueueName
eventsQueueName raw =
  case parseQueueName raw of
    Right name -> name
    Left err -> error ("invalid pgmq queue name: " <> show err)

encodeEvent :: AnalyticsEvent -> MessageBody
encodeEvent = MessageBody . toJSON

decodeEvent :: Value -> Maybe AnalyticsEvent
decodeEvent = parseMaybe parseJSON

-- | Idempotently create an application queue after schema migration.
provisionQueue :: Pool.Pool -> QueueName -> IO ()
provisionQueue pool queueName = do
  created <- Pool.use pool (Pgmq.createQueue queueName)
  case created of
    Left err -> error ("pgmq create queue error: " <> show err)
    Right () -> pure ()
