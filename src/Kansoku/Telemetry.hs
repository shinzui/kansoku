-- | OpenTelemetry tracer bootstrap for the service.
module Kansoku.Telemetry
  ( makeTracer,
  )
where

import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Trace.Core qualified as OTel

makeTracer :: IO OTel.Tracer
makeTracer = do
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  pure (OTel.makeTracer provider instrumentationLib OTel.tracerOptions)
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "kansoku",
          OTel.libraryVersion = "0.1.0.0",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }
