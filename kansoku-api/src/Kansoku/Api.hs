-- | Shared servant API type for the Kansoku service.
module Kansoku.Api
  ( KansokuAPI (..),
    kansokuAPI,
  )
where

import Kansoku.Auth.Api (IngestAuth, MetricsAuth)
import Kansoku.Ingest.Api (IngestRoutes)
import Kansoku.Metrics.Api (MetricsRoutes)
import Kansoku.Prelude
import Servant.API (NamedRoutes, type (:>))
import Servant.API.Generic (type (:-))

-- | The analytics contract served and documented by Kansoku.
data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- IngestAuth :> NamedRoutes IngestRoutes,
    metrics :: mode :- MetricsAuth :> NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy
