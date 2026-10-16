{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Kansoku.Api.OpenApi
  ( kansokuOpenApi,
  )
where

import Data.Char (toLower, toUpper)
import Data.OpenApi qualified as O
import Data.OpenApi.Declare (runDeclare)
import Data.Text qualified as Text
import Kansoku.Api (kansokuAPI)
import Kansoku.Api.Response (ProblemDetails, problemFieldName)
import Kansoku.Cohort.Types
import Kansoku.Event
  ( AccountId,
    AnalyticsEvent,
    AnonymousId,
    CausationId,
    ContractProperty,
    CorrelationId,
    EventId,
    EventName,
    EventSource,
    EventVersions,
    OrganizationId,
    SchemaCatalog,
    SessionId,
    SourceEventId,
    UserId,
    VersionedEventSchema,
  )
import Kansoku.Ingest.Api (BatchAck, BeaconEnvelope, IngestAck, IngestEvent, RejectedEvent)
import Kansoku.Metrics.Api (AcquisitionMeasure, AggregateBy, CohortMode, ExperimentMeasure, FunnelAttribution, FunnelCounting, FunnelMeasure, FunnelMode, MetricPoint, MetricResult, OrganizationAttribution, PathBy, RetentionMode, SessionMeasure, TimeGrain, UserWindow)
import Kansoku.Metrics.Definition
import Kansoku.Metrics.Filter (FilterOp, MetricFilter)
import Kansoku.Metrics.Limits (maxMetricPoints)
import Kansoku.Prelude
import Relay.Pagination.Servant.OpenApi ()
import Servant.API (type (:>))
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.OpenApi (HasOpenApi, toOpenApi)

instance (HasOpenApi sub) => HasOpenApi (AuthProtect "kansoku-ingest" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy @sub)
      & addSecurity "writeKey" [(401, "Missing, malformed, unknown, or revoked credential"), (503, "Storage or credential store unavailable")]

instance (HasOpenApi sub) => HasOpenApi (AuthProtect "kansoku-metrics" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy @sub)
      & addSecurity
        "serviceToken"
        [ (401, "Missing, malformed, unknown, or revoked credential"),
          (403, "A valid credential lacks metrics-read permission"),
          (503, "Storage or credential store unavailable")
        ]

instance (HasOpenApi sub) => HasOpenApi (AuthProtect "kansoku-beacon" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy @sub)
      & addProblemResponses [(401, "Unknown or revoked body write key"), (403, "Service credentials cannot use beacon"), (503, "Storage or credential store unavailable")]
      & O.allOperations
      . O.description
      ?~ "Body-authenticated public write key only. Rejects competing Authorization or X-Api-Key headers and duplicate envelope keys. text/plain supports browser sendBeacon without preflight; queueing is not server acknowledgement."

instance O.ToSchema BeaconEnvelope

instance O.ToSchema AccountId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema IngestEvent where
  declareNamedSchema _ = O.declareNamedSchema (Proxy @AnalyticsEvent)

instance O.ToSchema AnalyticsEvent

instance O.ToSchema AnonymousId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema BatchAck

instance O.ToSchema CausationId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema ContractProperty where
  declareNamedSchema =
    O.genericDeclareNamedSchema contractPropertySchemaOptions

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

instance O.ToSchema EventVersions

instance O.ToSchema ProblemDetails where
  declareNamedSchema = O.genericDeclareNamedSchema O.defaultSchemaOptions {O.fieldLabelModifier = problemFieldName}

instance O.ToSchema IngestAck

instance O.ToSchema RejectedEvent

instance O.ToParamSchema MetricFilter where
  toParamSchema _ =
    O.toParamSchema (Proxy @Text)
      & O.description
      ?~ "A URL-decoded JSON term or {or:[term,...]} (1..8 non-nested terms), or shorthand dimension:op:value terms separated by | for OR. Repeat filter for AND (at most 8 groups, 16384 total decoded bytes). Literal | in values requires JSON. Operators: eq, neq, in, contains, gt, lt, set, unset; set/unset omit value."

instance O.ToSchema MetricPoint where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    let nullableText = mempty & O.type_ ?~ O.OpenApiTypeArray [O.OpenApiString, O.OpenApiNull]
        groupSchema =
          mempty
            & O.type_
            ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.additionalProperties
            ?~ O.AdditionalPropertiesSchema (O.Inline nullableText)
            & O.description
            ?~ "Full dimension names map to scalar text or null. Empty string and null are distinct."
    pure
      ( named
          & O.schema
          . O.properties
          . at "group"
          ?~ O.Inline groupSchema
          & O.schema
          . O.properties
          . at "bucket"
          ?~ O.Inline nullableText
      )

instance O.ToSchema MetricResult where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure $
      named
        & O.schema
        . O.description
        ?~ "A complete aggregate answer with at most 10000 points. Larger answers return the permanent metric_result_too_large problem; no partial result or cursor pages are returned."
        & O.schema
        . O.properties
        . ix "points"
        %~ \case
          O.Inline schema -> O.Inline (schema & O.maxItems ?~ toInteger maxMetricPoints)
          reference -> reference

instance O.ToSchema OrganizationId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema SchemaCatalog

instance O.ToSchema SessionId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema SourceEventId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema TimeGrain where
  declareNamedSchema =
    O.genericDeclareNamedSchema lowerEnumOptions

instance O.ToParamSchema AcquisitionMeasure where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["sessions", "users"]

instance O.ToParamSchema SessionMeasure where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["count", "bounce_rate", "average_duration_seconds"]

instance O.ToParamSchema AggregateBy where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["users", "organizations"]

instance O.ToParamSchema OrganizationAttribution where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["event", "user_organization"]

instance O.ToParamSchema UserWindow where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["calendar", "rolling7", "rolling30"]

instance O.ToParamSchema RetentionMode where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["on", "on_or_after"]

instance O.ToParamSchema PathBy where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["event", "route"]

instance O.ToParamSchema FunnelMode where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["sequential", "strict", "any_order"]

instance O.ToParamSchema FunnelCounting where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["uniques", "totals"]

instance O.ToParamSchema FunnelAttribution where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ (["first_touch", "last_touch"] <> [toJSON ("step:" <> Text.pack (show n)) | n <- [1 .. 20 :: Int]])

instance O.ToParamSchema FunnelMeasure where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["count", "time_to_convert"]

instance O.ToParamSchema ExperimentMeasure where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["exposures", "diagnostics"]

instance O.ToParamSchema CohortMode where
  toParamSchema _ = O.toParamSchema (Proxy @Text) & O.enum_ ?~ ["window", "lifetime"]

instance O.ToParamSchema TimeGrain where
  toParamSchema =
    O.genericToParamSchema lowerEnumOptions

instance O.ToSchema UserId where
  declareNamedSchema =
    O.genericDeclareNamedSchema textNewtypeOptions

instance O.ToSchema VersionedEventSchema

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

contractPropertySchemaOptions :: O.SchemaOptions
contractPropertySchemaOptions =
  O.defaultSchemaOptions
    { O.fieldLabelModifier = \case
        "propertyType" -> "type"
        "validationPattern" -> "pattern"
        field -> field
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
    ?~ "HTTP ingestion, public event schemas, and typed metrics query API for the Kansoku analytics service."
    & O.components
    . O.securitySchemes
    .~ authSecuritySchemes
    & O.applyTags
      [ O.Tag "ingestion" (Just "Event ingestion endpoints") Nothing,
        O.Tag "metrics" (Just "Typed metric query endpoints") Nothing,
        O.Tag "schemas" (Just "Published event schema contracts") Nothing
      ]
    & addProblemResponses [(405, "Method not allowed"), (406, "Not acceptable"), (413, "Payload too large"), (500, "Internal server error")]
    & withUnsupportedBodyMedia
    & withRetryAfterHeader
    & withOperationIds

authSecuritySchemes :: O.SecurityDefinitions
authSecuritySchemes =
  O.SecurityDefinitions
    ( mempty
        & at "writeKey"
        ?~ O.SecurityScheme
          (O.SecuritySchemeApiKey (O.ApiKeyParams "X-Api-Key" O.ApiKeyHeader))
          (Just "Kansoku write key (`ksk_w_…`) or service token; Bearer transport is also accepted.")
        & at "serviceToken"
        ?~ O.SecurityScheme
          (O.SecuritySchemeHttp (O.HttpSchemeBearer Nothing))
          (Just "Kansoku service token (`ksk_s_…`); `X-Api-Key` transport is also accepted.")
    )

addSecurity :: Text -> [(Int, Text)] -> O.OpenApi -> O.OpenApi
addSecurity schemeName responses document =
  addProblemResponses
    responses
    ( document
        & O.allOperations
        . O.security
        .~ [O.SecurityRequirement (mempty & at schemeName ?~ [])]
    )

-- | Pre-handler and typed failures share one schema reference and media type.
addProblemResponses :: [(Int, Text)] -> O.OpenApi -> O.OpenApi
addProblemResponses responses document =
  foldr addResponse (document & O.components . O.schemas %~ (<> definitions)) responses
  where
    (definitions, problemSchema) = runDeclare (O.declareSchemaRef (Proxy @ProblemDetails)) mempty
    addResponse (status, responseDescription) =
      O.allOperations
        . at (fromIntegral status)
        ?~ problemResponse problemSchema status responseDescription

problemResponse :: O.Referenced O.Schema -> Int -> Text -> O.Referenced O.Response
problemResponse problemSchema status responseDescription =
  O.Inline
    ( mempty
        & O.description
        .~ responseDescription
        & O.content
        . at "application/problem+json"
        ?~ (mempty & O.schema ?~ problemSchema)
        & O.headers
        .~ ( if status == 401
               then mempty & at "WWW-Authenticate" ?~ O.Inline (mempty & O.description ?~ "Bearer authentication challenge" & O.required ?~ True & O.schema ?~ O.Inline (O.toSchema (Proxy @Text)))
               else mempty
           )
    )

withUnsupportedBodyMedia :: O.OpenApi -> O.OpenApi
withUnsupportedBodyMedia document =
  document & O.allOperations %~ \operation ->
    if isJust (operation ^. O.requestBody)
      then operation & at 415 ?~ problemResponse problemSchema 415 "Unsupported media type"
      else operation
  where
    (_, problemSchema) = runDeclare (O.declareSchemaRef (Proxy @ProblemDetails)) mempty

-- MultiVerb emits this header on every typed 429. Mark it required explicitly
-- while preserving the generated response/body and leaving public schemas alone.
withRetryAfterHeader :: O.OpenApi -> O.OpenApi
withRetryAfterHeader document =
  document & O.allOperations %~ \operation ->
    case operation ^. at 429 of
      Just (O.Inline response) ->
        operation
          & at 429
          ?~ O.Inline
            ( response
                & O.headers
                . at "Retry-After"
                ?~ O.Inline
                  (mempty & O.description ?~ "Positive whole seconds before retrying" & O.required ?~ True & O.schema ?~ O.Inline (O.toSchema (Proxy @Int)))
            )
      _ -> operation

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
        & O.put
        . _Just
        . O.operationId
        %~ orSet ("put" <> key)
        & O.delete
        . _Just
        . O.operationId
        %~ orSet ("delete" <> key)
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

instance O.ToSchema CohortCondition where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure (named & O.schema . O.required %~ filter (/= "filters") & O.schema . O.properties . ix "withinDays" %~ boundedInteger 1 365)
    where
      boundedInteger low high = \case
        O.Inline schema -> O.Inline (schema & O.minimum_ ?~ low & O.maximum_ ?~ high)
        reference -> reference

instance O.ToSchema CohortDefinition where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure
      ( named
          & O.schema
          . O.required
          %~ filter (`notElem` ["conditions", "traits"])
          & O.schema
          . O.properties
          . ix "kind"
          %~ (\case O.Inline schema -> O.Inline (schema & O.enum_ ?~ ["behavioural", "static"]); reference -> reference)
          & O.schema
          . O.properties
          . ix "conditions"
          %~ (\case O.Inline schema -> O.Inline (schema & O.maxItems ?~ 4); reference -> reference)
      )

instance O.ToSchema Cohort

instance O.ToSchema CohortMembers where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure (named & O.schema . O.properties . ix "userIds" %~ (\case O.Inline schema -> O.Inline (schema & O.maxItems ?~ 50000); reference -> reference))

instance O.ToSchema CohortSize

instance O.ToSchema MetricFilter where
  declareNamedSchema _ = do
    operator <- O.declareSchemaRef (Proxy @FilterOp)
    let term =
          mempty
            & O.type_
            ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.required
            .~ ["dimension", "op"]
            & O.properties
            .~ (mempty & at "dimension" ?~ O.Inline (O.toSchema (Proxy @Text)) & at "op" ?~ operator & at "value" ?~ O.Inline mempty)
            & O.additionalProperties
            ?~ O.AdditionalPropertiesAllowed False
        alternatives =
          mempty
            & O.type_
            ?~ O.OpenApiTypeSingle O.OpenApiArray
            & O.minItems
            ?~ 1
            & O.maxItems
            ?~ 8
            & O.items
            ?~ O.OpenApiItemsObject (O.Inline term)
        group =
          mempty
            & O.type_
            ?~ O.OpenApiTypeSingle O.OpenApiObject
            & O.required
            .~ ["or"]
            & O.properties
            .~ (mempty & at "or" ?~ O.Inline alternatives)
            & O.additionalProperties
            ?~ O.AdditionalPropertiesAllowed False
    pure (O.NamedSchema (Just "MetricFilter") (mempty & O.oneOf ?~ [O.Inline term, O.Inline group]))

instance O.ToSchema FilterOp where
  declareNamedSchema _ = pure (O.NamedSchema (Just "FilterOp") (O.toSchema (Proxy @Text) & O.enum_ ?~ ["eq", "neq", "in", "contains", "gt", "lt", "set", "unset"]))

instance O.ToSchema Aggregation where
  declareNamedSchema = O.genericDeclareNamedSchema O.defaultSchemaOptions {O.constructorTagModifier = \case "UniqueCount" -> "unique_count"; x -> map toLower x}

instance O.ToSchema MetricDefinition where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure (named & O.schema . O.description ?~ "Simple custom metric: name has 1..200 characters; eventNames has 1..100 validated names; aggregation is count, unique_count, sum or average. Sum/average require a numeric aggregationProperty declared across every listed event. Filters are grammar strings: at most eight AND groups, each with up to eight OR terms and 16384 decoded UTF-8 bytes combined with request filters. groupBy uses up to two distinct full dimension names. Day is the default grain; request grouping/grain override saved defaults. No SQL is accepted.")

instance O.ToSchema RatioMetric where
  declareNamedSchema proxy = do
    named <- O.genericDeclareNamedSchema O.defaultSchemaOptions proxy
    pure (named & O.schema . O.description ?~ "Ratio of two simple definitions; component grouping must be empty and timeGrain null. Each side supports count, unique_count, sum or average and its own filters. Request filters apply to both sides within each population's eight-group/16384-byte budget. Ratios are unbucketed, reject event-property grouping and return zero for a zero denominator. Names are labels, never builtin dispatch keys.")

instance O.ToSchema SavedMetric

instance O.ToSchema CustomDefinition where
  declareNamedSchema _ = do
    simple <- O.declareSchemaRef (Proxy @MetricDefinition)
    ratio <- O.declareSchemaRef (Proxy @RatioMetric)
    pure (O.NamedSchema (Just "CustomDefinition") (mempty & O.oneOf ?~ [simple, ratio]))
