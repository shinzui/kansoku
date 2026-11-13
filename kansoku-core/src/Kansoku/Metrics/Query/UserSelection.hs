-- | Discovery and semantic validation shared by HTTP, saved definitions and core queries.
module Kansoku.Metrics.Query.UserSelection
  ( hasUserSelection,
    validateUserSelection,
    supportedUserSelectionRoutes,
    userSelectionDimension,
  )
where

import Data.Aeson qualified as A
import Data.Foldable (toList, traverse_)
import Data.Text qualified as T
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Limits (maxSelectedUserIds)
import Kansoku.Metrics.Query.Dimension
import Kansoku.Prelude

supportedUserSelectionRoutes :: [Text]
supportedUserSelectionRoutes = ["events", "page-views", "users", "sessions", "acquisition", "revenue", "feature-adoption", "custom"]

hasUserSelection :: [F.MetricFilter] -> Bool
hasUserSelection = any ((== "user_id") . F.dimension) . concatMap F.filterTerms

validateUserSelection :: Bool -> [F.MetricFilter] -> Either Text ()
validateUserSelection supported inputs = traverse_ validate [term | term <- concatMap F.filterTerms inputs, F.dimension term == "user_id"]
  where
    validate term = do
      unless supported (Left "user_id is unsupported on this metric")
      case (F.op term, F.value term) of
        (operator, Just (A.String ident)) | operator `elem` [F.FilterEq, F.FilterNeq] -> nonempty ident
        (F.FilterIn, Just (A.Array values)) -> do
          unless (length values >= 1 && length values <= maxSelectedUserIds) (Left "user_id in requires 1..20 string IDs")
          traverse_ (\case A.String ident -> nonempty ident; _ -> Left "user_id requires string IDs") (toList values)
        _ -> Left "user_id supports only eq/neq with a string or in with 1..20 strings"
    nonempty ident = when (T.null ident) (Left "user_id requires nonempty string IDs")

-- Only filter resolvers opt in; grouping and cohort conditions remain closed.
userSelectionDimension :: Bool -> (Text -> Either DimensionError GroupDimension) -> Text -> Either DimensionError GroupDimension
userSelectionDimension session fallback label
  | label == "user_id" = Right (FilterByIdentifiedUser session)
  | otherwise = fallback label
