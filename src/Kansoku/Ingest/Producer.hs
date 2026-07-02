-- | Producer-side enqueue operations for analytics events.
module Kansoku.Ingest.Producer
  ( enqueueMany,
    enqueueOne,
  )
where

import Effectful (Eff, type (:>))
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.Queue (encodeEvent)
import Pgmq.Effectful
  ( BatchSendMessage (..),
    MessageId,
    Pgmq,
    QueueName,
    SendMessage (..),
    batchSendMessage,
    sendMessage,
  )

enqueueOne :: (Pgmq :> es) => QueueName -> AnalyticsEvent -> Eff es MessageId
enqueueOne queueName event =
  sendMessage
    SendMessage
      { queueName,
        messageBody = encodeEvent event,
        delay = Nothing
      }

enqueueMany :: (Pgmq :> es) => QueueName -> [AnalyticsEvent] -> Eff es [MessageId]
enqueueMany _ [] = pure []
enqueueMany queueName events =
  batchSendMessage
    BatchSendMessage
      { queueName,
        messageBodies = encodeEvent <$> events,
        delay = Nothing
      }
