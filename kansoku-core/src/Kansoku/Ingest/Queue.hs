-- | pgmq queue names, message encoding, and bootstrap.
module Kansoku.Ingest.Queue
  ( provisionQueue,
    decodeEvent,
    encodeEvent,
    decodeQueuedEvent,
    encodeQueuedEvent,
    eventsQueueName,
  )
where

import Data.Aeson.Types (Value, parseMaybe)
import Hasql.Pool qualified as Pool
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Prelude
import Pgmq qualified
import Pgmq.Types (MessageBody (..), QueueName, parseQueueName)

eventsQueueName :: Text -> QueueName
eventsQueueName raw =
  case parseQueueName raw of
    Right name -> name
    Left err -> error ("invalid pgmq queue name: " <> show err)

encodeEvent :: AnalyticsEvent -> MessageBody
encodeEvent = encodeQueuedEvent . enrichedQueuedEvent emptyRequestContext

decodeEvent :: Value -> Maybe AnalyticsEvent
decodeEvent value = (view #event) <$> decodeQueuedEvent value

encodeQueuedEvent :: QueuedEvent -> MessageBody
encodeQueuedEvent = MessageBody . toJSON

decodeQueuedEvent :: Value -> Maybe QueuedEvent
decodeQueuedEvent = parseMaybe parseJSON

-- | Idempotently create an application queue after schema migration.
provisionQueue :: Pool.Pool -> QueueName -> IO ()
provisionQueue pool queueName = do
  created <- Pool.use pool (Pgmq.createQueue queueName)
  case created of
    Left err -> error ("pgmq create queue error: " <> show err)
    Right () -> pure ()
