{-# LANGUAGE TypeApplications #-}

-- | The minimal HTTP server for EP-1: a single /health route returning 200 OK.
module Kansoku.Server
  ( ReadyProbe (..),
    bodySizeLimit,
    envelopeFormatters,
    healthApp,
    ingestCors,
    internalMetrics,
    kansokuApp,
    kansokuServer,
    pgmqReady,
    startServer,
    waiWrapper,
  )
where

import Data.Aeson qualified as Aeson
import Data.Either (isRight)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Effectful (Eff, IOE, runEff, type (:>))
import Effectful.Error.Static qualified as Error
import Effectful.Reader.Static (Reader, asks)
import Hasql.Pool qualified as Pool
import Kansoku.Api (KansokuAPI (..), kansokuAPI)
import Kansoku.Api.OpenApi (kansokuOpenApi)
import Kansoku.Api.Response (ErrorEnvelopeWire, badRequest, tooLarge)
import Kansoku.Api.Response qualified as Response
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Config (Config)
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Logging (Log, logInfo)
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.Prelude
import Kansoku.Readiness (ReadyCheckFailure (..), checkName)
import Network.HTTP.Types (status200, status404, status413, status503)
import Network.HTTP.Types.Header (hContentType)
import Network.Wai (Application, Middleware, Response, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Middleware.Cors qualified as Cors
import Network.Wai.Middleware.RequestSizeLimit qualified as SizeLimit
import Pgmq.Effectful (QueueName, queueMetrics, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Prometheus qualified
import Servant
  ( Context (..),
    Handler,
    ServerError (..),
    err400,
    err404,
    serveWithContext,
  )
import Servant.Server (ErrorFormatter, ErrorFormatters (..), defaultErrorFormatters)
import Servant.Server.Generic (AsServerT)

-- | Runtime checks used to answer GET /ready.
data ReadyProbe = ReadyProbe
  { writerAlive :: !(IO Bool),
    pgmqReachable :: !(IO (Either Text ())),
    pipelineReady :: !(IO [ReadyCheckFailure])
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

kansokuServer :: Int -> Pool.Pool -> QueueName -> QueryPool -> KansokuAPI (AsServerT Handler)
kansokuServer maxBatchLength pool queueName queryPool =
  KansokuAPI
    { ingest = ingestServer maxBatchLength pool queueName,
      metrics = metricsServer queryPool
    }

kansokuApp :: Config -> ReadyProbe -> Pool.Pool -> QueueName -> QueryPool -> Application
kansokuApp config probe pool queueName queryPool =
  waiWrapper
    probe
    ( internalMetrics
        (config ^. #internalMetricsEnabled)
        ( ingestCors
            (config ^. #corsAllowedOrigins)
            ( bodySizeLimit
                (config ^. #ingestMaxBodyBytes)
                ( serveWithContext
                    kansokuAPI
                    (envelopeFormatters :. EmptyContext)
                    (kansokuServer (config ^. #ingestMaxBatchLength) pool queueName queryPool)
                )
            )
        )
    )

-- | Serve the operational Prometheus scrape without adding it to the public
-- Servant API or OpenAPI document. This middleware sits outside the EP-14
-- ingest stack, so CORS and body limits remain scoped to ingestion.
internalMetrics :: Bool -> Middleware
internalMetrics enabled inner req respond =
  case pathInfo req of
    ["internal", "metrics"]
      | enabled -> do
          body <- Prometheus.exportMetricsAsText
          respond
            ( responseLBS
                status200
                [(hContentType, "text/plain; version=0.0.4")]
                body
            )
      | otherwise ->
          respond (responseLBS status404 [(hContentType, "text/plain")] "Not Found")
    _ -> inner req respond

-- | Apply browser CORS policy only to the ingestion route family. Metrics and
-- operational endpoints remain same-origin. Auth headers are pre-authorized
-- for EP-15 so browser SDKs do not need another contract change.
ingestCors :: Maybe [Text] -> Middleware
ingestCors allowedOrigins inner req respond =
  case pathInfo req of
    "v1" : _ -> Cors.cors (const (Just policy)) inner req respond
    _ -> inner req respond
  where
    policy =
      Cors.simpleCorsResourcePolicy
        { Cors.corsOrigins =
            (\origins -> (Text.Encoding.encodeUtf8 <$> origins, False)) <$> allowedOrigins,
          Cors.corsMethods = ["POST"],
          Cors.corsRequestHeaders = ["Content-Type", "X-Api-Key", "Authorization"],
          Cors.corsMaxAge = Just 3600
        }

-- | Bound request bodies before Servant parses them. CORS wraps this
-- middleware in 'kansokuApp', so browser callers can read the JSON 413.
bodySizeLimit :: Int -> Middleware
bodySizeLimit maxBytes =
  SizeLimit.requestSizeLimitMiddleware
    ( SizeLimit.setOnLengthExceeded
        (\_maxLength _inner _request respond -> respond (payloadTooLarge maxBytes))
        ( SizeLimit.setMaxLengthForRequest
            (\_request -> pure (Just (fromIntegral maxBytes)))
            SizeLimit.defaultRequestSizeLimitSettings
        )
    )

payloadTooLarge :: Int -> Response
payloadTooLarge maxBytes =
  responseLBS
    status413
    [(hContentType, "application/json")]
    ( Aeson.encode
        ( tooLarge
            "payload_too_large"
            ("request body exceeds the " <> Text.pack (show maxBytes) <> "-byte limit")
        )
    )

-- | Operational/meta routes stay at WAI level; all analytics routes delegate
-- to the one Servant application. Taking the inner app keeps this wrapper
-- testable without database connections.
waiWrapper :: ReadyProbe -> Application -> Application
waiWrapper probe inner req respond =
  case pathInfo req of
    ["health"] ->
      healthApp req respond
    ["ready"] ->
      readyApp probe req respond
    ["openapi.json"] ->
      respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode kansokuOpenApi))
    _ ->
      inner req respond

readyApp :: ReadyProbe -> Application
readyApp probe _req respond = do
  isWriterAlive <- probe ^. #writerAlive
  postgresResult <- probe ^. #pgmqReachable
  pipelineFailures <- probe ^. #pipelineReady
  let failingDependencies :: [Text]
      failingDependencies =
        ["writer" | not isWriterAlive]
          <> either (const ["postgres"]) (const []) postgresResult
          <> (checkName <$> pipelineFailures)
      checks =
        [ simpleCheck "writer_alive" isWriterAlive,
          simpleCheck "pgmq_reachable" (isRight postgresResult),
          pipelineCheck "queue_depth" pipelineFailures,
          pipelineCheck "writer_flush_stale" pipelineFailures
        ]
      body
        | null failingDependencies =
            Aeson.object
              [ "status" Aeson..= ("ready" :: Text),
                "checks" Aeson..= checks
              ]
        | otherwise =
            Aeson.object
              [ "status" Aeson..= ("unavailable" :: Text),
                "failing" Aeson..= failingDependencies,
                "checks" Aeson..= checks
              ]
      status
        | null failingDependencies = status200
        | otherwise = status503
  respond (responseLBS status [(hContentType, "application/json")] (Aeson.encode body))

simpleCheck :: Text -> Bool -> Aeson.Value
simpleCheck name ok = Aeson.object ["check" Aeson..= name, "ok" Aeson..= ok]

pipelineCheck :: Text -> [ReadyCheckFailure] -> Aeson.Value
pipelineCheck name failures =
  case find ((== name) . checkName) failures of
    Nothing -> simpleCheck name True
    Just failure -> renderPipelineFailure failure

renderPipelineFailure :: ReadyCheckFailure -> Aeson.Value
renderPipelineFailure = \case
  QueueDepthExceeded {observed, limit} ->
    Aeson.object
      [ "check" Aeson..= ("queue_depth" :: Text),
        "ok" Aeson..= False,
        "observed" Aeson..= observed,
        "limit" Aeson..= limit
      ]
  WriterFlushStale {lastFlushAt, ageSeconds, limitSeconds, backlog} ->
    Aeson.object
      [ "check" Aeson..= ("writer_flush_stale" :: Text),
        "ok" Aeson..= False,
        "lastFlushAt" Aeson..= lastFlushAt,
        "ageSeconds" Aeson..= ageSeconds,
        "limitSeconds" Aeson..= limitSeconds,
        "backlog" Aeson..= backlog
      ]

-- | Make Servant's pre-handler rejections use the same envelope as typed
-- handler results. Servant raises 405 and 415 outside ErrorFormatters; those
-- responses retain its empty body.
envelopeFormatters :: ErrorFormatters
envelopeFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = malformed,
      urlParseErrorFormatter = malformed,
      headerParseErrorFormatter = malformed,
      notFoundErrorFormatter = const unknownPath
    }
  where
    malformed :: ErrorFormatter
    malformed _typeRep _request detail =
      envelopeError err400 (badRequest "malformed_request" (Text.pack detail))

    unknownPath =
      envelopeError err404 (Response.notFound "not_found" "no such endpoint")

envelopeError :: ServerError -> ErrorEnvelopeWire -> ServerError
envelopeError err envelope =
  err
    { errBody = Aeson.encode envelope,
      errHeaders = [(hContentType, "application/json")]
    }

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
  logInfo ("kansoku-server listening on port " <> Text.pack (show port) <> " (GET /health, GET /ready, GET /internal/metrics, GET /openapi.json, POST /v1/events, POST /v1/batch, GET /metrics/*)")
  liftIO (Warp.run port app)
