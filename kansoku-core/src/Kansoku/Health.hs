-- | The operational probe surface, separate from the public analytics API.
module Kansoku.Health
  ( OperationalApi (..),
    operationalApi,
    probePaths,
    probeApplication,
  )
where

import Data.ByteString (ByteString)
import GHC.Generics (Generic)
import Network.Wai (Application)
import Servant (NamedRoutes, Proxy (..), serve, type (:>))
import Servant.API.Generic (type (:-))
import Servant.Health (HealthApi, ProbeCheck, healthServer)
import Servant.Health.Paths (healthRawPaths)

data OperationalApi mode = OperationalApi
  { health :: mode :- "health" :> NamedRoutes HealthApi
  }
  deriving stock (Generic)

operationalApi :: Proxy (NamedRoutes OperationalApi)
operationalApi = Proxy

probePaths :: [ByteString]
probePaths = healthRawPaths <> ["/health", "/ready"]

probeApplication :: ProbeCheck -> ProbeCheck -> Application
probeApplication liveCheck readyCheck =
  serve operationalApi (OperationalApi {health = healthServer liveCheck readyCheck})
