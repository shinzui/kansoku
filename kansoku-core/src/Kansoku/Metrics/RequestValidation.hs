-- | Reject ignored/ambiguous query parameters after service-token authentication.
module Kansoku.Metrics.RequestValidation (validateMetricRequest) where

import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Metrics.Filter (maxFilterBytes, maxFilters, parseMetricFilter, validateMetricFilters)
import Kansoku.Prelude
import Network.HTTP.Types.URI (decodePathSegments)
import Network.Wai (Request, queryString, rawPathInfo)

validateMetricRequest :: Request -> Either (Text, Text) ()
-- Servant consumes pathInfo while routing; rawPathInfo retains the full path.
validateMetricRequest request = case allowedParameters (decodePathSegments (rawPathInfo request)) of
  Nothing -> Right ()
  Just allowed -> do
    names <- traverse (first (const ("invalid_query_parameter", "query parameter names must be UTF-8")) . Text.decodeUtf8' . fst) query
    case filter (`notElem` allowed) names of
      invalid : _ -> Left ("unsupported_query_parameter", "unsupported query parameter: " <> Text.take 128 invalid)
      [] -> pure ()
    unless (length (filter (/= "filter") names) == length (nub (filter (/= "filter") names))) $
      Left ("invalid_query_parameter", "only filter may be repeated")
    unless (all (\(name, operand) -> name == "filter" || isJust operand) query) $
      Left ("invalid_query_parameter", "query parameters require a value")
    let rawFilters = [operand | ("filter", operand) <- query]
    unless (length rawFilters <= maxFilters) (Left ("invalid_filter", "at most eight filters are supported"))
    unless (sum (map (maybe 0 BS.length) rawFilters) <= maxFilterBytes) (Left ("invalid_filter", "decoded filters are limited to 16384 UTF-8 bytes"))
    filters <- first ("invalid_filter",) $ traverse parseOne rawFilters
    void (first ("invalid_filter",) (validateMetricFilters filters))
  where
    query = queryString request
    parseOne Nothing = Left "filter requires a JSON object"
    parseOne (Just bytes) = first (const "filter must be UTF-8") (Text.decodeUtf8' bytes) >>= parseMetricFilter

allowedParameters :: [Text] -> Maybe [Text]
allowedParameters = \case
  ["metrics", "acquisition"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "measure", "includeBots"]
  ["metrics", endpoint] | endpoint `elem` ["page-views", "users"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "includeBots"]
  ["metrics", endpoint]
    | endpoint `elem` ["events", "feature-adoption", "conversion", "revenue", "organizations", "custom"] ->
        Just ["from", "to", "groupBy", "timeGrain", "filter"]
  ["metrics", "sessions"] -> Just ["from", "to", "timeGrain"]
  ["metrics", "funnel"] -> Just ["from", "to", "steps", "window"]
  ["metrics", "retention"] -> Just ["from", "to", "days"]
  ["metrics", "experiments"] -> Just ["from", "to", "experiment", "timeGrain"]
  ["metrics", "experiments", "conversion"] -> Just ["from", "to", "experiment", "event"]
  ["metrics", "experiments", "funnel"] -> Just ["from", "to", "experiment", "steps", "window"]
  _ -> Nothing
