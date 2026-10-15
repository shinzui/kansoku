-- | Closed metric dimensions, typed sort expressions and nullable text transport.
module Kansoku.Metrics.Query.Dimension
  ( GroupDimension (..),
    DimensionError (..),
    resolveDimension,
    dimensionLabel,
    dimensionType,
    dimensionExpr,
    dimensionErrorMessage,
    groupProjection,
  )
where

import Data.Bifunctor (first)
import Data.Text qualified as Text
import Kansoku.Event (EventName (..), EventRegistry)
import Kansoku.Metrics.Query.Property
import Kansoku.Prelude hiding (index)

data GroupDimension
  = GroupByEventName
  | GroupBySource
  | GroupBySourceService
  | GroupByHost
  | GroupByRoute
  | GroupByProperty !PropertyName
  deriving stock (Generic, Eq, Show)

data DimensionError = UnknownDimension !Text | InvalidDimensionProperty !PropertyError
  deriving stock (Generic, Eq, Show)

resolveDimension :: EventRegistry -> [EventName] -> Text -> Either DimensionError GroupDimension
resolveDimension registry events name = case name of
  "event_name" -> Right GroupByEventName
  "source" -> Right GroupBySource
  "source_service" -> Right GroupBySourceService
  "host" -> Right GroupByHost
  "route" -> Right GroupByRoute
  _ -> case Text.stripPrefix "prop:" name of
    Nothing -> Left (UnknownDimension name)
    Just property -> GroupByProperty <$> first InvalidDimensionProperty (resolveProperty registry events property)

dimensionLabel :: GroupDimension -> Text
dimensionLabel = \case
  GroupByEventName -> "event_name"
  GroupBySource -> "source"
  GroupBySourceService -> "source_service"
  GroupByHost -> "host"
  GroupByRoute -> "route"
  GroupByProperty property -> "prop:" <> propertyNameText property

dimensionType :: GroupDimension -> ScalarType
dimensionType (GroupByProperty property) = propertyScalarType property
dimensionType _ = ScalarString

dimensionExpr :: GroupDimension -> Text
dimensionExpr = \case
  GroupByEventName -> "nullIf(toString(event_name), '')"
  GroupBySource -> "nullIf(toString(source), '')"
  GroupBySourceService -> "nullIf(source_service, '')"
  GroupByHost -> "nullIf(lowerUTF8(domain(coalesce(url, ''))), '')"
  GroupByRoute -> "nullIf(path(coalesce(url, '')), '')"
  GroupByProperty property -> propertyTypedExpr property

-- The sort columns keep their scalar types; JSON is only the native transport.
groupProjection :: [GroupDimension] -> Text
groupProjection dimensions =
  "toJSONString(["
    <> Text.intercalate ", " ["toString(sort_group_" <> Text.pack (show index) <> ")" | index <- [1 .. length dimensions]]
    <> "]) AS group_key, "
    <> Text.intercalate ", " [expression index <> " AS sort_group_" <> Text.pack (show index) | index <- [1, 2 :: Int]]
  where
    expression index = case drop (index - 1) dimensions of
      dimension : _ -> dimensionExpr dimension
      [] -> "CAST(NULL, 'Nullable(String)')"

dimensionErrorMessage :: DimensionError -> Text
dimensionErrorMessage = \case
  UnknownDimension name -> "invalid dimension: " <> name
  InvalidDimensionProperty failure -> case failure of
    PropertyErrorBadName name -> "invalid property name: " <> name
    PropertyErrorUnscopedMetric name -> "property requires a finite declared event scope: " <> name
    PropertyErrorUndeclared name event -> "unknown property " <> name <> " for event " <> unEventName event
    PropertyErrorNotNumeric name event -> "property is not numeric: " <> unEventName event <> "." <> name
    PropertyErrorNotScalar name event -> "property requires a declared scalar type: " <> unEventName event <> "." <> name
    PropertyErrorIncompatibleTypes name -> "property declarations have incompatible scalar types: " <> name
