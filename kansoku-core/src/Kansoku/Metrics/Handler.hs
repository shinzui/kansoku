{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for the semantic metrics API.
module Kansoku.Metrics.Handler
  ( metricsServer,
  )
where

import Control.Exception (SomeException, try)
import Data.Text qualified as Text
import Data.Time (Day)
import Effectful (Eff, IOE, runEff)
import Kansoku.Api.Response
  ( KansokuResult (..),
    badRequest,
    notFound,
    unavailable,
  )
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Metrics.Api (MetricResult, MetricsRoutes (..), TimeGrain)
import Kansoku.Metrics.Query qualified as Query
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
      featureAdoption = notImplemented "feature_adoption",
      conversion = metricHandler "conversion_rate",
      users = metricHandler "active_users",
      organizations = notImplemented "organizations",
      custom = notImplemented "custom"
    }
  where
    metricHandler :: Text -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    metricHandler key fromDay toDay groupBy timeGrain =
      case builtinMetric key of
        Nothing -> pure (KansokuNotFound (notFound "metric_not_found" ("no such metric: " <> key)))
        Just metric -> effToHandler (Query.run pool metric (queryRequest fromDay toDay groupBy timeGrain))

    sessionsHandler :: Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    sessionsHandler fromDay toDay groupBy timeGrain =
      effToHandler (Query.runSessions pool (queryRequest fromDay toDay groupBy timeGrain))

    funnelHandler :: Day -> Day -> Text -> Handler (KansokuResult MetricResult)
    funnelHandler fromDay toDay stepsParam =
      case nonEmptyCsv stepsParam of
        [] -> pure (KansokuBadRequest (badRequest "invalid_funnel_steps" ("invalid funnel steps: " <> stepsParam)))
        steps -> effToHandler (Query.runFunnel pool (queryRequest fromDay toDay Nothing Nothing) steps)

    retentionHandler :: Day -> Day -> Maybe Text -> Handler (KansokuResult MetricResult)
    retentionHandler fromDay toDay daysParam =
      case parseOffsets daysParam of
        Left message -> pure (KansokuBadRequest (badRequest "invalid_retention_days" message))
        Right offsets -> effToHandler (Query.runRetention pool (queryRequest fromDay toDay Nothing Nothing) offsets)

    notImplemented :: Text -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler (KansokuResult MetricResult)
    notImplemented name _ _ _ _ =
      pure
        ( KansokuNotFound
            (notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name))
        )

queryRequest :: Day -> Day -> Maybe Text -> Maybe TimeGrain -> Query.QueryRequest
queryRequest fromDay toDay groupBy timeGrain =
  Query.QueryRequest
    { from = fromDay,
      to = toDay,
      groupBy = nonEmptyCsv <$> groupBy,
      timeGrain
    }

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

effToHandler :: Eff '[IOE] MetricResult -> Handler (KansokuResult MetricResult)
effToHandler action = do
  result <- liftIO (try @SomeException (runEff action))
  case result of
    Left err -> do
      liftIO . runEff . runLogStderr $
        logError ("clickhouse query failed: " <> Text.pack (show err))
      pure (KansokuUnavailable (unavailable "clickhouse_unavailable" "analytics storage is unavailable"))
    Right value ->
      pure (KansokuOk value)
