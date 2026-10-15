-- | Pure validation for analytics events.
module Kansoku.Event.Validation
  ( ValidationError (..),
    renderValidationError,
    validateEvent,
    validateEventWith,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Format (defaultTimeLocale, formatTime)
import Kansoku.Event.Registry
import Kansoku.Event.Types
import Kansoku.Prelude

data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime
  | InvalidSchemaVersion Int
  | UnknownSchemaVersion EventName Int [Int]
  | UnknownIdentifierKind Text [Text]
  | EmptyIdentifierValue Text
  | IdentifierValueTooLong Text Int Int
  | IdentifierValueBadCharset Text
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
  | InvalidPropertyValue EventName Text Text
  deriving stock (Generic, Eq, Show)

-- | Validate against an explicit registry. Unknown event names are allowed; the
-- registry adds stricter property checks for names it knows.
validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEventWith registry event =
  case structuralErrors <> identifierErrors <> schemaErrors of
    [] -> Right event
    errs -> Left errs
  where
    structuralErrors =
      [EmptyEventId | unEventId ((event ^. #eventId)) == ""]
        <> [EmptyEventName | unEventName ((event ^. #eventName)) == ""]
        <> [ ReceivedBeforeOccurred ((event ^. #occurredAt)) ((event ^. #receivedAt))
           | (event ^. #receivedAt) < (event ^. #occurredAt)
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
              [InvalidPropertyValue ((event ^. #eventName)) ((spec ^. #name)) sqlNamePatternRule]
          | otherwise -> []

validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEvent = validateEventWith defaultRegistry

-- | Render a validation failure for logs and rejection responses. Callers may
-- show this text to people, but must use a rejected event's index for machine
-- correlation rather than parsing this prose.
renderValidationError :: ValidationError -> Text
renderValidationError = \case
  EmptyEventId ->
    "eventId must not be empty"
  EmptyEventName ->
    "eventName must not be empty"
  ReceivedBeforeOccurred occurred received ->
    "receivedAt ("
      <> renderTimestamp received
      <> ") precedes occurredAt ("
      <> renderTimestamp occurred
      <> "); occurredAt is in the future relative to the server clock"
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
propertyPatternMatches (Just SqlNamePattern) (String value) = isSqlSafeName value
propertyPatternMatches (Just SqlNamePattern) _ = False

sqlNamePatternRule :: Text
sqlNamePatternRule = "expected " <> propertyPatternText SqlNamePattern

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
