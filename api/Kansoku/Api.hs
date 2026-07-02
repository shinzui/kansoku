-- | Shared servant API type for the Kansoku service.
module Kansoku.Api
  ( KansokuAPI,
  )
where

import Kansoku.Api.Ingest (IngestAPI)
import Kansoku.Api.Metrics (MetricsAPI)
import Servant.API (type (:<|>))

type KansokuAPI = IngestAPI :<|> MetricsAPI
