-- | Compile validated filter operators and bind every operand natively.
module Kansoku.Metrics.Query.Filter
  ( CompiledFilters (..),
    compileMetricFilters,
    compileMetricFiltersWithPrefix,
    compileFiltersWith,
    filteredEventScope,
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList, traverse_)
import Data.List (intersect, nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Event (EventName (..), EventRegistry)
import Kansoku.Metrics.Filter qualified as Wire
import Kansoku.Metrics.Query.Dimension
import Kansoku.Metrics.Query.Property (ScalarType (..))
import Kansoku.Prelude hiding (index)

data CompiledFilters = CompiledFilters
  { predicates :: ![Text],
    parameters :: ![(String, Text)]
  }
  deriving stock (Generic, Eq, Show)

compileMetricFilters :: EventRegistry -> [EventName] -> [Wire.MetricFilter] -> Either Text CompiledFilters
compileMetricFilters = compileMetricFiltersWithPrefix "metric_filter"

compileMetricFiltersWithPrefix :: String -> EventRegistry -> [EventName] -> [Wire.MetricFilter] -> Either Text CompiledFilters
compileMetricFiltersWithPrefix prefix registry scope = compileFiltersWith prefix (resolveDimension registry scope)

compileFiltersWith :: String -> (Text -> Either DimensionError GroupDimension) -> [Wire.MetricFilter] -> Either Text CompiledFilters
compileFiltersWith prefix resolve inputs = do
  filters <- Wire.validateMetricFilters inputs
  compiled <- traverse compileOne (zip [1 :: Int ..] filters)
  pure (CompiledFilters (map fst compiled) (concatMap snd compiled))
  where
    compileOne (index, input) = do
      dimension <- first dimensionErrorMessage (resolve (Wire.dimension input))
      let expression = dimensionExpr dimension
          kind = dimensionType dimension
          operands = case Wire.value input of
            Just (Aeson.Array values) -> toList values
            Just operand -> [operand]
            Nothing -> []
      traverse_ (compatible kind) operands
      let bindings = zipWith (\position operand -> (parameterName prefix index position, operandText operand)) [1 :: Int ..] operands
          placeholders = [parameter kind name | (name, _) <- bindings]
          comparison operator = case placeholders of
            [placeholder] -> Right ("coalesce((" <> expression <> " " <> operator <> " " <> placeholder <> "), false)", bindings)
            _ -> Left "filter requires one operand"
      case Wire.op input of
        Wire.FilterSet -> Right ("isNotNull(" <> expression <> ")", [])
        Wire.FilterUnset -> Right ("isNull(" <> expression <> ")", [])
        Wire.FilterEq -> comparison "="
        Wire.FilterNeq -> comparison "!="
        Wire.FilterGt | kind == ScalarNumber -> comparison ">"
        Wire.FilterLt | kind == ScalarNumber -> comparison "<"
        Wire.FilterContains
          | kind == ScalarString,
            [placeholder] <- placeholders ->
              Right ("coalesce(positionUTF8(" <> expression <> ", " <> placeholder <> ") > 0, false)", bindings)
        Wire.FilterIn -> Right ("coalesce(" <> expression <> " IN (" <> Text.intercalate ", " placeholders <> "), false)", bindings)
        _ -> Left "operator requires a compatible declared scalar dimension"
    compatible ScalarString (Aeson.String _) = Right ()
    compatible ScalarNumber (Aeson.Number _) = Right ()
    compatible ScalarBool (Aeson.Bool _) = Right ()
    compatible _ _ = Left "filter operand does not match the declared dimension type"

parameterName :: String -> Int -> Int -> String
parameterName prefix index position = prefix <> "_" <> show index <> "_" <> show position

parameter :: ScalarType -> String -> Text
parameter kind name =
  let placeholder = "{" <> Text.pack name <> ":String}"
   in case kind of
        ScalarString -> placeholder
        ScalarNumber -> "toFloat64(" <> placeholder <> ")"
        ScalarBool -> "toUInt8(" <> placeholder <> ")"

operandText :: Aeson.Value -> Text
operandText = \case
  Aeson.String text -> text
  Aeson.Bool boolean -> if boolean then "1" else "0"
  operand -> Text.decodeUtf8 (LBS.toStrict (Aeson.encode operand))

-- Only positive eq/in event-name predicates establish a finite event scope.
filteredEventScope :: [EventName] -> [Wire.MetricFilter] -> [EventName]
filteredEventScope declared inputs =
  case positive of
    [] -> declared
    firstScope : rest -> foldl intersect (if null declared then firstScope else declared `intersect` firstScope) rest
  where
    positive = [nub (map EventName values) | input <- inputs, Wire.dimension input == "event_name", Just values <- [positiveValues input]]
    positiveValues input = case (Wire.op input, Wire.value input) of
      (Wire.FilterEq, Just (Aeson.String value)) -> Just [value]
      (Wire.FilterIn, Just (Aeson.Array values)) -> traverse (\case Aeson.String value -> Just value; _ -> Nothing) (toList values)
      _ -> Nothing
