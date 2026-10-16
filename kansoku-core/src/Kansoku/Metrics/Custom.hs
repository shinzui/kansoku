-- | Shared validation for ad-hoc and saved definitions. Names never select builtin code.
module Kansoku.Metrics.Custom (adHocDefinition, validateCustom, customBuiltin, customRequest) where

import Data.Aeson qualified as A
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Kansoku.Event (EventName (..), EventRegistry)
import Kansoku.Metrics.Definition
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Metrics.Query.Dimension (GroupDimension (..), dimensionErrorMessage, resolveDimension)
import Kansoku.Metrics.Query.Filter qualified as Filters
import Kansoku.Metrics.Query.Property (resolveNumericProperty)
import Kansoku.Metrics.Query.Validate (mkSqlName)
import Kansoku.Metrics.Registry (BuiltinMetric (..))
import Kansoku.Prelude

adHocDefinition :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Either Text CustomDefinition
adHocDefinition events aggregation property denominatorEvents denominatorAggregation = do
  names <- maybe (Left "events is required") (Right . T.splitOn ",") events
  kind <- maybe (Left "aggregation is required") (maybe (Left "unknown aggregation") Right . parseAggregationText) aggregation
  let component es agg = MetricDefinition "custom" Nothing (map T.strip es) agg property [] [] Nothing
  if kind == Ratio || isJust denominatorEvents
    then do
      denominator <- maybe (Left "ratio requires denominatorEvents") (Right . T.splitOn ",") denominatorEvents
      denominatorKind <- maybe (Right UniqueCount) (maybe (Left "unknown denominatorAggregation") Right . parseAggregationText) denominatorAggregation
      let numeratorKind = if kind == Ratio then UniqueCount else kind
          componentWithProperty es agg = (component es agg) {aggregationProperty = if agg `elem` [Sum, Average] then property else Nothing}
      unless (isNothing property || any (`elem` [Sum, Average]) [numeratorKind, denominatorKind]) (Left "property requires a numeric aggregation")
      pure (CustomRatio (RatioMetric "custom" Nothing (componentWithProperty names numeratorKind) (componentWithProperty denominator denominatorKind)))
    else do
      unless (isNothing denominatorAggregation) (Left "denominatorAggregation requires denominatorEvents")
      pure (CustomSimple (component names kind))

validateCustom :: EventRegistry -> CustomDefinition -> Either Text ()
validateCustom registry definition = do
  let name = customName definition
  unless (not (T.null (T.strip name)) && T.length name <= 200) (Left "name requires 1..200 characters")
  case definition of
    CustomSimple def -> validate def
    CustomRatio RatioMetric {numerator, denominator} -> do
      validate numerator
      validate denominator
      unless (all (\d -> null (groupBy d) && isNothing (timeGrain d)) [numerator, denominator]) (Left "ratio components cannot specify grouping or timeGrain")
  where
    validate :: MetricDefinition -> Either Text ()
    validate def = do
      unless (not (null (eventNames def)) && length (eventNames def) <= 100) (Left "events requires 1..100 event names")
      void (traverse mkSqlName (eventNames def))
      unless (aggregation def /= Ratio) (Left "use numerator and denominator for ratios")
      case aggregation def of
        Sum -> numeric def
        Average -> numeric def
        _ -> unless (isNothing (aggregationProperty def)) (Left "property is only supported for sum/average")
      inputs <- traverse F.parseMetricFilter (filters def) >>= F.validateMetricFilters
      -- Cohort membership is loaded at execution. Its shape is still checked on write.
      let resolve label
            | label == "cohort" = Right (GroupByCohort "validation" "'in'")
            | Just ident <- T.stripPrefix "cohort:" label, isJust (UUID.fromText ident) = Right (GroupByCohort ident "'in'")
            | otherwise = resolveDimension registry (map EventName (eventNames def)) label
      unless (all (not . T.isPrefixOf "cohort:" . F.dimension) (concatMap F.filterTerms inputs)) (Left "cohort filters require dimension cohort and a UUID operand")
      void (Filters.compileFiltersWith "validation" resolve inputs)
      unless (length (groupBy def) <= 2 && length (groupBy def) == length (nubText (groupBy def))) (Left "groupBy allows at most two distinct dimensions")
      unless ("cohort" `notElem` groupBy def) (Left "cohort grouping requires cohort:<uuid>")
      traverse_ (first dimensionErrorMessage . resolve) (groupBy def)
      traverse_ validateCohort [x | x <- concatMap F.filterTerms inputs, F.dimension x == "cohort"]
    numeric :: MetricDefinition -> Either Text ()
    numeric def = do
      property <- maybe (Left "sum/average require property") Right (aggregationProperty def)
      void (first (T.pack . show) (resolveNumericProperty registry (map EventName (eventNames def)) property))
    nubText = foldr (\x xs -> if x `elem` xs then xs else x : xs) []
    validateCohort input = unless (F.op input `elem` [F.FilterEq, F.FilterNeq] && case F.value input of Just (A.String ident) -> isJust (UUID.fromText ident); _ -> False) (Left "cohort requires eq/neq and a UUID")

customBuiltin :: CustomDefinition -> BuiltinMetric
customBuiltin (CustomSimple def) = Simple def {name = "custom", filters = [], groupBy = []}
customBuiltin (CustomRatio ratio) = Ratioed ratio {name = "custom", numerator = (numerator ratio) {name = "custom_numerator"}, denominator = (denominator ratio) {name = "custom_denominator"}}

-- Saved simple defaults become request inputs before trait/cohort discovery.
customRequest :: CustomDefinition -> Q.QueryRequest -> Either Text Q.QueryRequest
customRequest (CustomSimple def) req = do
  saved <- traverse F.parseMetricFilter (filters def)
  combined <- F.validateMetricFilters (saved <> Q.filters req)
  pure req {Q.filters = combined, Q.groupBy = Q.groupBy req <|> (if null (groupBy def) then Nothing else Just (groupBy def)), Q.timeGrain = Q.timeGrain req <|> timeGrain def}
customRequest (CustomRatio ratio) req = do
  traverse_ (\def -> traverse F.parseMetricFilter (filters def) >>= \saved -> void (F.validateMetricFilters (saved <> Q.filters req))) [numerator ratio, denominator ratio]
  unless (isNothing (Q.timeGrain req)) (Left "custom ratios are unbucketed; omit timeGrain")
  -- Component predicates remain local to each side of the ratio.
  pure req
