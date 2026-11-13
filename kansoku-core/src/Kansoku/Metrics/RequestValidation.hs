-- | Reject ignored/ambiguous query parameters after service-token authentication.
module Kansoku.Metrics.RequestValidation (validateMetricRequest) where

import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.List (nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Metrics.Filter (maxFilterBytes, maxFilters, parseMetricFilter, validateMetricFilters)
import Kansoku.Metrics.Query.UserSelection qualified as UserSelection
import Kansoku.Prelude
import Kansoku.Users.Validation (validateDates, validateDirectory, validateHistory, validateHostFacet)
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
    let filterNames = if requestPath == ["metrics", "retention"] then ["filter", "startFilter", "returnFilter"] else ["filter"]
        repeatable = if requestPath == ["metrics", "paths"] then filterNames else filterNames <> ["exclude"]
    unless (length (filter (`notElem` repeatable) names) == length (nub (filter (`notElem` repeatable) names))) $
      Left ("invalid_query_parameter", "only " <> Text.intercalate " and " repeatable <> " may be repeated")
    unless (all (\(name, operand) -> name `elem` map Text.encodeUtf8 filterNames || isJust operand) query) $
      Left ("invalid_query_parameter", "query parameters require a value")
    let exclusions = [operand | ("exclude", operand) <- query]
    unless (requestPath == ["metrics", "paths"] || length (nub exclusions) <= 20 && all (maybe False (not . BS.null)) exclusions) (Left ("invalid_funnel_exclusion", "at most 20 distinct nonempty exclusions are supported"))
    let rawFilters = [operand | (name, operand) <- query, name `elem` map Text.encodeUtf8 filterNames]
    unless (length rawFilters <= (if take 1 requestPath == ["users"] then 9 else maxFilters)) (Left ("invalid_filter", "at most eight filters are supported"))
    unless (sum (map (maybe 0 BS.length) rawFilters) <= maxFilterBytes) (Left ("invalid_filter", "decoded filters are limited to 16384 UTF-8 bytes"))
    filters <- first (filterErrorCode,) $ traverse parseOne rawFilters
    when (take 1 requestPath == ["users"]) $ do
      let scalar name = case [operand | (key, Just operand) <- query, key == name] of
            [] -> Right Nothing
            raw : _ -> Just <$> first (const ("invalid_users_query", "query value must be UTF-8")) (Text.decodeUtf8' raw)
          date name = do
            value <- scalar name
            traverse (\raw -> case reads (Text.unpack raw) of [(d, "")] -> Right d; _ -> Left ("invalid_users_query", "dates must be YYYY-MM-DD")) value
      lo <- date "from"
      hi <- date "to"
      search <- scalar "search"
      order <- scalar "order"
      first ("invalid_users_query",) $ case requestPath of
        ["users"] -> validateDirectory lo hi search order filters
        ["users", "activity-counts"] -> do
          unless (isJust lo && isJust hi) (Left "activity counts require from and to")
          validateDates lo hi
        ["users", _, "events"] -> validateDates lo hi >> validateHistory filters
        ["users", _, "hosts"] -> validateDates lo hi >> validateHostFacet filters
        _ -> validateDates lo hi
    when (take 1 requestPath == ["metrics"]) $ do
      sharedFilters <- first ("invalid_filter",) $ traverse parseOne [operand | ("filter", operand) <- query]
      first ("invalid_metric",) (UserSelection.validateUserSelection (requestPath `elem` [["metrics", route] | route <- UserSelection.supportedUserSelectionRoutes]) sharedFilters)
      when (any (\(key, operand) -> key == "groupBy" && maybe False (elem "user_id" . BS.split 44) operand) query) (Left ("invalid_group_by", "user_id is filter-only"))
    if take 1 requestPath == ["users"] then mapM_ (\f -> void (first ("invalid_filter",) (validateMetricFilters [f]))) filters else void (first ("invalid_filter",) (validateMetricFilters filters))
  where
    filterErrorCode = case requestPath of
      ["users", _, route] | route `elem` ["events", "hosts"] -> "invalid_users_query"
      _ -> "invalid_filter"
    requestPath = decodePathSegments (rawPathInfo request)
    query = queryString request
    parseOne Nothing = Left "filter requires a JSON object"
    parseOne (Just bytes) = first (const "filter must be UTF-8") (Text.decodeUtf8' bytes) >>= parseMetricFilter

allowedParameters :: [Text] -> Maybe [Text]
allowedParameters = \case
  ["users"] -> Just ["from", "to", "search", "order", "includeBots", "filter", "first", "after", "last", "before"]
  ["users", "activity-counts"] -> Just ["from", "to", "includeBots"]
  ["users", _] -> Just []
  ["users", _, "hosts"] -> Just ["from", "to", "includeBots", "filter"]
  ["users", _, "events"] -> Just ["from", "to", "includeBots", "filter", "first", "after", "last", "before"]
  ["metrics", "custom"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "metric", "events", "aggregation", "property", "quantile", "denominatorEvents", "denominatorAggregation"]
  ["metrics", "acquisition"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "measure", "conversionEvents", "includeBots"]
  ["metrics", "users"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "window", "includeBots", "aggregate", "attribution"]
  ["metrics", endpoint] | endpoint `elem` ["page-views", "stickiness", "lifecycle"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "includeBots"]
  ["metrics", endpoint]
    | endpoint `elem` ["events", "revenue"] ->
        Just ["from", "to", "groupBy", "timeGrain", "filter"]
  ["metrics", endpoint] | endpoint `elem` ["feature-adoption", "conversion", "organizations"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "aggregate", "attribution"]
  ["metrics", "sessions"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "measure", "containsEvent", "includeBots"]
  ["metrics", "paths"] -> Just ["from", "to", "start", "end", "steps", "top", "window", "events", "exclude", "by", "filter"]
  ["metrics", "funnel"] -> Just ["from", "to", "steps", "window", "mode", "measure", "counting", "attribution", "exclude", "groupBy", "filter", "aggregate"]
  ["metrics", "retention"] -> Just ["from", "to", "groupBy", "timeGrain", "filter", "days", "mode", "cohort", "includeBots", "aggregate", "attribution", "period", "startEvent", "returnEvent", "startFilter", "returnFilter"]
  ["metrics", "experiments"] -> Just ["from", "to", "experiment", "timeGrain", "measure", "groupBy", "filter"]
  ["metrics", "experiments", "conversion"] -> Just ["from", "to", "experiment", "event", "groupBy", "filter"]
  ["metrics", "experiments", "funnel"] -> Just ["from", "to", "experiment", "steps", "window", "mode", "measure", "counting", "attribution", "exclude", "groupBy", "filter"]
  _ -> Nothing
