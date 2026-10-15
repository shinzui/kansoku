{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for the semantic metrics API.
module Kansoku.Metrics.Handler
  ( metricsServer,
  )
where

import Data.Text qualified as Text
import Data.Time (Day, diffDays)
import Effectful (Eff, IOE, runEff)
import Kansoku.Api.Response
  ( KansokuResult (..),
    badRequest,
    notFound,
    unavailable,
  )
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (MetricsPrincipal (..))
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Event (AccountId, defaultRegistry)
import Kansoku.Exception (trySynchronous)
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Metrics.Api (MetricResult, MetricsRoutes (..), TimeGrain (..))
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (mkSqlName, renderSqlName)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

metricsServer :: QueryPool -> MetricsRoutes (AsServerT Handler)
metricsServer pool =
  MetricsRoutes
    { events = metricHandler "events",
      pageViews = metricHandler "page_views",
      sessions = sessionsHandler,
      funnel = funnelHandler,
      retention = retentionHandler,
      acquisition = notImplemented "acquisition",
      featureAdoption = metricHandler "feature_adoption",
      conversion = metricHandler "conversion_rate",
      users = metricHandler "active_users",
      revenue = metricHandler "revenue",
      organizations = notImplemented "organizations",
      custom = notImplemented "custom",
      experiments = experimentsHandler,
      experimentConversion = experimentConversionHandler,
      experimentFunnel = experimentFunnelHandler
    }
  where
    metricHandler :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    metricHandler key (MetricsPrincipal principal) fromDay toDay groupBy timeGrain =
      case builtinMetric key of
        Nothing -> pure (KansokuNotFound (notFound "metric_not_found" ("no such metric: " <> key)))
        Just metric ->
          metricEffToHandler
            (Query.run defaultRegistry pool metric (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain))

    sessionsHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    sessionsHandler (MetricsPrincipal principal) fromDay toDay groupBy timeGrain =
      effToHandler (Query.runSessions pool (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain))

    funnelHandler :: MetricsPrincipal -> Day -> Day -> Text -> Maybe Int -> Handler (KansokuResult MetricResult)
    funnelHandler (MetricsPrincipal principal) fromDay toDay stepsParam requestedWindow =
      case nonEmptyCsv stepsParam of
        [] -> pure (KansokuBadRequest (badRequest "invalid_funnel_steps" ("invalid funnel steps: " <> stepsParam)))
        rawSteps ->
          case traverse mkSqlName rawSteps of
            Left invalid ->
              pure
                ( KansokuBadRequest
                    (badRequest "invalid_funnel_step" ("invalid funnel step: " <> invalid))
                )
            Right steps ->
              case funnelWindow fromDay toDay requestedWindow of
                Left invalid ->
                  pure
                    ( KansokuBadRequest
                        (badRequest "invalid_funnel_window" ("invalid funnel window: " <> invalid <> "; expected 1..7776000 seconds"))
                    )
                Right window ->
                  effToHandler (Query.runFunnel pool (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing) window steps)

    retentionHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Handler (KansokuResult MetricResult)
    retentionHandler (MetricsPrincipal principal) fromDay toDay daysParam =
      case parseOffsets daysParam of
        Left message -> pure (KansokuBadRequest (badRequest "invalid_retention_days" message))
        Right offsets -> effToHandler (Query.runRetention pool (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing) offsets)

    experimentsHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    experimentsHandler (MetricsPrincipal principal) fromDay toDay experimentParam timeGrain =
      case timeGrain of
        Just Hour ->
          pure
            ( KansokuBadRequest
                (badRequest "invalid_experiment_time_grain" "timeGrain hour not supported for experiments (rollup is daily)")
            )
        _ ->
          case traverse mkSqlName experimentParam of
            Left invalid ->
              pure
                ( KansokuBadRequest
                    (badRequest "invalid_experiment_name" ("invalid experiment name: " <> invalid))
                )
            Right experiment ->
              effToHandler
                ( Query.runExperimentExposures
                    pool
                    (queryRequest (principal ^. #accountId) fromDay toDay Nothing timeGrain)
                    experiment
                )

    experimentConversionHandler :: MetricsPrincipal -> Text -> Text -> Day -> Day -> Handler (KansokuResult MetricResult)
    experimentConversionHandler (MetricsPrincipal principal) experimentParam eventParam fromDay toDay =
      case mkSqlName experimentParam of
        Left invalid ->
          pure
            ( KansokuBadRequest
                (badRequest "invalid_experiment_name" ("invalid experiment name: " <> invalid))
            )
        Right experiment ->
          case mkSqlName eventParam of
            Left invalid ->
              pure
                ( KansokuBadRequest
                    (badRequest "invalid_event_name" ("invalid event name: " <> invalid))
                )
            Right conversionEvent
              | renderSqlName conversionEvent == "experiment_viewed" ->
                  pure
                    ( KansokuBadRequest
                        (badRequest "invalid_conversion_event" "conversion event must differ from the exposure event")
                    )
              | otherwise ->
                  effToHandler
                    ( Query.runExperimentConversion
                        pool
                        (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing)
                        experiment
                        conversionEvent
                    )

    experimentFunnelHandler :: MetricsPrincipal -> Text -> Text -> Day -> Day -> Maybe Int -> Handler (KansokuResult MetricResult)
    experimentFunnelHandler (MetricsPrincipal principal) experimentParam stepsParam fromDay toDay requestedWindow =
      case mkSqlName experimentParam of
        Left invalid ->
          pure
            ( KansokuBadRequest
                (badRequest "invalid_experiment_name" ("invalid experiment name: " <> invalid))
            )
        Right experiment ->
          case nonEmptyCsv stepsParam of
            [] -> pure (KansokuBadRequest (badRequest "invalid_funnel_steps" ("invalid funnel steps: " <> stepsParam)))
            rawSteps ->
              case traverse mkSqlName rawSteps of
                Left invalid ->
                  pure
                    ( KansokuBadRequest
                        (badRequest "invalid_funnel_step" ("invalid funnel step: " <> invalid))
                    )
                Right steps ->
                  case funnelWindow fromDay toDay requestedWindow of
                    Left invalid ->
                      pure
                        ( KansokuBadRequest
                            (badRequest "invalid_funnel_window" ("invalid funnel window: " <> invalid <> "; expected 1..7776000 seconds"))
                        )
                    Right window ->
                      effToHandler
                        ( Query.runExperimentFunnel
                            pool
                            (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing)
                            experiment
                            window
                            steps
                        )

    notImplemented :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    notImplemented name _principal _ _ _ _ =
      pure
        ( KansokuNotFound
            (notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name))
        )

queryRequest :: AccountId -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Query.QueryRequest
queryRequest accountId fromDay toDay groupBy timeGrain =
  Query.QueryRequest
    { accountId,
      from = fromDay,
      to = toDay,
      groupBy = nonEmptyCsv <$> groupBy,
      timeGrain
    }

-- SQL safety audit: groupBy selects from a closed expression whitelist;
-- TimeGrain and Day are parsed types; retention offsets are Int values. Funnel
-- steps, experiment names, and conversion events are validated as SqlName and
-- passed as native ClickHouse parameters.

nonEmptyCsv :: Text -> [Text]
nonEmptyCsv =
  filter (not . Text.null) . fmap Text.strip . Text.splitOn ","

parseOffsets :: Maybe Text -> Either Text [Int]
parseOffsets Nothing = Right [1, 7, 14, 30]
parseOffsets (Just raw) =
  traverse parseOne (nonEmptyCsv raw)
  where
    parseOne piece =
      case reads (Text.unpack piece) of
        [(n, "")] | n > 0 -> Right n
        _ -> Left ("invalid day offset: " <> piece)

funnelWindow :: Day -> Day -> Maybe Int -> Either Text Int
funnelWindow fromDay toDay requested =
  case requested of
    Just seconds
      | seconds >= 1 && seconds <= maxFunnelWindowSeconds -> Right seconds
      | otherwise -> Left (Text.pack (show seconds))
    Nothing
      | rangeSeconds <= 0 -> Left (Text.pack (show rangeSeconds))
      | otherwise -> Right (fromInteger (min (toInteger maxFunnelWindowSeconds) rangeSeconds))
  where
    rangeSeconds = toInteger (diffDays toDay fromDay) * 86400

maxFunnelWindowSeconds :: Int
maxFunnelWindowSeconds = 7776000

effToHandler :: Eff '[IOE] MetricResult -> Handler (KansokuResult MetricResult)
effToHandler action = do
  result <- liftIO (trySynchronous (runEff action))
  case result of
    Left err -> do
      liftIO . runEff . runLogStderr $
        logError ("clickhouse query failed: " <> Text.pack (show err))
      pure (KansokuUnavailable (unavailable "clickhouse_unavailable" "analytics storage is unavailable"))
    Right value ->
      pure (KansokuOk value)

metricEffToHandler :: Eff '[IOE] (Either Query.QueryCompileError MetricResult) -> Handler (KansokuResult MetricResult)
metricEffToHandler action = do
  result <- liftIO (trySynchronous (runEff action))
  case result of
    Left err -> do
      liftIO . runEff . runLogStderr $
        logError ("clickhouse query failed: " <> Text.pack (show err))
      pure (KansokuUnavailable (unavailable "clickhouse_unavailable" "analytics storage is unavailable"))
    Right (Left compileError) ->
      pure
        ( KansokuBadRequest
            ( badRequest
                (Query.queryCompileErrorCode compileError)
                (Query.queryCompileErrorMessage compileError)
            )
        )
    Right (Right value) -> pure (KansokuOk value)
