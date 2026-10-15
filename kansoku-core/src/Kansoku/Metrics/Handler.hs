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
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricResult, MetricsRoutes (..), SessionMeasure (..), TimeGrain (..))
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), mkSqlName, renderSqlName, validateDateRange)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

metricsServer :: QueryPool -> MetricsRoutes (AsServerT Handler)
metricsServer pool =
  MetricsRoutes
    { events = metricHandler "events",
      pageViews = webMetricHandler "page_views",
      sessions = sessionsHandler,
      funnel = funnelHandler,
      retention = retentionHandler,
      acquisition = acquisitionHandler,
      featureAdoption = metricHandler "feature_adoption",
      conversion = metricHandler "conversion_rate",
      users = webMetricHandler "active_users",
      revenue = metricHandler "revenue",
      organizations = notImplemented "organizations",
      custom = notImplemented "custom",
      experiments = experimentsHandler,
      experimentConversion = experimentConversionHandler,
      experimentFunnel = experimentFunnelHandler
    }
  where
    metricHandler :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Handler (KansokuResult MetricResult)
    metricHandler key (MetricsPrincipal principal) fromDay toDay groupBy timeGrain filters =
      case builtinMetric key of
        Nothing -> pure (KansokuNotFound (notFound "metric_not_found" ("no such metric: " <> key)))
        Just metric ->
          metricEffToHandler
            (Query.run defaultRegistry pool metric (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain filters))

    webMetricHandler :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Maybe Bool -> Handler (KansokuResult MetricResult)
    webMetricHandler key (MetricsPrincipal principal) fromDay toDay groupBy timeGrain filters bots =
      case builtinMetric key of
        Nothing -> pure (KansokuNotFound (notFound "metric_not_found" ("no such metric: " <> key)))
        Just metric -> metricEffToHandler (Query.run defaultRegistry pool metric (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain filters) {Query.includeBots = fromMaybe False bots})

    acquisitionHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Maybe AcquisitionMeasure -> Maybe Bool -> Handler (KansokuResult MetricResult)
    acquisitionHandler (MetricsPrincipal principal) fromDay toDay groupBy timeGrain filters measure bots =
      effToHandler (Query.runAcquisition defaultRegistry pool (fromMaybe AcquisitionSessions measure) (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain filters) {Query.includeBots = fromMaybe False bots})

    sessionsHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Maybe SessionMeasure -> Maybe Bool -> Handler (KansokuResult MetricResult)
    sessionsHandler (MetricsPrincipal principal) fromDay toDay groupBy timeGrain filters measure bots =
      effToHandler (Query.runSessionMetric pool (fromMaybe SessionCount measure) (queryRequest (principal ^. #accountId) fromDay toDay groupBy timeGrain filters) {Query.includeBots = fromMaybe False bots})

    funnelHandler :: MetricsPrincipal -> Day -> Day -> Text -> Maybe Int -> Handler (KansokuResult MetricResult)
    funnelHandler (MetricsPrincipal principal) fromDay toDay stepsParam requestedWindow =
      withDateRange fromDay toDay $
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
                    effToHandler (Query.runFunnel pool (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing []) window steps)

    retentionHandler :: MetricsPrincipal -> Day -> Day -> Maybe Text -> Handler (KansokuResult MetricResult)
    retentionHandler (MetricsPrincipal principal) fromDay toDay daysParam =
      case parseOffsets daysParam of
        Left message -> pure (KansokuBadRequest (badRequest "invalid_retention_days" message))
        Right offsets -> effToHandler (Query.runRetention pool (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing []) offsets)

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
                    (queryRequest (principal ^. #accountId) fromDay toDay Nothing timeGrain [])
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
                        (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing [])
                        experiment
                        conversionEvent
                    )

    experimentFunnelHandler :: MetricsPrincipal -> Text -> Text -> Day -> Day -> Maybe Int -> Handler (KansokuResult MetricResult)
    experimentFunnelHandler (MetricsPrincipal principal) experimentParam stepsParam fromDay toDay requestedWindow =
      withDateRange fromDay toDay $
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
                              (queryRequest (principal ^. #accountId) fromDay toDay Nothing Nothing [])
                              experiment
                              window
                              steps
                          )

    notImplemented :: Text -> MetricsPrincipal -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Handler (KansokuResult MetricResult)
    notImplemented name _principal _ _ _ _ _ =
      pure
        ( KansokuNotFound
            (notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name))
        )

queryRequest :: AccountId -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> [MetricFilter] -> Query.QueryRequest
queryRequest accountId fromDay toDay groupBy timeGrain filters =
  Query.QueryRequest
    { accountId,
      from = fromDay,
      to = toDay,
      groupBy = (map Text.strip . Text.splitOn ",") <$> groupBy,
      timeGrain,
      filters,
      includeBots = False
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
      case reads (Text.unpack piece) :: [(Integer, String)] of
        [(n, "")] | n >= 1 && n <= 365 -> Right (fromInteger n)
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

effToHandler :: Eff '[IOE] (Either Query.QueryExecutionError MetricResult) -> Handler (KansokuResult MetricResult)
effToHandler action = do
  result <- liftIO (trySynchronous (runEff action))
  case result of
    Left err -> storageFailure (Text.pack (show err))
    Right (Right value) -> pure (KansokuOk value)
    Right (Left failure) -> case failure of
      Query.QueryCompileFailure compileError ->
        pure $
          KansokuBadRequest (badRequest (Query.queryCompileErrorCode compileError) (Query.queryCompileErrorMessage compileError))
      Query.QueryLimitFailure (QueryLimitError code message) -> pure (KansokuBadRequest (badRequest code message))
      Query.MetricResultTooLarge -> pure (KansokuBadRequest (badRequest "metric_result_too_large" "narrow the query range or grouping to at most 10000 metric points"))
      Query.QueryResourceLimit -> pure (KansokuBadRequest (badRequest "query_resource_limit" "narrow the query to fit the configured execution and memory limits"))
      Query.QueryStorageFailure message -> storageFailure message
  where
    storageFailure message = do
      liftIO . runEff . runLogStderr $ logError ("clickhouse query failed: " <> message)
      pure (KansokuUnavailable (unavailable "clickhouse_unavailable" "analytics storage is unavailable"))

metricEffToHandler :: Eff '[IOE] (Either Query.QueryExecutionError MetricResult) -> Handler (KansokuResult MetricResult)
metricEffToHandler = effToHandler

withDateRange :: Day -> Day -> Handler (KansokuResult MetricResult) -> Handler (KansokuResult MetricResult)
withDateRange fromDay toDay action = case validateDateRange fromDay toDay of
  Left (QueryLimitError code message) -> pure (KansokuBadRequest (badRequest code message))
  Right () -> action
