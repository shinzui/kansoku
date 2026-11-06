module Kansoku.Ingest.EnrichmentSpec (spec) where

import Control.Monad (filterM, forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.ClickHouse.EventRow (eventRowFromQueuedEvent)
import Kansoku.Event
import Kansoku.Ingest.Channel
import Kansoku.Ingest.Enrichment
import Kansoku.Ingest.QueuedEvent
import Kansoku.Ingest.RequestContext
import Kansoku.Ingest.UserAgent qualified as UA
import Kansoku.Prelude
import System.Directory (doesFileExist)
import Test.Hspec

data Fixture = Fixture Text Text UA.UserAgentInfo

instance FromJSON Fixture where
  parseJSON = Aeson.withObject "synthetic agent fixture" $ \object ->
    Fixture
      <$> object Aeson..: "label"
      <*> object Aeson..: "agent"
      <*> (UA.UserAgentInfo <$> object Aeson..: "browserFamily" <*> object Aeson..: "osFamily" <*> object Aeson..: "deviceClass" <*> object Aeson..: "isBot")

spec :: Spec
spec = describe "Kansoku.Ingest.Enrichment" $ do
  fixtures <- runIO loadFixtures
  it "contains at least one hundred distinct synthetic classification cases" $
    length fixtures `shouldSatisfy` (>= 100)
  describe "user-agent version 1" $
    forM_ fixtures $ \(Fixture label agent expected) ->
      it (Text.unpack label) (UA.classifyUserAgent agent `shouldBe` expected)

  it "does not classify non-web traffic as a browser and ORs only Boolean bot claims" $ do
    let request = IngestRequestContext (Just "Mozilla/5.0 (Windows NT 10.0) Chrome/130.0 Safari/537.36") Nothing
    forM_ [App, Service, Worker, Email, Agent] $ \source -> do
      let derived = enrichEvent request (sample & #source .~ source)
      derived ^. #browserFamily `shouldBe` "unknown"
      derived ^. #osFamily `shouldBe` "unknown"
      derived ^. #deviceClass `shouldBe` "unknown"
      derived ^. #channel `shouldBe` "unknown"
      derived ^. #ruleVersion `shouldBe` 2
    let botAgent = request & #userAgent ?~ "Googlebot/2.1"
        withBot value = sample & #context .~ KM.singleton "bot" value
    enrichEvent botAgent (withBot (Aeson.Bool False)) ^. #isBot `shouldBe` True
    enrichEvent request (withBot (Aeson.Bool True)) ^. #isBot `shouldBe` True
    enrichEvent request (withBot (Aeson.String "true")) ^. #isBot `shouldBe` False

  it "roundtrips the private envelope and decodes the legacy form without trusting producer categories" $ do
    let request = IngestRequestContext (Just "Googlebot/2.1") (Just "GB")
        queued = enrichedQueuedEvent request sample
    Aeson.eitherDecode (Aeson.encode queued) `shouldBe` Right queued
    Aeson.fromJSON (Aeson.toJSON sample) `shouldBe` Aeson.Success (legacyQueuedEvent sample)
    case Aeson.toJSON queued of
      Aeson.Object object -> (Aeson.fromJSON (Aeson.Object (KM.insert "queueVersion" (Aeson.Number 3) object)) :: Aeson.Result QueuedEvent) `shouldSatisfy` \case Aeson.Error _ -> True; _ -> False
      _ -> expectationFailure "queue envelope is not an object"
    (Aeson.eitherDecode "{\"queueVersion\":1,\"event\":{},\"enrichment\":{}}" :: Either String QueuedEvent) `shouldSatisfy` isLeft

  it "roundtrips version 2 Gemini classification through the queue and storage row" $ do
    let input = sample & #referrer ?~ "https://gemini.google.com/" & #url ?~ "https://shop.example/"
        queued = enrichedQueuedEvent (IngestRequestContext Nothing Nothing) input
    queued ^. #enrichment . #channel `shouldBe` "ai_assistant"
    queued ^. #enrichment . #ruleVersion `shouldBe` 2
    case Aeson.eitherDecode (Aeson.encode queued) of
      Left err -> expectationFailure err
      Right decoded -> do
        decoded `shouldBe` queued
        eventRowFromQueuedEvent decoded ^. #channel `shouldBe` "ai_assistant"
        eventRowFromQueuedEvent decoded ^. #enrichment_version `shouldBe` 2

  it "uses deterministic channel precedence and host boundaries" $ do
    let channel source medium campaign url referrer = classifyChannel (sample & #utmSource .~ source & #utmMedium .~ medium & #utmCampaign .~ campaign & #url ?~ url & #referrer .~ referrer)
    forM_
      [ (Nothing, Nothing, Nothing, "https://shop.example/", Nothing, "direct"),
        (Nothing, Nothing, Nothing, "https://SHOP.example./", Just "https://shop.example/old", "direct"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://www.google.com/search?q=x", "organic_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?gclid=123", Nothing, "paid_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?msclkid=123", Nothing, "paid_search"),
        (Just "facebook", Just "cpc", Just "launch", "https://shop.example/?gclid=x", Just "https://www.google.com/", "paid_social"),
        (Just "facebook", Just "paid_social", Nothing, "https://shop.example/", Nothing, "paid_social"),
        (Just "facebook", Just "social", Just "launch", "https://shop.example/", Nothing, "paid_social"),
        (Just "facebook", Just "email", Just "launch", "https://shop.example/?gclid=123", Nothing, "email"),
        (Just "google", Just "cpc", Nothing, "https://shop.example/", Just "https://facebook.com/", "paid_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?fbclid=123", Nothing, "organic_social"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://m.facebook.com/post", "organic_social"),
        (Nothing, Just "affiliate", Nothing, "https://shop.example/", Just "https://google.com/", "other_campaign"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://partner.example/path", "referral"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://google.com.evil.example/", "referral"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://notfacebook.com/", "referral"),
        (Nothing, Nothing, Nothing, "https://shop.example/", Just "https://facebook.com@evil.example/", "referral"),
        (Just "newsletter", Nothing, Just "launch", "https://shop.example/", Nothing, "other"),
        (Nothing, Nothing, Nothing, "https://shop.example/?gclid=", Nothing, "direct")
      ]
      (\(source, medium, campaign, url, referrer, expected) -> channel source medium campaign url referrer `shouldBe` expected)
    canonicalHost "hTtPs://USER:password@EXAMPLE.com.:8443/path" `shouldBe` Just "example.com"
    canonicalHost "mailto:someone@example.com" `shouldBe` Nothing

  describe "assistant channel version 2" $ do
    let hosts = ["chatgpt.com", "chat.openai.com", "perplexity.ai", "claude.ai", "gemini.google.com", "copilot.microsoft.com", "you.com", "phind.com"]
        aliases = ["chatgpt", "perplexity", "claude", "gemini", "copilot", "phind"]
        input = sample & #url ?~ "https://shop.example/"
    forM_ hosts $ \host -> it ("recognizes host and exact source " <> Text.unpack host) $ do
      classifyChannel (input & #referrer ?~ ("https://" <> host <> "/")) `shouldBe` "ai_assistant"
      classifyChannel (input & #referrer ?~ ("https://sub." <> Text.toUpper host <> ".:8443/")) `shouldBe` "ai_assistant"
      classifyChannel (input & #utmSource ?~ ("  " <> Text.toUpper host <> "  ")) `shouldBe` "ai_assistant"
      classifyChannel (input & #url ?~ ("https://" <> host <> "/") & #referrer ?~ ("https://" <> host <> "/old")) `shouldBe` "direct"
      classifyChannel (input & #url ?~ ("https://" <> host <> "/") & #referrer ?~ ("https://" <> host <> "/old") & #utmSource ?~ host) `shouldBe` "ai_assistant"
    forM_ aliases $ \source ->
      it ("recognizes alias " <> Text.unpack source) $
        classifyChannel (input & #utmSource ?~ (" " <> Text.toUpper source <> " ")) `shouldBe` "ai_assistant"
    forM_ ["notchatgpt.com", "chatgpt.com.evil.example", "google.com", "microsoft.com", "openai.com", "ai", "you", "google", "microsoft", "https://chatgpt.com", "chatgpt.com/path", "user@chatgpt.com", "chatgpt.com:443", "sub.chatgpt.com"] $ \source ->
      it ("rejects unlisted source " <> Text.unpack source) $
        classifyChannel (input & #utmSource ?~ source) `shouldBe` "other"
    forM_ ["https://notchatgpt.com/", "https://chatgpt.com.evil.example/", "https://chatgpt.com@evil.example/", "https://microsoft.com/", "https://openai.com/", "not a URL", "mailto:chatgpt.com"] $ \referrer ->
      it ("rejects false assistant referrer " <> Text.unpack referrer) $
        classifyChannel (input & #referrer ?~ referrer) `shouldSatisfy` (/= "ai_assistant")
    forM_
      [ (Nothing, Just "email", Nothing, "https://shop.example/", Just "https://chatgpt.com/", "email"),
        (Just "facebook", Just "cpc", Nothing, "https://shop.example/", Just "https://chatgpt.com/", "paid_social"),
        (Just "chatgpt", Just "cpc", Nothing, "https://shop.example/", Nothing, "paid_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?gclid=x", Just "https://chatgpt.com/", "paid_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?msclkid=x", Just "https://chatgpt.com/", "paid_search"),
        (Nothing, Just "affiliate", Nothing, "https://shop.example/", Just "https://chatgpt.com/", "other_campaign"),
        (Just "claude", Nothing, Nothing, "https://shop.example/", Just "https://google.com/", "ai_assistant"),
        (Just "claude", Nothing, Nothing, "https://shop.example/?fbclid=x", Just "https://facebook.com/", "ai_assistant"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=chatgpt.com", Nothing, "ai_assistant"),
        (Just "  ", Nothing, Nothing, "https://shop.example/?utm_source=%20ChatGPT%2Ecom%20", Nothing, "ai_assistant"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=&utm_source=%20&utm_source=claude&utm_source=google", Nothing, "ai_assistant"),
        (Just "newsletter", Nothing, Nothing, "https://shop.example/?utm_source=chatgpt", Nothing, "other"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=chatgpt&utm_medium=email", Nothing, "email"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=chatgpt&utm_medium=cpc", Nothing, "paid_search"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=newsletter&utm_medium=email", Nothing, "email"),
        (Nothing, Just "email", Nothing, "https://shop.example/?utm_source=chatgpt&utm_medium=cpc", Nothing, "email"),
        (Nothing, Just "cpc", Nothing, "https://shop.example/?utm_medium=email&utm_source=chatgpt", Nothing, "paid_search"),
        (Nothing, Just "social", Just "launch", "https://shop.example/?utm_source=facebook&utm_campaign=", Nothing, "paid_social"),
        (Nothing, Nothing, Nothing, "https://shop.example/?utm_source=facebook&utm_medium=social&utm_campaign=launch", Nothing, "paid_social"),
        (Nothing, Nothing, Just " ", "https://shop.example/?utm_campaign=launch", Nothing, "other"),
        (Nothing, Nothing, Nothing, "https://shop.example/?UTM_SOURCE=chatgpt", Nothing, "direct"),
        (Nothing, Nothing, Nothing, "not a URL?utm_source=chatgpt", Nothing, "direct"),
        (Nothing, Nothing, Nothing, "ftp://shop.example/?utm_source=chatgpt", Nothing, "direct")
      ]
      $ \(source, medium, campaign, url, referrer, expected) ->
        it ("applies precedence/fallback " <> show (source, medium, campaign, url, referrer)) $
          classifyChannel (input & #utmSource .~ source & #utmMedium .~ medium & #utmCampaign .~ campaign & #url ?~ url & #referrer .~ referrer) `shouldBe` expected

  it "preserves literal historical classifications in both envelope versions and storage" $ do
    forM_ [(Just "https://gemini.google.com/", Nothing, "organic_search"), (Just "https://chatgpt.com/", Nothing, "referral"), (Nothing, Just "chatgpt", "other")] $ \(referrer, source, channel) ->
      forM_ [1, 2 :: Int] $ \version -> do
        let event = sample & #url ?~ "https://shop.example/" & #referrer .~ referrer & #utmSource .~ source
            historical = Enrichment "unknown" "unknown" "unknown" False channel Nothing 1
            payload = Aeson.object (["queueVersion" Aeson..= version, "event" Aeson..= event, "enrichment" Aeson..= historical] <> ["traitsEligible" Aeson..= False | version == 2])
        case Aeson.fromJSON payload of
          Aeson.Error err -> expectationFailure err
          Aeson.Success queued -> do
            queued ^. #enrichment `shouldBe` historical
            Aeson.eitherDecode (Aeson.encode queued) `shouldBe` Right queued
            eventRowFromQueuedEvent queued ^. #channel `shouldBe` Text.encodeUtf8 channel
            eventRowFromQueuedEvent queued ^. #enrichment_version `shouldBe` 1
    let legacy = legacyQueuedEvent sample
    legacy ^. #enrichment . #ruleVersion `shouldBe` 0
    eventRowFromQueuedEvent legacy ^. #channel `shouldBe` "unknown"
    eventRowFromQueuedEvent legacy ^. #enrichment_version `shouldBe` 0

  it "rejects unsupported versions, unknown channels and AI channels before version 2" $
    forM_ [(3, "direct"), (-1, "direct"), (2, "invented"), (0, "ai_assistant"), (1, "ai_assistant")] $ \(version, channel) -> do
      let invalid = Enrichment "unknown" "unknown" "unknown" False channel Nothing version
      (Aeson.eitherDecode (Aeson.encode invalid) :: Either String Enrichment) `shouldSatisfy` isLeft

loadFixtures :: IO [Fixture]
loadFixtures = do
  paths <- filterM doesFileExist ["test/fixtures/user-agents.json", "kansoku-core/test/fixtures/user-agents.json"]
  case paths of
    path : _ -> LBS.readFile path >>= either fail pure . Aeson.eitherDecode
    [] -> fail "synthetic user-agent fixtures missing"

sample :: AnalyticsEvent
sample = baseEvent (EventId "classified") (EventName "custom") Web timestamp timestamp
  where
    timestamp = read "2026-07-01 12:00:00 UTC"
