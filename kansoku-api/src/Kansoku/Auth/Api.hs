-- | Type-level authentication boundaries for the two analytics route families.
module Kansoku.Auth.Api
  ( BeaconContext,
    IngestAuth,
    MetricsAuth,
  )
where

import Servant.API.Experimental.Auth (AuthProtect)

type IngestAuth = AuthProtect "kansoku-ingest"

type MetricsAuth = AuthProtect "kansoku-metrics"

-- Request context only; the envelope supplies the sole credential.
type BeaconContext = AuthProtect "kansoku-beacon"
