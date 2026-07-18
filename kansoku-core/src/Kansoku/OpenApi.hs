{-# OPTIONS_GHC -Wno-orphans #-}

module Kansoku.OpenApi
  ( openApiDoc,
  )
where

import Data.Char (toLower)
import Data.OpenApi qualified as O
import Kansoku.Api (kansokuAPI)
import Kansoku.Api.Response (ErrorEnvelopeWire)
import Kansoku.Event
  ( AccountId,
    AnalyticsEvent,
    AnonymousId,
    CausationId,
    CorrelationId,
    EventId,
    EventName,
    EventSource,
    OrganizationId,
    SessionId,
    SourceEventId,
    UserId,
  )
import Kansoku.Ingest.Api (BatchAck, IngestAck)
import Kansoku.Metrics.Api (MetricPoint, MetricResult, TimeGrain)
import Kansoku.Prelude
import Servant.OpenApi (toOpenApi)

instance O.ToSchema AccountId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema AnalyticsEvent

instance O.ToSchema AnonymousId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema BatchAck

instance O.ToSchema CausationId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema CorrelationId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema EventId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema EventName where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema EventSource where
  declareNamedSchema =
    O.genericDeclareNamedSchema lowerEnumOptions

instance O.ToSchema ErrorEnvelopeWire

instance O.ToSchema IngestAck

instance O.ToSchema MetricPoint

instance O.ToSchema MetricResult

instance O.ToSchema OrganizationId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema SessionId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema SourceEventId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema TimeGrain where
  declareNamedSchema =
    O.genericDeclareNamedSchema lowerEnumOptions

instance O.ToParamSchema TimeGrain where
  toParamSchema =
    O.genericToParamSchema lowerEnumOptions

instance O.ToSchema UserId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

textNewtypeOptions :: O.SchemaOptions
textNewtypeOptions =
  O.defaultSchemaOptions
    { O.unwrapUnaryRecords = True
    }

lowerEnumOptions :: O.SchemaOptions
lowerEnumOptions =
  O.defaultSchemaOptions
    { O.constructorTagModifier = map toLower
    }

openApiDoc :: O.OpenApi
openApiDoc =
  toOpenApi kansokuAPI
    & O.info
    . O.title
    .~ "Kansoku Analytics API"
    & O.info
    . O.version
    .~ "1.0.0"
    & O.info
    . O.description
    ?~ "HTTP ingestion and typed metrics query API for the Kansoku analytics service."
    & O.applyTags
      [ O.Tag "ingestion" (Just "Event ingestion endpoints") Nothing,
        O.Tag "metrics" (Just "Typed metric query endpoints") Nothing
      ]
