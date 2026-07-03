-- | pgmq queue names, message encoding, and bootstrap.
module Kansoku.Ingest.Queue
  ( bootstrapQueue,
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
import Pgmq.Migration qualified as Migration
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

bootstrapQueue :: Pool.Pool -> QueueName -> IO ()
bootstrapQueue pool queueName = do
  migrated <- Pool.use pool Migration.migrate
  case migrated of
    Left err -> error ("pgmq migration session error: " <> show err)
    Right (Left err) -> error ("pgmq migration error: " <> show err)
    Right (Right ()) -> pure ()

  created <- Pool.use pool (Pgmq.createQueue queueName)
  case created of
    Left err -> error ("pgmq create queue error: " <> show err)
    Right () -> pure ()
