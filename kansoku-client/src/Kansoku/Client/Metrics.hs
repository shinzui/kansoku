{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Typed servant-client access to Kansoku's experiment metrics.
module Kansoku.Client.Metrics
  ( pathsClient,
    experimentConversionClient,
    experimentFunnelClient,
    experimentsClient,
    kansokuMetricsCredential,
    metricsClient,
    cohortsClient,
  )
where

import Data.Time (Day)
import Kansoku.Api.Response (KansokuResult)
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Cohort.Api (Cohorts)
import Kansoku.Metrics.Api (MetricResult, MetricsRoutes, PathBy, TimeGrain)
import Kansoku.Metrics.Api qualified as Metrics
import Kansoku.Metrics.Filter (MetricFilter)
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
  Metrics.experiments metricsClient credential fromDay toDay experiment grain Nothing Nothing []

experimentConversionClient :: AuthenticatedRequest MetricsAuth -> Text -> Text -> Day -> Day -> ClientM (KansokuResult MetricResult)
experimentConversionClient credential experiment event fromDay toDay =
  Metrics.experimentConversion metricsClient credential experiment event fromDay toDay Nothing []

experimentFunnelClient :: AuthenticatedRequest MetricsAuth -> Text -> Text -> Day -> Day -> Maybe Int -> ClientM (KansokuResult MetricResult)
experimentFunnelClient credential experiment steps fromDay toDay window =
  Metrics.experimentFunnel metricsClient credential experiment steps fromDay toDay window Nothing Nothing [] Nothing []

-- | Management and member routes derived from the served cohort contract.
cohortsClient :: Cohorts (AsClientT ClientM)
cohortsClient = ServantClient.client (Proxy @(NamedRoutes Cohorts))

-- | Paths and page flows, derived directly from the served route.
pathsClient :: AuthenticatedRequest MetricsAuth -> Day -> Day -> Maybe Text -> Maybe Text -> Maybe Int -> Maybe Int -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe PathBy -> [MetricFilter] -> ClientM (KansokuResult MetricResult)
pathsClient = Metrics.paths metricsClient
