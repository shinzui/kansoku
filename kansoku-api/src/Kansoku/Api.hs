-- | Shared servant API type for the Kansoku service.
module Kansoku.Api
  ( KansokuAPI (..),
    SchemaAPI,
    kansokuAPI,
  )
where

import Kansoku.Event.Contract (SchemaCatalog)
import Kansoku.Ingest.Api (IngestRoutes)
import Kansoku.Metrics.Api (MetricsRoutes)
import Kansoku.Prelude
import Servant.API (Description, Get, JSON, NamedRoutes, type (:>))
import Servant.API.Generic (type (:-))

-- | The analytics contract served and documented by Kansoku.
data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- NamedRoutes IngestRoutes,
    metrics :: mode :- NamedRoutes MetricsRoutes,
    schemas :: mode :- SchemaAPI
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy

type SchemaAPI =
  "v1"
    :> "schemas"
    :> Description "Public event schema catalog. The same contract is committed at docs/contracts/events.json."
    :> Get '[JSON] SchemaCatalog
