-- | Pure validation for analytics events.
module Kansoku.Event.Validation
  ( ValidationError (..),
    validateEvent,
    validateEventWith,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Kansoku.Event.Registry
import Kansoku.Event.Types
import Kansoku.Prelude

data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
  deriving stock (Generic, Eq, Show)

-- | Validate against an explicit registry. Unknown event names are allowed; the
-- registry adds stricter property checks for names it knows.
validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEventWith registry event =
  case structuralErrors <> schemaErrors of
    [] -> Right event
    errs -> Left errs
  where
    structuralErrors =
      [EmptyEventId | unEventId (eventId event) == ""]
        <> [EmptyEventName | unEventName (eventName event) == ""]
        <> [ ReceivedBeforeOccurred (occurredAt event) (receivedAt event)
           | receivedAt event < occurredAt event
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
