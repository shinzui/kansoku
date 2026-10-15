module Kansoku.Ingest.EnrichmentSpec (spec) where

import Control.Monad (filterM, forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Text qualified as Text
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
      Aeson.Object object -> (Aeson.fromJSON (Aeson.Object (KM.insert "queueVersion" (Aeson.Number 2) object)) :: Aeson.Result QueuedEvent) `shouldSatisfy` \case Aeson.Error _ -> True; _ -> False
      _ -> expectationFailure "queue envelope is not an object"
    (Aeson.eitherDecode "{\"queueVersion\":1,\"event\":{},\"enrichment\":{}}" :: Either String QueuedEvent) `shouldSatisfy` isLeft

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
