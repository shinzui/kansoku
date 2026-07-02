module Kansoku.Ingest.QueueSpec (spec) where

import Data.Time (defaultTimeLocale, parseTimeOrError)
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    EventName (..),
    EventSource (..),
    baseEvent,
  )
import Kansoku.Ingest.Queue
  ( decodeEvent,
    encodeEvent,
    eventsQueueName,
  )
import Kansoku.Prelude
import Pgmq.Types (MessageBody (..), queueNameToText)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "Kansoku.Ingest.Queue" $ do
  it "round-trips an event through pgmq message body encoding" $ do
    let message = encodeEvent sampleEvent
    decodeEvent (unMessageBody message) `shouldBe` Just sampleEvent

  it "uses the canonical queue name text" $ do
    queueNameToText (eventsQueueName "kansoku_events") `shouldBe` "kansoku_events"

sampleEvent :: AnalyticsEvent
sampleEvent =
  baseEvent
    (EventId "event-1")
    (EventName "page_viewed")
    Web
    sampleTime
    sampleTime

sampleTime :: UTCTime
sampleTime =
  parseTimeOrError True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" "2026-07-01T12:00:00Z"
