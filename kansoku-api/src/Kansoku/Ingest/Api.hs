-- | Public servant API for analytics ingestion.
module Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
    IngestEvent (..),
    ingestEvent,
    RejectedEvent (..),
  )
where

import Data.Aeson (Object, Value (Object), withObject)
import Kansoku.Api.Response (AcceptedResponses, KansokuResult, ProblemJSON)
import Kansoku.Auth.Api (IngestAuth)
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Servant.API
  ( JSON,
    ReqBody,
    type (:>),
  )
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.API.Verbs qualified as Servant

-- | Ingestion routes keyed by field name. Field order is not load-bearing.
data IngestRoutes mode = IngestRoutes
  { postEvent :: mode :- IngestAuth :> "v1" :> "events" :> ReqBody '[JSON] IngestEvent :> MultiVerb 'Servant.POST '[JSON, ProblemJSON] (AcceptedResponses "Event accepted" IngestAck) (KansokuResult IngestAck),
    postBatch :: mode :- IngestAuth :> "v1" :> "batch" :> ReqBody '[JSON] [IngestEvent] :> MultiVerb 'Servant.POST '[JSON, ProblemJSON] (AcceptedResponses "Batch accepted" BatchAck) (KansokuResult BatchAck)
  }
  deriving stock (Generic)

data IngestAck = IngestAck
  { accepted :: !Int,
    eventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | One rejected event in a batch. The zero-based index is the stable
-- machine-usable correlation key; the error text is for people, not parsers.
data RejectedEvent = RejectedEvent
  { index :: !Int,
    eventId :: !(Maybe Text),
    errors :: ![Text]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A parsed batch is always acknowledged with HTTP 202. Valid events are
-- enqueued and invalid events are reported here so clients never retry them.
data BatchAck = BatchAck
  { accepted :: !Int,
    rejected :: ![RejectedEvent]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The parsed event and the exact original event object. Only the object is
-- represented on the wire; normalized queue records remain AnalyticsEvent.
data IngestEvent = IngestEvent
  { parsedEvent :: !AnalyticsEvent,
    originalPayload :: !Object
  }
  deriving stock (Generic, Eq, Show)

instance FromJSON IngestEvent where
  parseJSON = withObject "AnalyticsEvent" $ \object ->
    IngestEvent <$> parseJSON (Object object) <*> pure object

instance ToJSON IngestEvent where
  toJSON = Object . originalPayload

ingestEvent :: AnalyticsEvent -> IngestEvent
ingestEvent event = case toJSON event of
  Object object -> IngestEvent event object
  _ -> error "AnalyticsEvent JSON must be an object"
