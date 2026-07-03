-- | Public servant API for analytics ingestion.
module Kansoku.Api.Ingest
  ( BatchAck (..),
    IngestAPI,
    IngestAck (..),
  )
where

import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Servant.API
  ( JSON,
    ReqBody,
    type (:<|>),
    type (:>),
  )
import Servant.API.Verbs (Verb)
import Servant.API.Verbs qualified as Servant

type IngestAPI =
  "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> Verb 'Servant.POST 202 '[JSON] IngestAck
    :<|> "v1" :> "batch" :> ReqBody '[JSON] [AnalyticsEvent] :> Verb 'Servant.POST 202 '[JSON] BatchAck

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
