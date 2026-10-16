-- | Pure validation for analytics events.
module Kansoku.Event.Validation
  ( ValidationError (..),
    renderValidationError,
    validationReason,
    declaredSchemaError,
    validateEvent,
    validateEventWith,
    governedTraitEligible,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Scientific qualified as Scientific
import Data.Text qualified as Text
import Data.Time.Format (defaultTimeLocale, formatTime)
import Kansoku.Event.Registry
import Kansoku.Event.Types
import Kansoku.Prelude

data ValidationError
  = EmptyEventId
  | EventIdConflict
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime
  | UnsupportedTimestamp Text UTCTime
  | InvalidSchemaVersion Int
  | UnknownSchemaVersion EventName Int [Int]
  | UnknownIdentifierKind Text [Text]
  | EmptyIdentifierValue Text
  | IdentifierValueTooLong Text Int Int
  | IdentifierValueBadCharset Text
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
  | InvalidPropertyValue EventName Text Text
  | InvalidIdentityBinding Text
  deriving stock (Generic, Eq, Show)

-- | Validate against an explicit registry. Unknown event names are allowed; the
-- registry adds stricter property checks for names it knows.
validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEventWith registry event =
  case structuralErrors <> identifierErrors <> schemaErrors <> identityErrors of
    [] -> Right event
    errs -> Left errs
  where
    structuralErrors =
      [EmptyEventId | unEventId ((event ^. #eventId)) == ""]
        <> [EmptyEventName | unEventName ((event ^. #eventName)) == ""]
        <> [ ReceivedBeforeOccurred ((event ^. #occurredAt)) ((event ^. #receivedAt))
           | (event ^. #receivedAt) < (event ^. #occurredAt)
           ]
        <> [ UnsupportedTimestamp field value
           | (field, value) <- [("occurredAt", event ^. #occurredAt), ("receivedAt", event ^. #receivedAt)],
             value < read "1970-01-01 00:00:00 UTC" || value >= read "2100-01-01 00:00:00 UTC"
           ]
        <> [ InvalidSchemaVersion version
           | Just version <- [event ^. #schemaVersion],
             not (validSchemaVersion version)
           ]

    identifierErrors =
      case (event ^. #identifiers) of
        Nothing -> []
        Just ids -> concatMap identifierError (Map.toList ids)

    identifierError (kind, value) =
      [ UnknownIdentifierKind kind allowedIdentifierKindNames
      | isNothing (identifierKindFromText kind)
      ]
        <> [EmptyIdentifierValue kind | Text.null value]
        <> [ IdentifierValueTooLong kind (Text.length value) maxIdentifierValueLength
           | Text.length value > maxIdentifierValueLength
           ]
        <> [ IdentifierValueBadCharset kind
           | not (Text.all isIdentifierValueChar value)
           ]

    schemaErrors =
      case lookupVersions ((event ^. #eventName)) registry of
        Nothing -> []
        Just _
          | not (maybe True validSchemaVersion (event ^. #schemaVersion)) -> []
          | otherwise ->
              let requested = fromMaybe 1 (event ^. #schemaVersion)
               in case lookupSchemaVersion ((event ^. #eventName)) requested registry of
                    Nothing -> [UnknownSchemaVersion ((event ^. #eventName)) requested (knownVersions ((event ^. #eventName)) registry)]
                    Just schema -> concatMap validateProperty ((schema ^. #properties))

    identityErrors = case unEventName (event ^. #eventName) of
      "alias" ->
        [ InvalidIdentityBinding field
        | (field, top) <- [("previousId", unAnonymousId <$> event ^. #anonymousId), ("newId", unUserId <$> event ^. #userId)],
          case (top, KeyMap.lookup (Key.fromText field) (event ^. #properties)) of
            (Just value, Just (String property)) -> Text.null value || value /= property
            _ -> True
        ]
      "identify" | fromMaybe 1 (event ^. #schemaVersion) == 2 -> traitIdentityErrors
      "identify_once" -> traitIdentityErrors
      "group" -> [InvalidIdentityBinding "organizationId" | maybe True (Text.null . unOrganizationId) (event ^. #organizationId)]
      _ -> []

    traitIdentityErrors = [InvalidIdentityBinding "userId" | maybe True (Text.null . unUserId) (event ^. #userId)]

    validateProperty :: PropertySpec -> [ValidationError]
    validateProperty spec =
      case KeyMap.lookup (Key.fromText ((spec ^. #name))) ((event ^. #properties)) of
        Nothing
          | (spec ^. #required) -> [MissingRequiredProperty ((event ^. #eventName)) ((spec ^. #name))]
          | otherwise -> []
        Just value
          | not (propertyMatches ((spec ^. #propertyType)) value) ->
              [WrongPropertyType ((event ^. #eventName)) ((spec ^. #name)) ((spec ^. #propertyType))]
          | not (propertyPatternMatches ((spec ^. #validationPattern)) value) ->
              [InvalidPropertyValue ((event ^. #eventName)) ((spec ^. #name)) ("expected " <> maybe "valid value" propertyPatternText (spec ^. #validationPattern))]
          | otherwise -> []

-- | Server-owned eligibility. Never infer governed state from legacy v1
-- identify data or from Float64-rounded native JSON values.
governedTraitEligible :: AnalyticsEvent -> Bool
governedTraitEligible event =
  let operation = (unEventName (event ^. #eventName), fromMaybe 1 (event ^. #schemaVersion))
   in operation `elem` [("identify", 2), ("identify_once", 1)] && case validateEvent event of
        Right _ -> True
        Left _ -> False

validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEvent = validateEventWith defaultRegistry

-- | Render a validation failure for logs and rejection responses. Callers may
-- show this text to people, but must use a rejected event's index for machine
-- correlation rather than parsing this prose.
renderValidationError :: ValidationError -> Text
renderValidationError = \case
  EmptyEventId ->
    "eventId must not be empty"
  EventIdConflict ->
    "event_id_conflict: eventId already identifies different producer content"
  EmptyEventName ->
    "eventName must not be empty"
  ReceivedBeforeOccurred occurred received ->
    "receivedAt ("
      <> renderTimestamp received
      <> ") precedes occurredAt ("
      <> renderTimestamp occurred
      <> "); occurredAt is in the future relative to the server clock"
  InvalidIdentityBinding field ->
    "invalid top-level identity binding for " <> field
  UnsupportedTimestamp field _ ->
    field <> " must be in the supported UTC range [1970-01-01, 2100-01-01)"
  InvalidSchemaVersion version ->
    "schemaVersion "
      <> Text.pack (show version)
      <> " is outside the supported range 1..65535"
  UnknownSchemaVersion name requested known ->
    "event '"
      <> unEventName name
      <> "': schemaVersion "
      <> Text.pack (show requested)
      <> " is unknown; known versions: "
      <> Text.pack (show known)
  UnknownIdentifierKind kind allowed ->
    "identifier kind '"
      <> kind
      <> "' is not supported; allowed kinds: "
      <> Text.intercalate ", " allowed
  EmptyIdentifierValue kind ->
    "identifier '" <> kind <> "' must not be empty"
  IdentifierValueTooLong kind actual maxAllowed ->
    "identifier '"
      <> kind
      <> "' is "
      <> Text.pack (show actual)
      <> " characters; maximum is "
      <> Text.pack (show maxAllowed)
  IdentifierValueBadCharset kind ->
    "identifier '"
      <> kind
      <> "' must contain only printable non-space ASCII characters"
  MissingRequiredProperty name propertyName ->
    "event '"
      <> unEventName name
      <> "': missing required property '"
      <> propertyName
      <> "'"
  WrongPropertyType name propertyName expected ->
    "event '"
      <> unEventName name
      <> "': property '"
      <> propertyName
      <> "' must be of type "
      <> renderPropertyType expected
  InvalidPropertyValue name propertyName rule ->
    "event '"
      <> unEventName name
      <> "': property '"
      <> propertyName
      <> "' has an invalid value; "
      <> rule
  where
    renderTimestamp = Text.pack . formatTime defaultTimeLocale "%FT%T%QZ"

maxIdentifierValueLength :: Int
maxIdentifierValueLength = 256

validSchemaVersion :: Int -> Bool
validSchemaVersion version = version >= 1 && version <= 65535

isIdentifierValueChar :: Char -> Bool
isIdentifierValueChar char = char > ' ' && char <= '~'

renderPropertyType :: PropertyType -> Text
renderPropertyType = \case
  PTString -> "string"
  PTNumber -> "number"
  PTBool -> "boolean"
  PTObject -> "object"
  PTArray -> "array"
  PTAny -> "any"

propertyMatches :: PropertyType -> Value -> Bool
propertyMatches expected value =
  case expected of
    PTString -> case value of
      String _ -> True
      _ -> False
    PTNumber -> case value of
      Number _ -> True
      _ -> False
    PTBool -> case value of
      Bool _ -> True
      _ -> False
    PTObject -> case value of
      Object _ -> True
      _ -> False
    PTArray -> case value of
      Array _ -> True
      _ -> False
    PTAny -> True

propertyPatternMatches :: Maybe PropertyPattern -> Value -> Bool
propertyPatternMatches Nothing _ = True
propertyPatternMatches (Just NonEmptyStringPattern) (String value) = not (Text.null value)
propertyPatternMatches (Just NonNegativeNumberPattern) (Number value) = value >= 0
propertyPatternMatches (Just NonNegativeIntegerPattern) (Number value) =
  let numeric = Scientific.toRealFloat value :: Double
   in not (isInfinite numeric || isNaN numeric) && value >= 0 && Scientific.isInteger value
propertyPatternMatches (Just SqlNamePattern) (String value) = isSqlSafeName value
propertyPatternMatches (Just _) _ = False

-- Keep this predicate aligned with Kansoku.Metrics.Query.Validate.mkSqlName.
-- It lives in kansoku-api because this package cannot depend on kansoku-core.
isSqlSafeName :: Text -> Bool
isSqlSafeName value =
  not (Text.null value)
    && Text.length value <= 128
    && Text.all allowed value
  where
    allowed char =
      isAsciiLower char
        || isDigit char
        || char `elem` ("_.:-" :: String)

-- | Finite reason codes: never derive telemetry labels from payload values.
validationReason :: ValidationError -> Text
validationReason = \case
  EmptyEventId -> "empty_event_id"
  EventIdConflict -> "event_id_conflict"
  EmptyEventName -> "empty_event_name"
  ReceivedBeforeOccurred {} -> "future_timestamp"
  UnsupportedTimestamp {} -> "unsupported_timestamp"
  InvalidSchemaVersion {} -> "invalid_schema_version"
  UnknownSchemaVersion {} -> "unknown_schema_version"
  UnknownIdentifierKind {} -> "unknown_identifier_kind"
  EmptyIdentifierValue {} -> "empty_identifier_value"
  IdentifierValueTooLong {} -> "identifier_value_too_long"
  IdentifierValueBadCharset {} -> "identifier_value_bad_charset"
  MissingRequiredProperty {} -> "missing_required_property"
  WrongPropertyType {} -> "wrong_property_type"
  InvalidPropertyValue {} -> "invalid_property_value"
  InvalidIdentityBinding {} -> "invalid_identity_binding"

declaredSchemaError :: ValidationError -> Bool
declaredSchemaError = \case
  UnknownSchemaVersion {} -> True
  InvalidSchemaVersion {} -> True
  MissingRequiredProperty {} -> True
  WrongPropertyType {} -> True
  InvalidPropertyValue {} -> True
  InvalidIdentityBinding {} -> True
  _ -> False
