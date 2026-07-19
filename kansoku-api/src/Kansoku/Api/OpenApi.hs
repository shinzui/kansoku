{-# OPTIONS_GHC -Wno-orphans #-}

module Kansoku.Api.OpenApi
  ( kansokuOpenApi,
  )
where

import Data.Char (toLower, toUpper)
import Data.OpenApi qualified as O
import Data.Text qualified as Text
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

kansokuOpenApi :: O.OpenApi
kansokuOpenApi =
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
    & withOperationIds

-- | Assign deterministic operation identifiers from method and path. They are
-- derived rather than authored, so a path rename intentionally changes the id.
-- Existing explicit identifiers always win.
withOperationIds :: O.OpenApi -> O.OpenApi
withOperationIds =
  O.paths %~ imap setForPath
  where
    setForPath path item =
      item
        & O.get
        . _Just
        . O.operationId
        %~ orSet ("get" <> key)
        & O.post
        . _Just
        . O.operationId
        %~ orSet ("post" <> key)
      where
        key = camel path

    orSet identifier = Just . fromMaybe identifier

-- | Turn @/metrics/feature-adoption@ into @MetricsFeatureAdoption@.
-- Capture braces are separators, so future captures remain stable identifier
-- fragments without punctuation.
camel :: FilePath -> Text
camel =
  Text.concat . fmap capitalize . filter (not . Text.null) . Text.split isSeparator . Text.pack
  where
    isSeparator char = char `elem` ("/-{}" :: String)
    capitalize segment =
      case Text.uncons segment of
        Just (first, rest) -> Text.cons (toUpper first) rest
        Nothing -> segment
