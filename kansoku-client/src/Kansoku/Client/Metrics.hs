{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Typed servant-client access to Kansoku's experiment metrics.
module Kansoku.Client.Metrics
  ( experimentConversionClient,
    experimentsClient,
    kansokuMetricsCredential,
    metricsClient,
  )
where

import Data.Time (Day)
import Kansoku.Api.Response (KansokuResult)
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Metrics.Api (MetricResult, MetricsRoutes, TimeGrain)
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Prelude
import Servant.API (NamedRoutes, type (:>))
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.Client (ClientM)
import Servant.Client qualified as ServantClient
import Servant.Client.Core.Auth (AuthClientData, AuthenticatedRequest, mkAuthenticatedRequest)
import Servant.Client.Core.Request qualified as ClientRequest
import Servant.Client.Generic (AsClientT)

type instance AuthClientData (AuthProtect "kansoku-metrics") = Text

kansokuMetricsCredential :: Text -> AuthenticatedRequest MetricsAuth
kansokuMetricsCredential token =
  mkAuthenticatedRequest token $ \value ->
    ClientRequest.addHeader "Authorization" ("Bearer " <> value)

metricsClient :: AuthenticatedRequest MetricsAuth -> MetricsRoutes (AsClientT ClientM)
metricsClient = ServantClient.client (Proxy @(MetricsAuth :> NamedRoutes MetricsRoutes))

experimentsClient :: AuthenticatedRequest MetricsAuth -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> ClientM (KansokuResult MetricResult)
experimentsClient credential =
  Metrics.experiments (metricsClient credential)

experimentConversionClient :: AuthenticatedRequest MetricsAuth -> Text -> Text -> Day -> Day -> ClientM (KansokuResult MetricResult)
experimentConversionClient credential =
  Metrics.experimentConversion (metricsClient credential)
