{-# LANGUAGE TypeApplications #-}

-- | Servant handlers for the semantic metrics API.
module Kansoku.Metrics.Handler
  ( metricsApp,
    metricsServer,
  )
where

import ClickHaskell (Connection)
import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Time (Day)
import Effectful (Eff, IOE, runEff)
import Kansoku.Api.Metrics (MetricResult, MetricsAPI, TimeGrain)
import Kansoku.Logging (logError, runLogStderr)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Kansoku.Query qualified as Query
import Network.Wai (Application)
import Servant
  ( Handler,
    Server,
    ServerError (..),
    err400,
    err404,
    err501,
    err503,
    serve,
    throwError,
    type (:<|>) (..),
  )

metricsApp :: Connection -> Application
metricsApp conn =
  serve (Proxy @MetricsAPI) (metricsServer conn)

metricsServer :: Connection -> Server MetricsAPI
metricsServer conn =
  metricHandler "events"
    :<|> metricHandler "page_views"
    :<|> sessionsHandler
    :<|> funnelHandler
    :<|> retentionHandler
    :<|> notImplemented "acquisition"
    :<|> notImplemented "feature_adoption"
    :<|> metricHandler "conversion_rate"
    :<|> metricHandler "active_users"
    :<|> notImplemented "organizations"
    :<|> notImplemented "custom"
  where
    metricHandler :: Text -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler MetricResult
    metricHandler key fromDay toDay groupBy timeGrain =
      case builtinMetric key of
        Nothing -> throwError (jsonError err404 "metric not found" (Aeson.object ["metric" Aeson..= key]))
        Just metric -> effToHandler (Query.run conn metric (queryRequest fromDay toDay groupBy timeGrain))

    sessionsHandler :: Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler MetricResult
    sessionsHandler fromDay toDay groupBy timeGrain =
      effToHandler (Query.runSessions conn (queryRequest fromDay toDay groupBy timeGrain))

    funnelHandler :: Day -> Day -> Text -> Handler MetricResult
    funnelHandler fromDay toDay stepsParam =
      case nonEmptyCsv stepsParam of
        [] -> throwError (jsonError err400 "invalid funnel steps" (Aeson.object ["steps" Aeson..= stepsParam]))
        steps -> effToHandler (Query.runFunnel conn (queryRequest fromDay toDay Nothing Nothing) steps)

    retentionHandler :: Day -> Day -> Maybe Text -> Handler MetricResult
    retentionHandler fromDay toDay daysParam =
      case parseOffsets daysParam of
        Left message -> throwError (jsonError err400 "invalid retention days" (Aeson.object ["details" Aeson..= message]))
        Right offsets -> effToHandler (Query.runRetention conn (queryRequest fromDay toDay Nothing Nothing) offsets)

    notImplemented :: Text -> Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler MetricResult
    notImplemented name _ _ _ _ =
      throwError
        ( err501
            { errBody =
                Aeson.encode
                  ( Aeson.object
                      [ "error" Aeson..= ("not_implemented" :: Text),
                        "metric" Aeson..= name,
                        "message" Aeson..= ("This metric endpoint is stubbed in the MVP." :: Text)
                      ]
                  ),
              errHeaders = [("content-type", "application/json")]
            }
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

effToHandler :: Eff '[IOE] MetricResult -> Handler MetricResult
effToHandler action = do
  result <- liftIO (try @SomeException (runEff action))
  case result of
    Left err -> do
      liftIO . runEff . runLogStderr $
        logError ("clickhouse query failed: " <> Text.pack (show err))
      throwError (jsonError err503 "clickhouse query failed" (Aeson.object []))
    Right value ->
      pure value

jsonError :: ServerError -> Text -> Aeson.Value -> ServerError
jsonError err message details =
  err
    { errBody =
        Aeson.encode
          ( Aeson.object
              [ "error" Aeson..= message,
                "details" Aeson..= details
              ]
          ),
      errHeaders = [("content-type", "application/json")]
    }
