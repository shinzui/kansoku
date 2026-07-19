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
  | UnknownIdentifierKind Text [Text]
  | EmptyIdentifierValue Text
  | IdentifierValueTooLong Text Int Int
  | IdentifierValueBadCharset Text
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
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
      [EmptyEventId | unEventId (eventId event) == ""]
        <> [EmptyEventName | unEventName (eventName event) == ""]
        <> [ ReceivedBeforeOccurred (occurredAt event) (receivedAt event)
           | receivedAt event < occurredAt event
           ]

    identifierErrors =
      case identifiers event of
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
      case lookupSchema (eventName event) registry of
        Nothing -> []
        Just schema -> concatMap validateProperty (schemaProperties schema)

    validateProperty :: PropertySpec -> [ValidationError]
    validateProperty spec =
      case KeyMap.lookup (Key.fromText (propName spec)) (properties event) of
        Nothing
          | propRequired spec -> [MissingRequiredProperty (eventName event) (propName spec)]
          | otherwise -> []
        Just value
          | propertyMatches (propType spec) value -> []
          | otherwise -> [WrongPropertyType (eventName event) (propName spec) (propType spec)]

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
  where
    renderTimestamp = Text.pack . formatTime defaultTimeLocale "%FT%T%QZ"

maxIdentifierValueLength :: Int
maxIdentifierValueLength = 256

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
