-- | The operational probe surface, separate from the public analytics API.
module Kansoku.Health
  ( OperationalApi (..),
    operationalApi,
    probePaths,
    probeApplication,
    pipelineProbeApplication,
  )
where

import Data.ByteString (ByteString)
import GHC.Generics (Generic)
import Network.Wai (Application)
import Servant (JSON, NamedRoutes, Proxy (..), serve, type (:>))
import Servant.API (StdMethod (GET))
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.Health (HealthApi, ProbeCheck, ProbeResponses, ProbeResult, healthServer, runProbe)
import Servant.Health.Paths (healthRawPaths)

data OperationalApi mode = OperationalApi
  { health :: mode :- "health" :> NamedRoutes HealthApi,
    pipeline :: mode :- "health" :> "pipeline" :> MultiVerb 'GET '[JSON] ProbeResponses ProbeResult
  }
  deriving stock (Generic)

operationalApi :: Proxy (NamedRoutes OperationalApi)
operationalApi = Proxy

probePaths :: [ByteString]
probePaths = healthRawPaths <> ["/health/pipeline"]

probeApplication :: ProbeCheck -> ProbeCheck -> Application
probeApplication liveCheck readyCheck = pipelineProbeApplication liveCheck readyCheck readyCheck

pipelineProbeApplication :: ProbeCheck -> ProbeCheck -> ProbeCheck -> Application
pipelineProbeApplication liveCheck readyCheck pipelineCheck =
  serve operationalApi (OperationalApi {health = healthServer liveCheck readyCheck, pipeline = runProbe pipelineCheck})
