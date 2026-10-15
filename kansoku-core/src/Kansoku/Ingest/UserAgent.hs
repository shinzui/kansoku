-- | Conservative, ordered categorical rules. These are approximations, not identity.
module Kansoku.Ingest.UserAgent
  ( UserAgentInfo (..),
    classifyUserAgent,
    unknownUserAgent,
    botRuleVersion,
  )
where

import Data.Text qualified as Text
import Kansoku.Prelude hiding (anyOf, has)

data UserAgentInfo = UserAgentInfo
  { browserFamily :: !Text,
    osFamily :: !Text,
    deviceClass :: !Text,
    isBot :: !Bool
  }
  deriving stock (Generic, Eq, Show)

unknownUserAgent :: UserAgentInfo
unknownUserAgent = UserAgentInfo "unknown" "unknown" "unknown" False

botRuleVersion :: Int
botRuleVersion = 1

classifyUserAgent :: Text -> UserAgentInfo
classifyUserAgent input
  | Text.null input = unknownUserAgent
  | otherwise = UserAgentInfo browser os device bot
  where
    -- The request boundary rejects larger agents; direct callers are bounded too.
    agent = Text.toLower (Text.take 2048 input)
    has = (`Text.isInfixOf` agent)
    anyOf = any has
    bot = anyOf botTokens
    browser
      | anyOf ["edg/", "edga/", "edgios/", "edge/"] = "edge"
      | anyOf ["opr/", "opera/", "opios/", "opera mini", "opera mobi"] = "opera"
      | has "samsungbrowser/" = "samsung_internet"
      | has "android" && anyOf ["; wv)", "; wv;"] = "android_webview"
      | anyOf ["crios/", "chrome/", "chromium/"] = "chrome"
      | anyOf ["fxios/", "firefox/"] = "firefox"
      | has "safari/" && has "version/" = "safari"
      | has "msie " || (has "trident/" && has "rv:") = "internet_explorer"
      | otherwise = "unknown"
    os
      | has "windows phone" = "windows"
      | anyOf ["iphone", "ipad", "ipod"] = "ios"
      | has "android" = "android"
      | has "cros " = "chrome_os"
      | anyOf ["windows nt", "windows phone"] = "windows"
      | anyOf ["macintosh", "mac os x"] = "macos"
      | has "linux" = "linux"
      | otherwise = "unknown"
    device
      | anyOf ["ipad", "tablet", "kindle", "silk/"] = "tablet"
      | anyOf ["iphone", "ipod", "windows phone", "opera mini", "opera mobi"] || (os == "android" && has "mobile") = "mobile"
      | os == "android" && browser /= "unknown" && not (has "mobile") = "tablet"
      | os `elem` ["windows", "macos", "linux", "chrome_os"] || has "x11" = "desktop"
      | otherwise = "unknown"

-- Version 1 uses explicit crawler/tool signatures; generic words such as "bot"
-- or "search" alone do not classify a request. Context.bot=true is ORed later.
botTokens :: [Text]
botTokens =
  [ "googlebot",
    "bingbot",
    "bingpreview",
    "duckduckbot",
    "baiduspider",
    "yandexbot",
    "yandeximages",
    "slurp/",
    "sogou web spider",
    "exabot",
    "facebookexternalhit",
    "facebot",
    "twitterbot",
    "linkedinbot",
    "slackbot",
    "discordbot",
    "applebot",
    "petalbot",
    "semrushbot",
    "ahrefsbot",
    "mj12bot",
    "dotbot",
    "headlesschrome",
    "phantomjs",
    "chrome-lighthouse",
    "gptbot",
    "chatgpt-user",
    "oai-searchbot",
    "claudebot",
    "claude-user",
    "perplexitybot",
    "bytespider",
    "ccbot",
    "amazonbot",
    "meta-externalagent",
    "uptimerobot",
    "pingdom.com_bot"
  ]
