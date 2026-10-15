-- | Version 1 first-touch channel inputs and complete host/suffix boundaries.
module Kansoku.Ingest.Channel
  ( classifyChannel,
    canonicalHost,
    referrerHost,
    channelRuleVersion,
  )
where

import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Network.HTTP.Types.URI (parseQueryText)
import Network.URI (URI (..), URIAuth (..), parseURI)

channelRuleVersion :: Int
channelRuleVersion = 1

canonicalHost :: Text -> Maybe Text
canonicalHost value = do
  uri <- parseURI (Text.unpack value)
  guard (Text.toLower (Text.pack (uriScheme uri)) `elem` ["http:", "https:"])
  authority <- uriAuthority uri
  let host = Text.dropWhileEnd (== '.') (Text.toLower (Text.pack (uriRegName authority)))
  guard (not (Text.null host))
  pure host

referrerHost :: AnalyticsEvent -> Maybe Text
referrerHost event = do
  host <- canonicalHost =<< event ^. #referrer
  guard (Just host /= (canonicalHost =<< event ^. #url))
  pure host

classifyChannel :: AnalyticsEvent -> Text
classifyChannel event
  | medium `elem` ["email", "e-mail", "e_mail"] = "email"
  | socialSource && (medium `elem` paidMediums || (not (Text.null campaign) && medium `elem` ["social", "social-media", "social_media"])) = "paid_social"
  | click "gclid" || click "msclkid" || medium `elem` ["cpc", "ppc", "paidsearch", "paid_search", "paid-search"] = "paid_search"
  | not (Text.null medium) = "other_campaign"
  | maybe False (matchesAny searchHosts) external = "organic_search"
  | maybe False (matchesAny socialHosts) external || click "fbclid" = "organic_social"
  | isJust external = "referral"
  | any (not . Text.null) [source, campaign] = "other"
  | otherwise = "direct"
  where
    source = normalized (event ^. #utmSource)
    medium = normalized (event ^. #utmMedium)
    campaign = normalized (event ^. #utmCampaign)
    normalized = Text.toLower . Text.strip . fromMaybe ""
    external = referrerHost event
    socialSource = if Text.null source then maybe False (matchesAny socialHosts) external else source `elem` socialSources || matchesAny socialHosts source
    click key = case parseURI . Text.unpack =<< event ^. #url of
      Nothing -> False
      Just uri -> any (\(name, value) -> name == key && maybe False (not . Text.null) value) (parseQueryText (Text.encodeUtf8 (Text.pack (uriQuery uri))))
    paidMediums = ["cpc", "ppc", "paid", "paid_social", "paid-social", "paidsocial", "social_paid"]

matchesAny :: [Text] -> Text -> Bool
matchesAny hosts candidate = any (\host -> candidate == host || ("." <> host) `Text.isSuffixOf` candidate) hosts

socialSources :: [Text]
socialSources = ["facebook", "fb", "instagram", "ig", "linkedin", "twitter", "x", "tiktok", "pinterest", "reddit", "snapchat", "youtube"]

socialHosts, searchHosts :: [Text]
socialHosts = ["facebook.com", "fb.com", "instagram.com", "linkedin.com", "twitter.com", "x.com", "t.co", "tiktok.com", "pinterest.com", "reddit.com", "snapchat.com", "youtube.com", "youtu.be"]
searchHosts = ["google.com", "google.co.uk", "google.ca", "google.de", "google.fr", "google.co.jp", "google.com.au", "bing.com", "duckduckgo.com", "search.yahoo.com", "yahoo.co.jp", "baidu.com", "yandex.com", "yandex.ru", "ecosia.org", "search.brave.com", "qwant.com", "startpage.com"]
