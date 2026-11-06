-- | Validation for names that can participate in metric SQL.
--
-- Caller-supplied event names are validated before native parameter binding.
-- Other query inputs are parsed values or select from closed SQL fragments.
module Kansoku.Metrics.Query.Validate
  ( QueryLimitError (..),
    validateDateRange,
    validateObservationCutoff,
    validateSteps,
    validateAcquisitionConversions,
    validateOffsets,
    SqlName,
    mkSqlName,
    renderSqlName,
  )
where

import Data.Char (isAsciiLower, isDigit)
import Data.List qualified as List
import Data.Text qualified as Text
import Data.Time (Day, diffDays)
import Kansoku.Metrics.Api (AcquisitionMeasure (..))
import Kansoku.Metrics.Limits
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

-- | A public, permanent input fault. Validation never touches storage.
data QueryLimitError = QueryLimitError
  { limitCode :: !Text,
    limitMessage :: !Text
  }
  deriving stock (Generic, Eq, Show)

validateDateRange :: Day -> Day -> Either QueryLimitError ()
validateDateRange fromDay toDay
  | days <= 0 = Left (QueryLimitError "invalid_date_range" "from must precede the exclusive to date")
  | days > maxQueryDays = Left (QueryLimitError "query_range_too_large" "narrow the query to at most 366 days")
  | otherwise = Right ()
  where
    days = diffDays toDay fromDay

-- Every included UTC day must have closed at request start.
validateObservationCutoff :: Day -> Day -> Either QueryLimitError ()
validateObservationCutoff today toDay
  | toDay > today = Left (QueryLimitError "unclosed_observation_window" "to must be no later than the current UTC day; only closed days are observed")
  | otherwise = Right ()

validateSteps :: [a] -> Either QueryLimitError ()
validateSteps steps
  | null steps = Left (QueryLimitError "invalid_funnel_steps" "at least one non-empty funnel step is required")
  | length steps > maxFunnelSteps = Left (QueryLimitError "too_many_funnel_steps" "at most 20 funnel steps are supported")
  | otherwise = Right ()

validateOffsets :: [Int] -> Either QueryLimitError [Int]
validateOffsets offsets
  | any (\n -> n < 1 || n > maxRetentionOffset) unique =
      Left (QueryLimitError "invalid_retention_days" "retention day offsets must be in 1..365")
  | length unique > maxRetentionDays =
      Left (QueryLimitError "too_many_retention_days" "at most 32 distinct retention day offsets are supported")
  | otherwise = Right unique
  where
    unique = List.sort (List.nub offsets)

-- | Bound the supplied list before normalization; duplicate names have OR semantics.
validateAcquisitionConversions :: AcquisitionMeasure -> Maybe [Text] -> Either QueryLimitError [SqlName]
validateAcquisitionConversions measure supplied =
  case (measure `elem` [AcquisitionConvertedUsers, AcquisitionConversionRate], supplied) of
    (False, Nothing) -> Right []
    (True, Just names)
      | not (null names),
        length names <= maxAcquisitionConversionEvents ->
          case traverse (mkSqlName . Text.strip) names of
            Right valid -> Right (List.nub valid)
            Left _ -> Left invalid
    _ -> Left invalid
  where
    invalid = QueryLimitError "invalid_conversion_events" "converted_users and conversion_rate require conversionEvents with 1..20 names of 1..128 lowercase ASCII letters, digits, underscore, dot, colon or hyphen; empty entries and lists on sessions/users are invalid"
