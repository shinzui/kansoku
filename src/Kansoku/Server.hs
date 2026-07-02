{-# LANGUAGE TypeApplications #-}

-- | The minimal HTTP server for EP-1: a single /health route returning 200 OK.
module Kansoku.Server
  ( healthApp,
    kansokuApp,
    startServer,
  )
where

import ClickHaskell (Connection)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Reader.Static (Reader, asks)
import Hasql.Pool qualified as Pool
import Kansoku.Config (Config)
import Kansoku.Ingest.Handler (ingestApp)
import Kansoku.Logging (Log, logInfo)
import Kansoku.Metrics.Handler (metricsApp)
import Kansoku.OpenApi (openApiDoc)
import Kansoku.Prelude
import Network.HTTP.Types (status200, status404)
import Network.HTTP.Types.Header (hContentType)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Pgmq.Effectful (QueueName)

-- | The WAI application. GET /health -> 200 "OK"; everything else -> 404.
healthApp :: Application
healthApp req respond =
  case pathInfo req of
    ["health"] ->
      respond (responseLBS status200 [(hContentType, "text/plain")] "OK")
    _ ->
      respond (responseLBS status404 [(hContentType, "text/plain")] "Not Found")

kansokuApp :: Pool.Pool -> QueueName -> Connection -> Application
kansokuApp pool queueName clickHouse req respond =
  case pathInfo req of
    ["health"] ->
      healthApp req respond
    ["openapi.json"] ->
      respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode openApiDoc))
    "metrics" : _ ->
      metricsApp clickHouse req respond
    _ ->
      ingestApp pool queueName req respond

-- | Read the configured port, log a startup line, and run Warp. This blocks.
startServer :: (IOE :> es, Reader Config :> es, Log :> es) => Application -> Eff es ()
startServer app = do
  port <- asks @Config (^. #serverPort)
  logInfo ("kansoku-server listening on port " <> Text.pack (show port) <> " (GET /health, GET /openapi.json, POST /v1/events, POST /v1/batch, GET /metrics/*)")
  liftIO (Warp.run port app)
