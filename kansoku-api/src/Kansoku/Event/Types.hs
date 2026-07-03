-- | Canonical analytics event types and their JSON wire contract.
module Kansoku.Event.Types
  ( AccountId (..),
    AnalyticsEvent (..),
    AnonymousId (..),
    CausationId (..),
    CorrelationId (..),
    EventId (..),
    EventName (..),
    EventSource (..),
    OrganizationId (..),
    SessionId (..),
    SourceEventId (..),
    UserId (..),
    analyticsEventOptions,
    eventSourceToText,
  )
where

import Data.Aeson (Object, Value (String), withText)
import Data.Aeson.Types (Options (..))
import Data.Int (Int64)
import Kansoku.Prelude

-- | The origin category of an event. Exactly the six values the spec allows.
data EventSource = Web | App | Service | Worker | Email | Agent
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | Render to the exact lowercase wire strings.
eventSourceToText :: EventSource -> Text
eventSourceToText s = case s of
  Web -> "web"
  App -> "app"
  Service -> "service"
  Worker -> "worker"
  Email -> "email"
  Agent -> "agent"

instance ToJSON EventSource where
  toJSON = String . eventSourceToText

instance FromJSON EventSource where
  parseJSON = withText "EventSource" $ \t -> case t of
    "web" -> pure Web
    "app" -> pure App
    "service" -> pure Service
    "worker" -> pure Worker
    "email" -> pure Email
    "agent" -> pure Agent
    other ->
      fail
        ( "unknown event source: "
            <> show other
            <> " (expected one of web, app, service, worker, email, agent)"
        )

newtype EventId = EventId {unEventId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype EventName = EventName {unEventName :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype AnonymousId = AnonymousId {unAnonymousId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype UserId = UserId {unUserId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype OrganizationId = OrganizationId {unOrganizationId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype AccountId = AccountId {unAccountId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype SessionId = SessionId {unSessionId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype CorrelationId = CorrelationId {unCorrelationId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype CausationId = CausationId {unCausationId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

newtype SourceEventId = SourceEventId {unSourceEventId :: Text}
  deriving stock (Generic, Show)
  deriving newtype (Eq, Ord, FromJSON, ToJSON)

-- | The canonical analytics event record. Field names intentionally match the
-- JSON wire keys from docs/initial-spec.md.
data AnalyticsEvent = AnalyticsEvent
  { eventId :: !EventId,
    eventName :: !EventName,
    source :: !EventSource,
    sourceService :: !(Maybe Text),
    occurredAt :: !UTCTime,
    receivedAt :: !UTCTime,
    anonymousId :: !(Maybe AnonymousId),
    userId :: !(Maybe UserId),
    organizationId :: !(Maybe OrganizationId),
    accountId :: !(Maybe AccountId),
    sessionId :: !(Maybe SessionId),
    url :: !(Maybe Text),
    referrer :: !(Maybe Text),
    utmSource :: !(Maybe Text),
    utmMedium :: !(Maybe Text),
    utmCampaign :: !(Maybe Text),
    utmContent :: !(Maybe Text),
    utmTerm :: !(Maybe Text),
    correlationId :: !(Maybe CorrelationId),
    causationId :: !(Maybe CausationId),
    sourceEventId :: !(Maybe SourceEventId),
    sourceGlobalPosition :: !(Maybe Int64),
    properties :: !Object,
    context :: !Object
  }
  deriving stock (Generic, Eq, Show)

analyticsEventOptions :: Options
analyticsEventOptions =
  defaultOptions
    { omitNothingFields = True,
      rejectUnknownFields = False
    }

instance ToJSON AnalyticsEvent where
  toJSON = genericToJSON analyticsEventOptions

instance FromJSON AnalyticsEvent where
  parseJSON = genericParseJSON analyticsEventOptions
