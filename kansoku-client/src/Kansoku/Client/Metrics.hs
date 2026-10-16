{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Typed servant-client access to Kansoku's experiment metrics.
module Kansoku.Client.Metrics
  ( experimentConversionClient,
    experimentFunnelClient,
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
import Servant.API (NamedRoutes)
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

metricsClient :: MetricsRoutes (AsClientT ClientM)
metricsClient = ServantClient.client (Proxy @(NamedRoutes MetricsRoutes))

experimentsClient :: AuthenticatedRequest MetricsAuth -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> ClientM (KansokuResult MetricResult)
experimentsClient credential fromDay toDay experiment grain =
  Metrics.experiments metricsClient credential fromDay toDay experiment grain Nothing

experimentConversionClient :: AuthenticatedRequest MetricsAuth -> Text -> Text -> Day -> Day -> ClientM (KansokuResult MetricResult)
experimentConversionClient credential =
  Metrics.experimentConversion metricsClient credential

experimentFunnelClient :: AuthenticatedRequest MetricsAuth -> Text -> Text -> Day -> Day -> Maybe Int -> ClientM (KansokuResult MetricResult)
experimentFunnelClient credential experiment steps fromDay toDay window =
  Metrics.experimentFunnel metricsClient credential experiment steps fromDay toDay window Nothing Nothing [] Nothing []
