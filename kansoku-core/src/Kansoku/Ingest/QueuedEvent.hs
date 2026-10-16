-- | The private queue contract. Producer JSON cannot choose these derived fields.
module Kansoku.Ingest.QueuedEvent
  ( QueuedEvent (..),
    legacyQueuedEvent,
    enrichedQueuedEvent,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Kansoku.Event (AnalyticsEvent, governedTraitEligible)
import Kansoku.Ingest.Enrichment (Enrichment, enrichEvent, legacyEnrichment)
import Kansoku.Ingest.RequestContext (IngestRequestContext)
import Kansoku.Prelude

data QueuedEvent = QueuedEvent
  { event :: !AnalyticsEvent,
    enrichment :: !Enrichment,
    traitsEligible :: !Bool
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON QueuedEvent where
  toJSON QueuedEvent {event, enrichment, traitsEligible} = Aeson.object ["queueVersion" Aeson..= (2 :: Int), "event" Aeson..= event, "enrichment" Aeson..= enrichment, "traitsEligible" Aeson..= traitsEligible]

instance FromJSON QueuedEvent where
  parseJSON value =
    Aeson.withObject
      "queued event"
      ( \object ->
          case KM.lookup "queueVersion" object of
            Nothing -> legacyQueuedEvent <$> parseJSON value
            Just version -> do
              parsedVersion <- parseJSON version
              unless (parsedVersion `elem` [1, 2 :: Int]) (fail "unsupported queue envelope version")
              QueuedEvent <$> object Aeson..: "event" <*> object Aeson..: "enrichment" <*> (if parsedVersion == 1 then pure False else object Aeson..: "traitsEligible")
      )
      value

legacyQueuedEvent :: AnalyticsEvent -> QueuedEvent
legacyQueuedEvent event = QueuedEvent event legacyEnrichment False

enrichedQueuedEvent :: IngestRequestContext -> AnalyticsEvent -> QueuedEvent
enrichedQueuedEvent request event = QueuedEvent event (enrichEvent request event) (governedTraitEligible event)
