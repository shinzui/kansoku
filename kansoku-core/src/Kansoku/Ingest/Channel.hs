-- | Version 2 first-touch channel inputs and complete host/suffix boundaries.
module Kansoku.Ingest.Channel
  ( classifyChannel,
    canonicalHost,
    referrerHost,
    channelRuleVersion,
  )
where

import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude
import Network.HTTP.Types.URI (parseQueryText)
import Network.URI (URI (..), URIAuth (..), parseURI)

channelRuleVersion :: Int
channelRuleVersion = 2

canonicalHost :: Text -> Maybe Text
canonicalHost value = parseURI (Text.unpack value) >>= canonicalURIHost

canonicalURIHost :: URI -> Maybe Text
canonicalURIHost uri = do
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
  | maybe False (matchesAny aiAssistantHosts) external || source `elem` (aiAssistantHosts <> aiAssistantSources) = "ai_assistant"
  | maybe False (matchesAny searchHosts) external = "organic_search"
  | maybe False (matchesAny socialHosts) external || click "fbclid" = "organic_social"
  | isJust external = "referral"
  | any (not . Text.null) [source, campaign] = "other"
  | otherwise = "direct"
  where
    destination = parseURI . Text.unpack =<< event ^. #url
    query = maybe [] (parseQueryText . Text.encodeUtf8 . Text.pack . uriQuery) destination
    fallbackQuery = if isJust (destination >>= canonicalURIHost) then query else []
    source = effective "utm_source" (event ^. #utmSource)
    medium = effective "utm_medium" (event ^. #utmMedium)
    campaign = effective "utm_campaign" (event ^. #utmCampaign)
    effective key explicit = fromMaybe "" ((explicit >>= nonblank) <|> listToMaybe [value | (name, Just raw) <- fallbackQuery, name == key, Just value <- [nonblank raw]])
    nonblank raw = let value = Text.toLower (Text.strip raw) in if Text.null value then Nothing else Just value
    external = do
      host <- canonicalHost =<< event ^. #referrer
      guard (Just host /= (destination >>= canonicalURIHost))
      pure host
    socialSource = if Text.null source then maybe False (matchesAny socialHosts) external else source `elem` socialSources || matchesAny socialHosts source
    click key = any (\(name, value) -> name == key && maybe False (not . Text.null) value) query
    paidMediums = ["cpc", "ppc", "paid", "paid_social", "paid-social", "paidsocial", "social_paid"]

matchesAny :: [Text] -> Text -> Bool
matchesAny hosts candidate = any (\host -> candidate == host || ("." <> host) `Text.isSuffixOf` candidate) hosts

socialSources :: [Text]
socialSources = ["facebook", "fb", "instagram", "ig", "linkedin", "twitter", "x", "tiktok", "pinterest", "reddit", "snapchat", "youtube"]

socialHosts, searchHosts :: [Text]
socialHosts = ["facebook.com", "fb.com", "instagram.com", "linkedin.com", "twitter.com", "x.com", "t.co", "tiktok.com", "pinterest.com", "reddit.com", "snapchat.com", "youtube.com", "youtu.be"]
searchHosts = ["google.com", "google.co.uk", "google.ca", "google.de", "google.fr", "google.co.jp", "google.com.au", "bing.com", "duckduckgo.com", "search.yahoo.com", "yahoo.co.jp", "baidu.com", "yandex.com", "yandex.ru", "ecosia.org", "search.brave.com", "qwant.com", "startpage.com"]

-- Version 2 policy: external hosts allow dot suffixes; source tokens are exact.
aiAssistantHosts, aiAssistantSources :: [Text]
aiAssistantHosts = ["chatgpt.com", "chat.openai.com", "perplexity.ai", "claude.ai", "gemini.google.com", "copilot.microsoft.com", "you.com", "phind.com"]
aiAssistantSources = ["chatgpt", "perplexity", "claude", "gemini", "copilot", "phind"]
