module Kansoku.EventSpec (spec) where

import Data.Aeson (Value, decode, eitherDecode, encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Kansoku.Event
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Event" $ do
  describe "AnalyticsEvent JSON codec" $ do
    it "round-trips the sample event (decode then encode equals original JSON)" $ do
      case eitherDecode sampleJson of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right ev -> do
          ev `shouldBe` expectedSample
          decode (encode ev) `shouldBe` (decode sampleJson :: Maybe Value)

    it "rejects an unknown source value" $ do
      (eitherDecode badSourceJson :: Either String AnalyticsEvent)
        `shouldSatisfy` isLeftContaining "unknown event source"

    it "round-trips identifier maps and keeps the field optional" $ do
      let withIdentifiers =
            expectedSample
              & #identifiers
              ?~ Map.fromList
                [ ("fingerprint", "fp-1"),
                  ("email_sha256", "ab12")
                ]
      decode (encode withIdentifiers) `shouldBe` Just withIdentifiers
      expectedSample ^. #identifiers `shouldBe` Nothing

  describe "schema registry" $ do
    it "finds a seeded schema" $
      lookupSchema (EventName "page_view") defaultRegistry `shouldSatisfy` isJust

    it "returns Nothing for an unregistered name" $
      lookupSchema (EventName "no_such_event") defaultRegistry `shouldBe` Nothing

  describe "validation" $ do
    it "accepts a well-formed registered event" $
      validateEvent expectedSample `shouldBe` Right expectedSample

    it "rejects an empty eventId" $
      validateEvent (expectedSample & #eventId .~ EventId "")
        `shouldSatisfy` hasError EmptyEventId

    it "rejects receivedAt before occurredAt" $
      validateEvent (swapTimes expectedSample) `shouldSatisfy` isLeft

    it "flags a missing required property for a registered event" $
      validateEvent (expectedSample & #properties .~ KeyMap.empty)
        `shouldSatisfy` hasError (MissingRequiredProperty (EventName "page_view") "url")

    it "accepts every declared identifier kind" $ do
      let ids = Map.fromList [(name, "opaque-value") | name <- allowedIdentifierKindNames]
          event = expectedSample & #identifiers ?~ ids
      validateEvent event `shouldBe` Right event

    it "rejects unknown identifier kinds with the allowed vocabulary" $
      validateEvent (expectedSample & #identifiers ?~ Map.singleton "mac_address" "aa:bb")
        `shouldSatisfy` hasError (UnknownIdentifierKind "mac_address" allowedIdentifierKindNames)

    it "rejects empty, oversized, whitespace, and non-ASCII identifier values" $ do
      let ids =
            Map.fromList
              [ ("cookie", ""),
                ("device", Text.replicate 257 "x"),
                ("fingerprint", "contains space"),
                ("email_sha256", "café")
              ]
          result = validateEvent (expectedSample & #identifiers ?~ ids)
      result `shouldSatisfy` hasError (EmptyIdentifierValue "cookie")
      result `shouldSatisfy` hasError (IdentifierValueTooLong "device" 257 256)
      result `shouldSatisfy` hasError (IdentifierValueBadCharset "fingerprint")
      result `shouldSatisfy` hasError (IdentifierValueBadCharset "email_sha256")

sampleJson :: LBS8.ByteString
sampleJson =
  """
  {
    "eventId": "evt_01HZX8N2Qb",
    "eventName": "page_view",
    "source": "web",
    "sourceService": "marketing-site",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:01Z",
    "anonymousId": "anon_abc123",
    "userId": "user_42",
    "organizationId": "org_7",
    "accountId": "acct_9",
    "sessionId": "sess_xyz",
    "url": "https://example.com/pricing",
    "referrer": "https://google.com/",
    "utmSource": "google",
    "utmMedium": "cpc",
    "utmCampaign": "launch",
    "utmContent": "hero",
    "utmTerm": "analytics",
    "correlationId": "corr_1",
    "causationId": "cause_1",
    "sourceEventId": "src_evt_1",
    "sourceGlobalPosition": 12345,
    "properties": { "url": "https://example.com/pricing", "title": "Pricing" },
    "context": { "userAgent": "Mozilla/5.0", "ip": "203.0.113.7" }
  }
  """

badSourceJson :: LBS8.ByteString
badSourceJson =
  """
  {
    "eventId": "evt_bad_source",
    "eventName": "page_view",
    "source": "telepathy",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:01Z",
    "properties": { "url": "https://example.com/pricing" },
    "context": {}
  }
  """

expectedSample :: AnalyticsEvent
expectedSample =
  AnalyticsEvent
    { eventId = EventId "evt_01HZX8N2Qb",
      eventName = EventName "page_view",
      source = Web,
      sourceService = Just "marketing-site",
      occurredAt = read "2026-07-01 12:00:00 UTC",
      receivedAt = read "2026-07-01 12:00:01 UTC",
      anonymousId = Just (AnonymousId "anon_abc123"),
      userId = Just (UserId "user_42"),
      identifiers = Nothing,
      organizationId = Just (OrganizationId "org_7"),
      accountId = Just (AccountId "acct_9"),
      sessionId = Just (SessionId "sess_xyz"),
      url = Just "https://example.com/pricing",
      referrer = Just "https://google.com/",
      utmSource = Just "google",
      utmMedium = Just "cpc",
      utmCampaign = Just "launch",
      utmContent = Just "hero",
      utmTerm = Just "analytics",
      correlationId = Just (CorrelationId "corr_1"),
      causationId = Just (CausationId "cause_1"),
      sourceEventId = Just (SourceEventId "src_evt_1"),
      sourceGlobalPosition = Just 12345,
      properties =
        KeyMap.fromList
          [ ("url", "https://example.com/pricing"),
            ("title", "Pricing")
          ],
      context =
        KeyMap.fromList
          [ ("userAgent", "Mozilla/5.0"),
            ("ip", "203.0.113.7")
          ]
    }

swapTimes :: AnalyticsEvent -> AnalyticsEvent
swapTimes event =
  event
    & #occurredAt
    .~ read "2026-07-01 12:00:01 UTC"
    & #receivedAt
    .~ read "2026-07-01 12:00:00 UTC"

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

isLeftContaining :: String -> Either String a -> Bool
isLeftContaining needle (Left err) = needle `isInfixOf` err
isLeftContaining _ (Right _) = False

hasError :: ValidationError -> Either [ValidationError] AnalyticsEvent -> Bool
hasError expected (Left errs) = expected `elem` errs
hasError _ (Right _) = False
