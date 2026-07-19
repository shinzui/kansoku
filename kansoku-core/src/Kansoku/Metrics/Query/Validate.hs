-- | Validation for names that can participate in metric SQL.
--
-- Funnel steps are the only raw 'Text' HTTP input that reaches metric SQL.
-- Other query inputs are parsed values or select from closed SQL fragments.
module Kansoku.Metrics.Query.Validate
  ( SqlName,
    mkSqlName,
    renderSqlName,
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as Text
import Kansoku.Prelude

-- | A non-empty metric/event name of at most 128 ASCII characters, containing
-- only lowercase letters, digits, underscore, dot, colon, or hyphen.
newtype SqlName = SqlName Text
  deriving stock (Generic, Eq, Ord, Show)

mkSqlName :: Text -> Either Text SqlName
mkSqlName value
  | Text.length value >= 1,
    Text.length value <= 128,
    Text.all allowed value =
      Right (SqlName value)
  | otherwise = Left value
  where
    allowed char =
      isAsciiLower char
        || isDigit char
        || char `elem` ("_.:-" :: String)

renderSqlName :: SqlName -> Text
renderSqlName (SqlName value) = value
