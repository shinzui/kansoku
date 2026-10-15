-- | Versioned categorical output, independent of producer context claims.
module Kansoku.Ingest.Enrichment
  ( Enrichment (..),
    enrichEvent,
    legacyEnrichment,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as Text
import Kansoku.Event (AnalyticsEvent, EventSource (Web))
import Kansoku.Ingest.Channel (classifyChannel)
import Kansoku.Ingest.RequestContext (IngestRequestContext)
import Kansoku.Ingest.UserAgent qualified as UA
import Kansoku.Prelude

data Enrichment = Enrichment
  { browserFamily :: !Text,
    osFamily :: !Text,
    deviceClass :: !Text,
    isBot :: !Bool,
    channel :: !Text,
    countryCode :: !(Maybe Text),
    ruleVersion :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON Enrichment where
  parseJSON = Aeson.withObject "queued enrichment" $ \object -> do
    browserFamily <- object Aeson..: "browserFamily"
    osFamily <- object Aeson..: "osFamily"
    deviceClass <- object Aeson..: "deviceClass"
    isBot <- object Aeson..: "isBot"
    channel <- object Aeson..: "channel"
    countryCode <- object Aeson..: "countryCode"
    ruleVersion <- object Aeson..: "ruleVersion"
    unless (browserFamily `elem` ["unknown", "edge", "opera", "samsung_internet", "android_webview", "chrome", "firefox", "safari", "internet_explorer"]) (fail "unknown queued browser family")
    unless (osFamily `elem` ["unknown", "ios", "android", "chrome_os", "windows", "macos", "linux"]) (fail "unknown queued OS family")
    unless (deviceClass `elem` ["unknown", "desktop", "mobile", "tablet"]) (fail "unknown queued device class")
    unless (channel `elem` ["unknown", "email", "paid_social", "paid_search", "other_campaign", "organic_search", "organic_social", "referral", "direct", "other"]) (fail "unknown queued channel")
    unless (all (\country -> Text.length country == 2 && Text.all (\char -> char >= 'A' && char <= 'Z') country) countryCode) (fail "invalid queued country code")
    unless (ruleVersion `elem` [0, 1]) (fail "unsupported enrichment rule version")
    pure Enrichment {browserFamily, osFamily, deviceClass, isBot, channel, countryCode, ruleVersion}

legacyEnrichment :: Enrichment
legacyEnrichment = Enrichment "unknown" "unknown" "unknown" False "unknown" Nothing 0

enrichEvent :: IngestRequestContext -> AnalyticsEvent -> Enrichment
enrichEvent request event =
  let info = if event ^. #source == Web then maybe UA.unknownUserAgent UA.classifyUserAgent (request ^. #userAgent) else UA.unknownUserAgent
   in Enrichment
        { browserFamily = info ^. #browserFamily,
          osFamily = info ^. #osFamily,
          deviceClass = info ^. #deviceClass,
          isBot = info ^. #isBot || KM.lookup "bot" (event ^. #context) == Just (Aeson.Bool True),
          channel = if event ^. #source == Web then classifyChannel event else "unknown",
          countryCode = request ^. #countryCode,
          ruleVersion = 1
        }
