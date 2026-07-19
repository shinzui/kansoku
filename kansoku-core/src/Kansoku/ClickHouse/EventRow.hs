-- | ClickHouse wire rows for the raw analytics events table.
module Kansoku.ClickHouse.EventRow
  ( CountColumns,
    CountRow (..),
    EventColumns,
    EventProjection (..),
    EventRow (..),
    ProjectionColumns,
    eventRowFromEvent,
  )
where

import ClickHaskell (ChString, ClickHaskell, Column, DateTime64, UInt64)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import Kansoku.Event
import Kansoku.Prelude

type EventColumns =
  '[ Column "event_id" ChString,
     Column "event_name" ChString,
     Column "source" ChString,
     Column "source_service" ChString,
     Column "occurred_at" (DateTime64 3 "UTC"),
     Column "received_at" (DateTime64 3 "UTC"),
     Column "anonymous_id" ChString,
     Column "user_id" ChString,
     Column "organization_id" ChString,
     Column "account_id" ChString,
     Column "session_id" ChString,
     Column "url" ChString,
     Column "referrer" ChString,
     Column "utm_source" ChString,
     Column "utm_medium" ChString,
     Column "utm_campaign" ChString,
     Column "utm_content" ChString,
     Column "utm_term" ChString,
     Column "correlation_id" ChString,
     Column "causation_id" ChString,
     Column "source_event_id" ChString,
     Column "source_global_position" (Maybe UInt64),
     Column "properties" ChString,
     Column "context" ChString,
     Column "identifiers" ChString
   ]

data EventRow = EventRow
  { event_id :: !ByteString,
    event_name :: !ByteString,
    source :: !ByteString,
    source_service :: !ByteString,
    occurred_at :: !UTCTime,
    received_at :: !UTCTime,
    anonymous_id :: !ByteString,
    user_id :: !ByteString,
    organization_id :: !ByteString,
    account_id :: !ByteString,
    session_id :: !ByteString,
    url :: !ByteString,
    referrer :: !ByteString,
    utm_source :: !ByteString,
    utm_medium :: !ByteString,
    utm_campaign :: !ByteString,
    utm_content :: !ByteString,
    utm_term :: !ByteString,
    correlation_id :: !ByteString,
    causation_id :: !ByteString,
    source_event_id :: !ByteString,
    source_global_position :: !(Maybe Word64),
    properties :: !ByteString,
    context :: !ByteString,
    identifiers :: !ByteString
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell EventColumns)

data EventProjection = EventProjection
  { event_id :: !ByteString,
    event_name :: !ByteString,
    source :: !ByteString,
    account_id :: !ByteString,
    user_id :: !ByteString
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell ProjectionColumns)

type ProjectionColumns =
  '[ Column "event_id" ChString,
     Column "event_name" ChString,
     Column "source" ChString,
     Column "account_id" ChString,
     Column "user_id" ChString
   ]

type CountColumns = '[Column "count" UInt64]

newtype CountRow = CountRow {count :: Word64}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell CountColumns)

eventRowFromEvent :: AnalyticsEvent -> EventRow
eventRowFromEvent event =
  EventRow
    { event_id = textBytes (unEventId (event ^. #eventId)),
      event_name = textBytes (unEventName (event ^. #eventName)),
      source = textBytes (eventSourceToText (event ^. #source)),
      source_service = maybe "" textBytes (event ^. #sourceService),
      occurred_at = event ^. #occurredAt,
      received_at = event ^. #receivedAt,
      anonymous_id = maybe "" (textBytes . unAnonymousId) (event ^. #anonymousId),
      user_id = maybe "" (textBytes . unUserId) (event ^. #userId),
      organization_id = maybe "" (textBytes . unOrganizationId) (event ^. #organizationId),
      account_id = maybe "" (textBytes . unAccountId) (event ^. #accountId),
      session_id = maybe "" (textBytes . unSessionId) (event ^. #sessionId),
      url = maybe "" textBytes (event ^. #url),
      referrer = maybe "" textBytes (event ^. #referrer),
      utm_source = maybe "" textBytes (event ^. #utmSource),
      utm_medium = maybe "" textBytes (event ^. #utmMedium),
      utm_campaign = maybe "" textBytes (event ^. #utmCampaign),
      utm_content = maybe "" textBytes (event ^. #utmContent),
      utm_term = maybe "" textBytes (event ^. #utmTerm),
      correlation_id = maybe "" (textBytes . unCorrelationId) (event ^. #correlationId),
      causation_id = maybe "" (textBytes . unCausationId) (event ^. #causationId),
      source_event_id = maybe "" (textBytes . unSourceEventId) (event ^. #sourceEventId),
      source_global_position = nonNegativeWord64 =<< event ^. #sourceGlobalPosition,
      properties = objectBytes (event ^. #properties),
      context = objectBytes (event ^. #context),
      identifiers = maybe "{}" identifiersBytes (event ^. #identifiers)
    }

textBytes :: Text -> ByteString
textBytes = Text.encodeUtf8

objectBytes :: Aeson.Object -> ByteString
objectBytes = LBS.toStrict . Aeson.encode . Aeson.Object

identifiersBytes :: Map Text Text -> ByteString
identifiersBytes = LBS.toStrict . Aeson.encode

nonNegativeWord64 :: Int64 -> Maybe Word64
nonNegativeWord64 n
  | n < 0 = Nothing
  | otherwise = Just (fromIntegral n)
