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
validateMetricRequest request = case allowedParameters requestPath of
  Nothing -> Right ()
  Just allowed -> do
    names <- traverse (first (const ("invalid_query_parameter", "query parameter names must be UTF-8")) . Text.decodeUtf8' . fst) query
    case filter (`notElem` allowed) names of
      invalid : _ -> Left ("unsupported_query_parameter", "unsupported query parameter: " <> Text.take 128 invalid)
      [] -> pure ()
    let repeatable = if requestPath == ["metrics", "paths"] then ["filter"] else ["filter", "exclude"]
    unless (length (filter (`notElem` repeatable) names) == length (nub (filter (`notElem` repeatable) names))) $
      Left ("invalid_query_parameter", "only " <> Text.intercalate " and " repeatable <> " may be repeated")
    unless (all (\(name, operand) -> name == "filter" || isJust operand) query) $
      Left ("invalid_query_parameter", "query parameters require a value")
    let exclusions = [operand | ("exclude", operand) <- query]
    unless (requestPath == ["metrics", "paths"] || length (nub exclusions) <= 20 && all (maybe False (not . BS.null)) exclusions) (Left ("invalid_funnel_exclusion", "at most 20 distinct nonempty exclusions are supported"))
    let rawFilters = [operand | ("filter", operand) <- query]
    unless (length rawFilters <= maxFilters) (Left ("invalid_filter", "at most eight filters are supported"))
    unless (sum (map (maybe 0 BS.length) rawFilters) <= maxFilterBytes) (Left ("invalid_filter", "decoded filters are limited to 16384 UTF-8 bytes"))
    filters <- first ("invalid_filter",) $ traverse parseOne rawFilters
    void (first ("invalid_filter",) (validateMetricFilters filters))
  where
    requestPath = decodePathSegments (rawPathInfo request)
    query = queryString request
    parseOne Nothing = Left "filter requires a JSON object"
    parseOne (Just bytes) = first (const "filter must be UTF-8") (Text.decodeUtf8' bytes) >>= parseMetricFilter

allowedParameters :: [Text] -> Maybe [Text]
allowedParameters = \case
  ["metrics", "custom"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "metric", "events", "aggregation", "property", "denominatorEvents", "denominatorAggregation"]
  ["metrics", "acquisition"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "measure", "includeBots"]
  ["metrics", "users"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "window", "includeBots", "aggregate", "attribution"]
  ["metrics", endpoint] | endpoint `elem` ["page-views", "stickiness", "lifecycle"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "includeBots"]
  ["metrics", endpoint]
    | endpoint `elem` ["events", "revenue"] ->
        Just ["from", "to", "groupBy", "timeGrain", "filter"]
  ["metrics", endpoint] | endpoint `elem` ["feature-adoption", "conversion", "organizations"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "aggregate", "attribution"]
  ["metrics", "sessions"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "measure", "includeBots"]
  ["metrics", "paths"] -> Just ["from", "to", "start", "end", "steps", "top", "window", "events", "exclude", "by", "filter"]
  ["metrics", "funnel"] -> Just ["from", "to", "steps", "window", "mode", "measure", "counting", "attribution", "exclude", "groupBy", "filter", "aggregate"]
  ["metrics", "retention"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "days", "mode", "cohort", "includeBots", "aggregate", "attribution"]
  ["metrics", "experiments"] -> Just ["from", "to", "experiment", "timeGrain", "measure", "groupBy", "filter"]
  ["metrics", "experiments", "conversion"] -> Just ["from", "to", "experiment", "event", "groupBy", "filter"]
  ["metrics", "experiments", "funnel"] -> Just ["from", "to", "experiment", "steps", "window", "mode", "measure", "counting", "attribution", "exclude", "groupBy", "filter"]
  _ -> Nothing
