-- | OpenTelemetry tracer bootstrap for the service.
module Kansoku.Telemetry
  ( Telemetry (..),
    makeTelemetry,
  )
where

import Kansoku.Prelude
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.Handle qualified as Handle
import OpenTelemetry.Registry qualified as Registry
import OpenTelemetry.Trace qualified as TraceSdk
import OpenTelemetry.Trace.Core qualified as OTel
import System.Environment (lookupEnv)

-- | The tracer and the matching provider shutdown action. Keeping them in one
-- handle makes the executable's lifetime bracket explicit and flushable.
data Telemetry = Telemetry
  { tracer :: !OTel.Tracer,
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
  if isNothing endpoint && isNothing exporterSelection
    then do
      provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
      pure
        Telemetry
          { tracer = tracerFrom provider,
            shutdownTelemetry = pure ()
          }
    else do
      _registered <-
        Registry.registerSpanExporterFactoryIfAbsent
          "console"
          (pure (Handle.stdoutExporter' Handle.defaultFormatter))
      provider <- TraceSdk.initializeGlobalTracerProvider
      pure
        Telemetry
          { tracer = tracerFrom provider,
            shutdownTelemetry = void (OTel.shutdownTracerProvider provider Nothing)
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
