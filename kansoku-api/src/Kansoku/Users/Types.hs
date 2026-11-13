-- | Public, deliberately small identified-user read models.
module Kansoku.Users.Types where

import Data.Aeson (Value)
import Data.Aeson qualified
import Data.Map.Strict (Map)
import Kansoku.Prelude

data UserSummary = UserSummary
  { userId :: !Text,
    traits :: !(Map Text Value),
    firstActivityAt :: !(Maybe Text),
    lastActivityAt :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

data UserActivityCounts = UserActivityCounts {identified :: !Integer, anonymous :: !Integer}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

data TraitObservation = TraitObservation {value :: !Value, observedAt :: !Text, operation :: !Text}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

data UserOrganization = UserOrganization {organizationId :: !Text, traits :: !(Map Text Value)}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

data UserProfile = UserProfile
  { userId :: !Text,
    traits :: !(Map Text TraitObservation),
    firstActivityAt :: !(Maybe Text),
    lastActivityAt :: !(Maybe Text),
    retainedEventCount :: !Integer,
    identityEvidence :: !(Map Text Integer),
    resolvedAnonymousCount :: !Integer,
    organization :: !(Maybe UserOrganization)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

-- | Receipt time is cursor state only and is never serialized as a node field.
data UserEvent = UserEvent
  { eventId :: !Text,
    eventName :: !Text,
    occurredAt :: !Text,
    source :: !Text,
    sourceService :: !Text,
    sessionId :: !Text,
    host :: !(Maybe Text),
    path :: !(Maybe Text),
    isPageView :: !Bool,
    properties :: !(Map Text Value),
    eventReceivedAt :: !Text
  }
  deriving stock (Generic, Eq, Show)

instance ToJSON UserEvent where
  toJSON UserEvent {eventId, eventName, occurredAt, source, sourceService, sessionId, host, path, isPageView, properties} =
    Data.Aeson.object ["eventId" Data.Aeson..= eventId, "eventName" Data.Aeson..= eventName, "occurredAt" Data.Aeson..= occurredAt, "source" Data.Aeson..= source, "sourceService" Data.Aeson..= sourceService, "sessionId" Data.Aeson..= sessionId, "host" Data.Aeson..= host, "path" Data.Aeson..= path, "isPageView" Data.Aeson..= isPageView, "properties" Data.Aeson..= properties]

instance FromJSON UserEvent where
  parseJSON = Data.Aeson.withObject "user event" $ \o ->
    UserEvent
      <$> o Data.Aeson..: "eventId"
      <*> o Data.Aeson..: "eventName"
      <*> o Data.Aeson..: "occurredAt"
      <*> o Data.Aeson..: "source"
      <*> o Data.Aeson..: "sourceService"
      <*> o Data.Aeson..: "sessionId"
      <*> o Data.Aeson..:? "host"
      <*> o Data.Aeson..:? "path"
      <*> o Data.Aeson..: "isPageView"
      <*> o Data.Aeson..: "properties"
      <*> pure ""
