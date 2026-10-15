{-# LANGUAGE TypeApplications #-}

-- | The minimal HTTP server for EP-1: a single /health route returning 200 OK.
module Kansoku.Server
  ( ReadyProbe (..),
    bodySizeLimit,
    problemBoundary,
    envelopeFormatters,
    healthApp,
    ingestCors,
    internalMetrics,
    kansokuApp,
    kansokuAppWithChecks,
    newProbeChecks,
    kansokuServer,
    pgmqReady,
    startServer,
    waiWrapper,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as LBS
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
import Kansoku.Api.Response (ProblemDetails, badRequest, tooLarge)
import Kansoku.Api.Response qualified as Response
import Kansoku.Auth.Handler (ingestAuthHandlerWithContext, metricsAuthHandler)
import Kansoku.Auth.Store (lookupApiKey)
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Config (Config)
import Kansoku.Event.Contract (schemaCatalog)
import Kansoku.Event.Registry (defaultRegistry)
import Kansoku.Exception (catchSynchronous, trySynchronous)
import Kansoku.Health (probeApplication)
import Kansoku.Ingest.Handler (ingestServer)
import Kansoku.Ingest.Service (IngestService, ingestRequestContext, newIngestService)
import Kansoku.Logging (Log, logError, logInfo, runLogStderr)
import Kansoku.Metrics.Handler (metricsServer)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude
import Kansoku.Readiness (ReadyCheckFailure (..), checkName)
import Network.HTTP.Types (status200, status404, status413, status500, status503, statusCode)
import Network.HTTP.Types.Header (hContentType)
import Network.Wai (Application, Middleware, Response, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Internal qualified as Wai
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
import Servant.Health (ProbeCheck, ProbeVerdict (..))
import Servant.Health.Check (boolCheck, newFailureTracker, safeCheck, sequenceChecks, withProbeTimeout)
import Servant.Server (ErrorFormatter, ErrorFormatters (..), defaultErrorFormatters)
import Servant.Server.Generic (AsServerT)
import System.Timeout (timeout)

-- | Runtime checks used to answer GET /ready.
data ReadyProbe = ReadyProbe
  { writerAlive :: !(IO Bool),
    pgmqReachable :: !(IO (Either Text ())),
    clickhouseReachable :: !(IO Bool),
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

kansokuServer :: IngestService -> QueryPool -> KansokuAPI (AsServerT Handler)
kansokuServer service queryPool =
  KansokuAPI
    { ingest = ingestServer service,
      metrics = metricsServer queryPool,
      schemas = pure (schemaCatalog defaultRegistry)
    }

kansokuApp :: PipelineMetrics -> Config -> ReadyProbe -> Pool.Pool -> QueueName -> QueryPool -> IO Application
kansokuApp pipelineMetrics config probe pool queueName queryPool = do
  service <- newIngestService config pipelineMetrics pool queueName
  (liveCheck, readyCheck) <- newProbeChecks probe
  pure (kansokuAppWithChecks liveCheck readyCheck pipelineMetrics config probe pool service queryPool)

-- | Production assembly with independently injectable checks. The conformance kit
-- uses this same builder; analytics dependencies stay unevaluated for probes.
kansokuAppWithChecks :: ProbeCheck -> ProbeCheck -> PipelineMetrics -> Config -> ReadyProbe -> Pool.Pool -> IngestService -> QueryPool -> Application
kansokuAppWithChecks liveCheck readyCheck _pipelineMetrics config probe pool service queryPool =
  operational liveCheck readyCheck $
    waiWrapper
      probe
      ( internalMetrics
          (config ^. #internalMetricsEnabled)
          ( ingestCors
              (config ^. #corsAllowedOrigins)
              ( problemBoundary $
                  bodySizeLimit
                    (config ^. #ingestMaxBodyBytes)
                    ( serveWithContext
                        kansokuAPI
                        ( envelopeFormatters
                            :. ingestAuthHandlerWithContext (lookupApiKey pool) (ingestRequestContext service)
                            :. metricsAuthHandler pool
                            :. EmptyContext
                        )
                        (kansokuServer service queryPool)
                    )
              )
          )
      )

-- | Allocate independent failure-onset state once, at application startup.
newProbeChecks :: ReadyProbe -> IO (ProbeCheck, ProbeCheck)
newProbeChecks probe = do
  trackLive <- newFailureTracker
  trackReady <- newFailureTracker
  pure
    ( trackLive (withProbeTimeout 2_000_000 "liveness" (safeCheck "liveness" (getCurrentTime >> pure Healthy))),
      trackReady (withProbeTimeout 2_000_000 "readiness" (sequenceChecks (namedReadyChecks probe)))
    )

namedReadyChecks :: ReadyProbe -> [ProbeCheck]
namedReadyChecks probe =
  [ boundedCheck "writer_alive" (probe ^. #writerAlive),
    boundedCheck "pgmq_reachable" (isRight <$> (probe ^. #pgmqReachable)),
    boundedCheck "clickhouse_query_reachable" (probe ^. #clickhouseReachable),
    boundedCheck "queue_depth" (pipelineOk "queue_depth"),
    boundedCheck "writer_flush_stale" (pipelineOk "writer_flush_stale")
  ]
  where
    pipelineOk name = all ((/= name) . checkName) <$> (probe ^. #pipelineReady)

boundedCheck :: Text -> IO Bool -> ProbeCheck
boundedCheck name = withProbeTimeout 750_000 name . safeCheck name . boolCheck name

operational :: ProbeCheck -> ProbeCheck -> Middleware
operational liveCheck readyCheck inner req respond =
  case pathInfo req of
    ["health", "live"] -> probes req respond
    ["health", "ready"] -> probes req respond
    _ -> inner req respond
  where
    probes = probeApplication liveCheck readyCheck

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

-- | Apply browser CORS policy to the /v1 ingestion and public-schema family.
-- Metrics and operational endpoints remain same-origin. Auth headers are
-- pre-authorized for EP-15 so browser SDKs do not need another contract change.
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
          Cors.corsMethods = ["GET", "POST"],
          Cors.corsRequestHeaders = ["Content-Type", "X-Api-Key", "Authorization"],
          Cors.corsExposedHeaders = Just ["Retry-After"],
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
    [(hContentType, "application/problem+json")]
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
  result <- timeout 2_000_000 (trySynchronous (readyResponse probe))
  respond $ case result of
    Just (Right response) -> response
    _ ->
      responseLBS status503 [(hContentType, "application/json")] $
        Aeson.encode
          ( Aeson.object
              [ "status" Aeson..= ("unavailable" :: Text),
                "failing" Aeson..= (["readiness"] :: [Text]),
                "checks"
                  Aeson..= fmap
                    (`simpleCheck` False)
                    ["writer_alive", "pgmq_reachable", "clickhouse_query_reachable", "queue_depth", "writer_flush_stale"]
              ]
          )

readyResponse :: ReadyProbe -> IO Response
readyResponse probe = do
  isWriterAlive <- passed <$> boundedCheck "writer_alive" (probe ^. #writerAlive)
  postgresOk <- passed <$> boundedCheck "pgmq_reachable" (isRight <$> (probe ^. #pgmqReachable))
  clickhouseOk <- passed <$> boundedCheck "clickhouse_query_reachable" (probe ^. #clickhouseReachable)
  pipelineFailures <- probe ^. #pipelineReady
  let failingDependencies :: [Text]
      failingDependencies =
        ["writer" | not isWriterAlive]
          <> ["postgres" | not postgresOk]
          <> ["clickhouse" | not clickhouseOk]
          <> (checkName <$> pipelineFailures)
      checks =
        [ simpleCheck "writer_alive" isWriterAlive,
          simpleCheck "pgmq_reachable" postgresOk,
          simpleCheck "clickhouse_query_reachable" clickhouseOk,
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
  pure (responseLBS status [(hContentType, "application/json")] (Aeson.encode body))

passed :: ProbeVerdict -> Bool
passed Healthy = True
passed Unhealthy {} = False

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

-- | Make Servant's parser and routing rejections use the typed problem contract.
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

envelopeError :: ServerError -> ProblemDetails -> ServerError
envelopeError err envelope =
  err
    { errBody = Aeson.encode envelope,
      errHeaders = [(hContentType, "application/problem+json")]
    }

-- | Fill only empty framework rejections; never consume a streaming body.
-- This boundary is inside CORS so browser clients can read every failure.
problemBoundary :: Middleware
problemBoundary inner req respond =
  catchSynchronous (inner req (respond . frameworkProblem)) handle
  where
    handle err = do
      runEff . runLogStderr $ logError ("HTTP request failed: " <> Text.pack (show err))
      respond
        ( responseLBS
            status500
            [(hContentType, "application/problem+json")]
            (Aeson.encode (Response.problem 500 "internal_error" "an unexpected error occurred"))
        )
    frameworkProblem response =
      case response of
        Wai.ResponseBuilder status headers builder
          | Just code <-
              lookup
                (statusCode status)
                [(405, "method_not_allowed"), (406, "not_acceptable"), (415, "unsupported_media_type")],
            LBS.null (toLazyByteString builder) ->
              responseLBS
                status
                ((hContentType, "application/problem+json") : filter ((/= hContentType) . fst) headers)
                (Aeson.encode (Response.problem (statusCode status) code "the request is not supported by this endpoint"))
        _ -> response

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
  logInfo ("kansoku-server listening on port " <> Text.pack (show port) <> " (GET /health, GET /ready, GET /internal/metrics, GET /openapi.json, GET /v1/schemas, POST /v1/events, POST /v1/batch, GET /metrics/*)")
  liftIO (Warp.run port app)
