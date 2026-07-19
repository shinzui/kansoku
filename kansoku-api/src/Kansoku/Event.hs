-- | Public event API.
--
-- Identity stitching uses ordinary analytics events named @identify@, @alias@,
-- and @group@. The smart constructors here reserve those names and fill the
-- rest of the event with empty optional fields.
module Kansoku.Event
  ( module Kansoku.Event.Registry,
    module Kansoku.Event.Types,
    module Kansoku.Event.Validation,
    aliasEvent,
    baseEvent,
    groupEvent,
    identifyEvent,
  )
where

import Data.Aeson (Object)
import Data.Generics.Labels ()
import Kansoku.Event.Registry
import Kansoku.Event.Types
import Kansoku.Event.Validation
import Kansoku.Prelude

identifyEvent ::
  EventId ->
  EventSource ->
  UTCTime ->
  UTCTime ->
  Maybe AnonymousId ->
  Maybe UserId ->
  Object ->
  AnalyticsEvent
identifyEvent eid src occ recv anonId usr traits =
  baseEvent eid (EventName "identify") src occ recv
    & #anonymousId
    .~ anonId
    & #userId
    .~ usr
    & #properties
    .~ traits

aliasEvent ::
  EventId ->
  EventSource ->
  UTCTime ->
  UTCTime ->
  Maybe AnonymousId ->
  Maybe UserId ->
  Object ->
  AnalyticsEvent
aliasEvent eid src occ recv anonId usr properties =
  baseEvent eid (EventName "alias") src occ recv
    & #anonymousId
    .~ anonId
    & #userId
    .~ usr
    & #properties
    .~ properties

groupEvent ::
  EventId ->
  EventSource ->
  UTCTime ->
  UTCTime ->
  Maybe UserId ->
  Maybe OrganizationId ->
  Object ->
  AnalyticsEvent
groupEvent eid src occ recv usr org properties =
  baseEvent eid (EventName "group") src occ recv
    & #userId
    .~ usr
    & #organizationId
    .~ org
    & #properties
    .~ properties

baseEvent :: EventId -> EventName -> EventSource -> UTCTime -> UTCTime -> AnalyticsEvent
baseEvent eid name src occ recv =
  AnalyticsEvent
    { eventId = eid,
      eventName = name,
      source = src,
      sourceService = Nothing,
      occurredAt = occ,
      receivedAt = recv,
      anonymousId = Nothing,
      userId = Nothing,
      identifiers = Nothing,
      organizationId = Nothing,
      accountId = Nothing,
      sessionId = Nothing,
      url = Nothing,
      referrer = Nothing,
      utmSource = Nothing,
      utmMedium = Nothing,
      utmCampaign = Nothing,
      utmContent = Nothing,
      utmTerm = Nothing,
      correlationId = Nothing,
      causationId = Nothing,
      sourceEventId = Nothing,
      sourceGlobalPosition = Nothing,
      properties = mempty,
      context = mempty
    }
