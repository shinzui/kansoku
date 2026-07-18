-- | Public servant API for analytics ingestion.
module Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
  )
where

import Kansoku.Api.Response (AcceptedResponses, KansokuResult)
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
  { postEvent :: mode :- "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> MultiVerb 'Servant.POST '[JSON] (AcceptedResponses "Event accepted" IngestAck) (KansokuResult IngestAck),
    postBatch :: mode :- "v1" :> "batch" :> ReqBody '[JSON] [AnalyticsEvent] :> MultiVerb 'Servant.POST '[JSON] (AcceptedResponses "Batch accepted" BatchAck) (KansokuResult BatchAck)
  }
  deriving stock (Generic)

data IngestAck = IngestAck
  { accepted :: !Int,
    eventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype BatchAck = BatchAck
  { accepted :: Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
