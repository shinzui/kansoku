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
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import Kansoku.Event
import Kansoku.Prelude

type EventColumns =
  '[ Column "event_id" ChString,
     Column "event_name" ChString,
     Column "source" ChString,
     Column "source_service" (Maybe ChString),
     Column "occurred_at" (DateTime64 3 "UTC"),
     Column "received_at" (DateTime64 3 "UTC"),
     Column "anonymous_id" (Maybe ChString),
     Column "user_id" ChString,
     Column "organization_id" (Maybe ChString),
     Column "account_id" ChString,
     Column "session_id" (Maybe ChString),
     Column "url" (Maybe ChString),
     Column "referrer" (Maybe ChString),
     Column "utm_source" (Maybe ChString),
     Column "utm_medium" (Maybe ChString),
     Column "utm_campaign" (Maybe ChString),
     Column "utm_content" (Maybe ChString),
     Column "utm_term" (Maybe ChString),
     Column "correlation_id" (Maybe ChString),
     Column "causation_id" (Maybe ChString),
     Column "source_event_id" (Maybe ChString),
     Column "source_global_position" (Maybe UInt64),
     Column "properties" ChString,
     Column "context" ChString
   ]

data EventRow = EventRow
  { event_id :: !ByteString,
    event_name :: !ByteString,
    source :: !ByteString,
    source_service :: !(Maybe ByteString),
    occurred_at :: !UTCTime,
    received_at :: !UTCTime,
    anonymous_id :: !(Maybe ByteString),
    user_id :: !ByteString,
    organization_id :: !(Maybe ByteString),
    account_id :: !ByteString,
    session_id :: !(Maybe ByteString),
    url :: !(Maybe ByteString),
    referrer :: !(Maybe ByteString),
    utm_source :: !(Maybe ByteString),
    utm_medium :: !(Maybe ByteString),
    utm_campaign :: !(Maybe ByteString),
    utm_content :: !(Maybe ByteString),
    utm_term :: !(Maybe ByteString),
    correlation_id :: !(Maybe ByteString),
    causation_id :: !(Maybe ByteString),
    source_event_id :: !(Maybe ByteString),
    source_global_position :: !(Maybe Word64),
    properties :: !ByteString,
    context :: !ByteString
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
      source_service = textBytes <$> event ^. #sourceService,
      occurred_at = event ^. #occurredAt,
      received_at = event ^. #receivedAt,
      anonymous_id = textBytes . unAnonymousId <$> event ^. #anonymousId,
      user_id = maybe "" (textBytes . unUserId) (event ^. #userId),
      organization_id = textBytes . unOrganizationId <$> event ^. #organizationId,
      account_id = maybe "" (textBytes . unAccountId) (event ^. #accountId),
      session_id = textBytes . unSessionId <$> event ^. #sessionId,
      url = textBytes <$> event ^. #url,
      referrer = textBytes <$> event ^. #referrer,
      utm_source = textBytes <$> event ^. #utmSource,
      utm_medium = textBytes <$> event ^. #utmMedium,
      utm_campaign = textBytes <$> event ^. #utmCampaign,
      utm_content = textBytes <$> event ^. #utmContent,
      utm_term = textBytes <$> event ^. #utmTerm,
      correlation_id = textBytes . unCorrelationId <$> event ^. #correlationId,
      causation_id = textBytes . unCausationId <$> event ^. #causationId,
      source_event_id = textBytes . unSourceEventId <$> event ^. #sourceEventId,
      source_global_position = nonNegativeWord64 =<< event ^. #sourceGlobalPosition,
      properties = objectBytes (event ^. #properties),
      context = objectBytes (event ^. #context)
    }

textBytes :: Text -> ByteString
textBytes = Text.encodeUtf8

objectBytes :: Aeson.Object -> ByteString
objectBytes = LBS.toStrict . Aeson.encode . Aeson.Object

nonNegativeWord64 :: Int64 -> Maybe Word64
nonNegativeWord64 n
  | n < 0 = Nothing
  | otherwise = Just (fromIntegral n)
