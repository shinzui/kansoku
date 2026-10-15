-- | OpenTelemetry tracer bootstrap for the service.
module Kansoku.Telemetry
  ( Telemetry (..),
    makeTelemetry,
    makeHttpMiddleware,
    makeHttpMiddlewareWithSink,
  )
where

import Control.Exception (onException)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Lazy qualified as LazyText
import Data.Text.Lazy.Encoding qualified as LazyEncoding
import Kansoku.Api (kansokuAPI)
import Kansoku.Health (operationalApi)
import Kansoku.Prelude
import Kansoku.RequestLog (requestLogger, stdoutSink)
import Network.Wai (Middleware, Request (..))
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.Handle qualified as Handle
import OpenTelemetry.Instrumentation.Servant (openTelemetryServantMiddleware)
import OpenTelemetry.Instrumentation.Wai qualified as WaiOTel
import OpenTelemetry.Metric qualified as Metric
import OpenTelemetry.Metric.Core qualified as MetricCore
import OpenTelemetry.Registry qualified as Registry
import OpenTelemetry.Trace qualified as TraceSdk
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as Id
import System.Environment (lookupEnv)

-- | The tracer and the matching provider shutdown action. Keeping them in one
-- handle makes the executable's lifetime bracket explicit and flushable.
data Telemetry = Telemetry
  { tracer :: !OTel.Tracer,
    httpMiddleware :: !Middleware,
    shutdownTelemetry :: !(IO ())
  }
  deriving stock (Generic)

-- | Initialize real export only when an exporter is configured. The SDK's
-- no-variable default is OTLP on localhost:4318, which would be surprising in
-- development, so the previous drop-all provider remains the zero-config path.
makeTelemetry :: IO Telemetry
makeTelemetry = do
  endpoint <- lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
  exporterSelection <- lookupEnv "OTEL_TRACES_EXPORTER"
  metricsSelection <- lookupEnv "OTEL_METRICS_EXPORTER"
  provider <-
    if isNothing endpoint && isNothing exporterSelection
      then do
        noExport <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
        OTel.setGlobalTracerProvider noExport
        pure noExport
      else do
        _registered <-
          Registry.registerSpanExporterFactoryIfAbsent
            "console"
            (pure (Handle.stdoutExporter' consoleFormatter))
        TraceSdk.initializeGlobalTracerProvider
  meter <-
    ( if isNothing metricsSelection
        then Metric.setGlobalMeterProvider Metric.noopMeterProvider >> pure Metric.noopMeterProvider
        else Metric.initializeGlobalMeterProvider
    )
      `onException` void (OTel.shutdownTracerProvider provider Nothing)
  middleware <-
    makeHttpMiddleware provider `onException` do
      void (Metric.shutdownMeterProvider meter Nothing)
      void (OTel.shutdownTracerProvider provider Nothing)
  pure
    Telemetry
      { tracer = tracerFrom provider,
        httpMiddleware = middleware,
        shutdownTelemetry = do
          void (OTel.forceFlushTracerProvider provider Nothing)
          void (Metric.forceFlushMeterProvider meter Nothing)
          void (Metric.shutdownMeterProvider meter Nothing)
          void (OTel.shutdownTracerProvider provider Nothing)
      }
  where
    tracerFrom provider = OTel.makeTracer provider instrumentationLib OTel.tracerOptions

    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "kansoku",
          OTel.libraryVersion = "0.1.0.0",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }

-- | Only this wrapped middleware is exposed for production assembly. The WAI
-- instrumentation sees no query values; handlers retain the complete original
-- request and the instrumented request's context vault. The response closure
-- in the dependency also captures the sanitized request.
makeHttpMiddleware :: OTel.TracerProvider -> IO Middleware
makeHttpMiddleware provider = makeHttpMiddlewareWithSink provider stdoutSink

makeHttpMiddlewareWithSink :: OTel.TracerProvider -> (BS.ByteString -> IO ()) -> IO Middleware
makeHttpMiddlewareWithSink provider sink = do
  meterProvider <- MetricCore.getGlobalMeterProvider
  meter <- MetricCore.getMeter meterProvider "kansoku-http"
  instrumentation <- WaiOTel.newOpenTelemetryWaiMiddleware' provider meter
  pure $ \app original respond ->
    let bounded n = encodeUtf8 . decodeUtf8With lenientDecode . BS.take n
        allowed = ["host", "user-agent", "traceparent", "tracestate"]
        cleanHeader (name, value) = (name, bounded (if name == "user-agent" then 512 else 2048) value)
        sanitized =
          original
            { rawQueryString = "",
              queryString = [],
              rawPathInfo = bounded 2048 (rawPathInfo original),
              requestHeaders = fmap cleanHeader (filter ((`elem` allowed) . fst) (requestHeaders original))
            }
        restore instrumented = original {vault = vault instrumented}
        annotations =
          openTelemetryServantMiddleware provider kansokuAPI
            . openTelemetryServantMiddleware provider operationalApi
     in instrumentation (\instrumented -> annotations (requestLogger sink app) (restore instrumented)) sanitized respond

-- The default handle formatter prints only names/IDs. Export the complete bounded
-- snapshot so collector-free acceptance can inspect attributes, events and status.
consoleFormatter :: OTel.ImmutableSpan -> IO LazyText.Text
consoleFormatter span' = do
  hot <- readIORef (OTel.spanHot span')
  let context = OTel.spanContext span'
  pure . LazyEncoding.decodeUtf8 . Aeson.encode $
    Aeson.object
      [ "kind" Aeson..= ("span" :: Text),
        "name" Aeson..= OTel.hotName hot,
        "trace_id" Aeson..= Id.traceIdBaseEncodedText Id.Base16 (OTel.traceId context),
        "span_id" Aeson..= Id.spanIdBaseEncodedText Id.Base16 (OTel.spanId context),
        "attributes" Aeson..= show (OTel.hotAttributes hot),
        "events" Aeson..= show (OTel.hotEvents hot),
        "status" Aeson..= show (OTel.hotStatus hot)
      ]
