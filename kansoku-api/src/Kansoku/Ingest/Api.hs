-- | Public servant API for analytics ingestion.
module Kansoku.Ingest.Api
  ( BatchAck (..),
    IngestAck (..),
    IngestRoutes (..),
  )
where

import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Servant.API
  ( JSON,
    ReqBody,
    type (:>),
  )
import Servant.API.Generic (type (:-))
import Servant.API.Verbs (Verb)
import Servant.API.Verbs qualified as Servant

-- | Ingestion routes keyed by field name. Field order is not load-bearing.
data IngestRoutes mode = IngestRoutes
  { postEvent :: mode :- "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> Verb 'Servant.POST 202 '[JSON] IngestAck,
    postBatch :: mode :- "v1" :> "batch" :> ReqBody '[JSON] [AnalyticsEvent] :> Verb 'Servant.POST 202 '[JSON] BatchAck
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
