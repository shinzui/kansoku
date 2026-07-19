module Kansoku.EventSpec (spec) where

import Data.Aeson (Value, decode, eitherDecode, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Either (isRight)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Kansoku.ClickHouse.EventRow (eventRowFromEvent)
import Kansoku.Event
import Kansoku.Metrics.Query.Validate (mkSqlName)
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

    it "omits a versionless schemaVersion and round-trips an explicit version" $ do
      case Aeson.toJSON expectedSample of
        Aeson.Object object -> KeyMap.member "schemaVersion" object `shouldBe` False
        _ -> expectationFailure "AnalyticsEvent did not encode as an object"
      let pinned = expectedSample & #schemaVersion ?~ 1
      decode (encode pinned) `shouldBe` Just pinned

  describe "schema registry" $ do
    it "finds seeded versions and reports them in ascending order" $ do
      lookupSchemaVersion (EventName "page_view") 1 defaultRegistry `shouldSatisfy` isJust
      latestSchema (EventName "page_view") defaultRegistry
        `shouldBe` lookupSchemaVersion (EventName "page_view") 1 defaultRegistry
      knownVersions (EventName "page_view") defaultRegistry `shouldBe` [1]

    it "returns Nothing for an unregistered name" $
      lookupVersions (EventName "no_such_event") defaultRegistry `shouldBe` Nothing

    it "sorts versions and replaces a duplicate name/version idempotently" $ do
      let name = EventName "versioned_test"
          version1 = EventSchema name 1 "v1" []
          version2 = EventSchema name 2 "v2" []
          replacement = EventSchema name 1 "v1 replacement" []
          registry = foldr registerSchema emptyRegistry [replacement, version2, version1]
      knownVersions name registry `shouldBe` [1, 2]
      lookupSchemaVersion name 1 registry `shouldBe` Just replacement

  describe "validation" $ do
    it "accepts a well-formed registered event" $
      validateEvent expectedSample `shouldBe` Right expectedSample

    it "accepts an event pinned to the known version 1" $ do
      let pinned = expectedSample & #schemaVersion ?~ 1
      validateEvent pinned `shouldBe` Right pinned

    it "rejects an unknown version of a registered event and names known versions" $
      validateEvent (expectedSample & #schemaVersion ?~ 2)
        `shouldSatisfy` hasError (UnknownSchemaVersion (EventName "page_view") 2 [1])

    it "rejects schema versions outside the UInt16 persistence range" $ do
      validateEvent (expectedSample & #schemaVersion ?~ 0)
        `shouldSatisfy` hasError (InvalidSchemaVersion 0)
      validateEvent (expectedSample & #schemaVersion ?~ 65536)
        `shouldSatisfy` hasError (InvalidSchemaVersion 65536)

    it "keeps unknown event names permissive when their version is in range" $ do
      let unknown = expectedSample & #eventName .~ EventName "future_event" & #schemaVersion ?~ 7
      validateEvent unknown `shouldBe` Right unknown

    it "defaults persistence to version 1 and preserves an explicit version" $ do
      eventRowFromEvent expectedSample ^. #schema_version `shouldBe` 1
      eventRowFromEvent (expectedSample & #schemaVersion ?~ 7) ^. #schema_version `shouldBe` 7
      eventRowFromEvent (expectedSample & #schemaVersion ?~ 0) ^. #schema_version `shouldBe` 1
      eventRowFromEvent (expectedSample & #schemaVersion ?~ 65536) ^. #schema_version `shouldBe` 65535

    it "rejects an empty eventId" $
      validateEvent (expectedSample & #eventId .~ EventId "")
        `shouldSatisfy` hasError EmptyEventId

    it "rejects receivedAt before occurredAt" $
      validateEvent (swapTimes expectedSample) `shouldSatisfy` isLeft

    it "flags a missing required property for a registered event" $
      validateEvent (expectedSample & #properties .~ KeyMap.empty)
        `shouldSatisfy` hasError (MissingRequiredProperty (EventName "page_view") "url")

    it "enforces the experiment_viewed property contract" $ do
      let valid = experimentEvent (Aeson.String "checkout_v2") (Just (Aeson.String "treatment"))
      validateEvent valid `shouldBe` Right valid
      validateEvent (experimentEvent (Aeson.String "checkout_v2") Nothing)
        `shouldSatisfy` hasError (MissingRequiredProperty (EventName "experiment_viewed") "variant")
      validateEvent (experimentEvent (Aeson.String "checkout_v2") (Just (Aeson.Number 1)))
        `shouldSatisfy` hasError (WrongPropertyType (EventName "experiment_viewed") "variant" PTString)
      validateEvent (experimentEvent (Aeson.String "checkout_v2") (Just (Aeson.String "Treatment!")))
        `shouldSatisfy` hasError (InvalidPropertyValue (EventName "experiment_viewed") "variant" "expected [a-z0-9_.:-]{1,128}")

    it "keeps registry SqlNamePattern acceptance aligned with mkSqlName" $ do
      let accepted = ["checkout_v2", "control", "a", "x.y:z-1", Text.replicate 128 "a"]
          rejected = ["", Text.replicate 129 "a", "Control", "checkout v2", "variant'--", "bad|variant", "bad\nvariant"]
          agrees value =
            isRight (validateEvent (experimentEvent (Aeson.String "checkout_v2") (Just (Aeson.String value))))
              == isRight (mkSqlName value)
      traverse_ (\value -> agrees value `shouldBe` True) (accepted <> rejected)

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
      schemaVersion = Nothing,
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

experimentEvent :: Aeson.Value -> Maybe Aeson.Value -> AnalyticsEvent
experimentEvent experiment variant =
  baseEvent
    (EventId "evt_experiment")
    (EventName "experiment_viewed")
    Web
    (read "2026-08-01 10:00:00 UTC")
    (read "2026-08-01 10:00:01 UTC")
    & #userId
    .~ Just (UserId "user_experiment")
    & #properties
    .~ KeyMap.fromList
      ([("experiment", experiment)] <> maybe [] (pure . ("variant",)) variant)
