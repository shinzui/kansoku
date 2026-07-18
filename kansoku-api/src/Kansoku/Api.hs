-- | Shared servant API type for the Kansoku service.
module Kansoku.Api
  ( KansokuAPI (..),
    kansokuAPI,
  )
where

import Kansoku.Ingest.Api (IngestRoutes)
import Kansoku.Metrics.Api (MetricsRoutes)
import Kansoku.Prelude
import Servant.API (NamedRoutes)
import Servant.API.Generic (type (:-))

-- | The analytics contract served and documented by Kansoku.
data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- NamedRoutes IngestRoutes,
    metrics :: mode :- NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy
