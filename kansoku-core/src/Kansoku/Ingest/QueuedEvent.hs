-- | The private queue contract. Producer JSON cannot choose these derived fields.
module Kansoku.Ingest.QueuedEvent
  ( QueuedEvent (..),
    legacyQueuedEvent,
    enrichedQueuedEvent,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.Enrichment (Enrichment, enrichEvent, legacyEnrichment)
import Kansoku.Ingest.RequestContext (IngestRequestContext)
import Kansoku.Prelude

data QueuedEvent = QueuedEvent
  { event :: !AnalyticsEvent,
    enrichment :: !Enrichment
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON QueuedEvent where
  toJSON QueuedEvent {event, enrichment} = Aeson.object ["queueVersion" Aeson..= (1 :: Int), "event" Aeson..= event, "enrichment" Aeson..= enrichment]

instance FromJSON QueuedEvent where
  parseJSON value =
    Aeson.withObject
      "queued event"
      ( \object ->
          case KM.lookup "queueVersion" object of
            Nothing -> legacyQueuedEvent <$> parseJSON value
            Just version -> do
              parsedVersion <- parseJSON version
              unless (parsedVersion == (1 :: Int)) (fail "unsupported queue envelope version")
              QueuedEvent <$> object Aeson..: "event" <*> object Aeson..: "enrichment"
      )
      value

legacyQueuedEvent :: AnalyticsEvent -> QueuedEvent
legacyQueuedEvent event = QueuedEvent event legacyEnrichment

enrichedQueuedEvent :: IngestRequestContext -> AnalyticsEvent -> QueuedEvent
enrichedQueuedEvent request event = QueuedEvent event (enrichEvent request event)
