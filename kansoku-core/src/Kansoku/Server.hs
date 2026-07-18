{-# LANGUAGE TypeApplications #-}

-- | The minimal HTTP server for EP-1: a single /health route returning 200 OK.
module Kansoku.Server
  ( ReadyProbe (..),
    healthApp,
    kansokuApp,
    kansokuServer,
    pgmqReady,
    startServer,
  )
where

import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, runEff, type (:>))
import Effectful.Error.Static qualified as Error
import Effectful.Reader.Static (Reader, asks)
import Hasql.Pool qualified as Pool
import Kansoku.Api (KansokuAPI (..), kansokuAPI)
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Config (Config)
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Logging (Log, logInfo)
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.OpenApi (openApiDoc)
import Kansoku.Prelude
import Network.HTTP.Types (status200, status404, status503)
import Network.HTTP.Types.Header (hContentType)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Pgmq.Effectful (QueueName, queueMetrics, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Servant (Handler, serve)
import Servant.Server.Generic (AsServerT)

-- | Runtime checks used to answer GET /ready.
data ReadyProbe = ReadyProbe
  { writerAlive :: !(IO Bool),
    pgmqReachable :: !(IO (Either Text ()))
  }
  deriving stock (Generic)

-- | The WAI application. GET /health -> 200 "OK"; everything else -> 404.
healthApp :: Application
healthApp req respond =
  case pathInfo req of
    ["health"] ->
      respond (responseLBS status200 [(hContentType, "text/plain")] "OK")
    _ ->
      respond (responseLBS status404 [(hContentType, "text/plain")] "Not Found")

kansokuServer :: Pool.Pool -> QueueName -> QueryPool -> KansokuAPI (AsServerT Handler)
kansokuServer pool queueName queryPool =
  KansokuAPI
    { ingest = ingestServer pool queueName,
      metrics = metricsServer queryPool
    }

kansokuApp :: ReadyProbe -> Pool.Pool -> QueueName -> QueryPool -> Application
kansokuApp probe pool queueName queryPool req respond =
  case pathInfo req of
    ["health"] ->
      healthApp req respond
    ["ready"] -> do
      isWriterAlive <- probe ^. #writerAlive
      postgresResult <- probe ^. #pgmqReachable
      let failingDependencies :: [Text]
          failingDependencies =
            ["writer" | not isWriterAlive]
              <> either (const ["postgres"]) (const []) postgresResult
          body
            | null failingDependencies = Aeson.object ["status" Aeson..= ("ready" :: Text)]
            | otherwise =
                Aeson.object
                  [ "status" Aeson..= ("unavailable" :: Text),
                    "failing" Aeson..= failingDependencies
                  ]
          status
            | null failingDependencies = status200
            | otherwise = status503
      respond (responseLBS status [(hContentType, "application/json")] (Aeson.encode body))
    ["openapi.json"] ->
      respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode openApiDoc))
    _ ->
      serve kansokuAPI (kansokuServer pool queueName queryPool) req respond

-- | Check that PostgreSQL and pgmq answer one inexpensive metrics query.
pgmqReady :: Pool.Pool -> QueueName -> IO (Either Text ())
pgmqReady pool queueName = do
  result <-
    runEff $
      Error.runErrorNoCallStack @PgmqRuntimeError $
        runPgmq pool $
          queueMetrics queueName
  pure $ case result of
    Left err -> Left (Text.pack (show err))
    Right _metrics -> Right ()

-- | Read the configured port, log a startup line, and run Warp. This blocks.
startServer :: (IOE :> es, Reader Config :> es, Log :> es) => Application -> Eff es ()
startServer app = do
  port <- asks @Config (^. #serverPort)
  logInfo ("kansoku-server listening on port " <> Text.pack (show port) <> " (GET /health, GET /ready, GET /openapi.json, POST /v1/events, POST /v1/batch, GET /metrics/*)")
  liftIO (Warp.run port app)
