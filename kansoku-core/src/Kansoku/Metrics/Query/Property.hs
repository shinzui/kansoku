-- | Registry-validated scalar properties and safe native-JSON extraction.
module Kansoku.Metrics.Query.Property
  ( PropertyError (..),
    PropertyName,
    ScalarType (..),
    propertyFloatExpr,
    propertyGroupExpr,
    propertyTypedExpr,
    propertyNameText,
    propertyScalarType,
    resolveNumericProperty,
    resolveProperty,
    resolveOptionalProperty,
  )
where

import Data.Foldable (toList)
import Data.List (find, nub)
import Data.Text qualified as Text
import Kansoku.Event
  ( EventName,
    EventRegistry,
    EventSchema (..),
    PropertySpec (..),
    PropertyType (..),
    lookupVersions,
  )
import Kansoku.Prelude

data ScalarType = ScalarString | ScalarNumber | ScalarBool
  deriving stock (Generic, Eq, Ord, Show)

data PropertyName = PropertyName !Text !ScalarType
  deriving stock (Generic, Eq, Ord, Show)

data PropertyError
  = PropertyErrorBadName !Text
  | PropertyErrorUnscopedMetric !Text
  | PropertyErrorUndeclared !Text !EventName
  | PropertyErrorNotNumeric !Text !EventName
  | PropertyErrorNotScalar !Text !EventName
  | PropertyErrorIncompatibleTypes !Text
  deriving stock (Generic, Eq, Show)

propertyNameText :: PropertyName -> Text
propertyNameText (PropertyName name _) = name

propertyScalarType :: PropertyName -> ScalarType
propertyScalarType (PropertyName _ kind) = kind

resolveProperty :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
resolveProperty registry events name
  | not (validPropertyName name) = Left (PropertyErrorBadName name)
  | null events = Left (PropertyErrorUnscopedMetric name)
  | otherwise = do
      types <- concat <$> traverse declaredTypes events
      case nub types of
        [kind] -> Right (PropertyName name kind)
        _ -> Left (PropertyErrorIncompatibleTypes name)
  where
    declaredTypes event = do
      let declarations = [spec | schema <- maybe [] toList (lookupVersions event registry), Just spec <- [findProperty name schema]]
      unless (not (null declarations)) (Left (PropertyErrorUndeclared name event))
      traverse (scalar event . propertyType) declarations
    scalar _ PTString = Right ScalarString
    scalar _ PTNumber = Right ScalarNumber
    scalar _ PTBool = Right ScalarBool
    scalar event _ = Left (PropertyErrorNotScalar name event)

-- | Funnel attribution may select an event on which a known property is absent.
-- Require a declaration somewhere in the finite scope and compatible declared
-- types, while retaining NULL extraction for the other steps.
resolveOptionalProperty :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
resolveOptionalProperty registry events name =
  let declared event = any (isJust . findProperty name) (maybe [] toList (lookupVersions event registry))
      scope = filter declared events
   in resolveProperty registry (if null scope then events else scope) name

resolveNumericProperty :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
resolveNumericProperty registry events name = do
  property <- resolveProperty registry events name
  case (propertyScalarType property, events) of
    (ScalarNumber, _) -> Right property
    (_, event : _) -> Left (PropertyErrorNotNumeric name event)
    _ -> Left (PropertyErrorUnscopedMetric name)

-- Missing, null and historical incompatible values all produce SQL NULL.
-- Safe conversion never parses an unguarded historical string as a number.
propertyTypedExpr :: PropertyName -> Text
propertyTypedExpr property =
  let expression = propertySubcolumnExpr property
      numeric = "toFloat64OrNull(toString(" <> expression <> "))"
   in case propertyScalarType property of
        ScalarString -> "dynamicElement(" <> expression <> ", 'String')"
        ScalarBool -> "dynamicElement(" <> expression <> ", 'Bool')"
        ScalarNumber ->
          "if(dynamicType(" <> expression <> ") IN ('Int64','UInt64','Float64') AND isFinite(" <> numeric <> "), " <> numeric <> ", CAST(NULL, 'Nullable(Float64)'))"

propertyGroupExpr :: PropertyName -> Text
propertyGroupExpr property = "toString(" <> propertyTypedExpr property <> ")"

propertyFloatExpr :: PropertyName -> Text
propertyFloatExpr = propertyTypedExpr

validPropertyName :: Text -> Bool
validPropertyName name =
  Text.length name >= 1 && Text.length name <= 64 && Text.all allowed name
  where
    allowed char = (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9') || char == '_'

findProperty :: Text -> EventSchema -> Maybe PropertySpec
findProperty name EventSchema {properties} = find (\PropertySpec {name = candidate} -> name == candidate) properties

propertySubcolumnExpr :: PropertyName -> Text
propertySubcolumnExpr property =
  "getSubcolumn(properties_json, '" <> propertyNameText property <> "')"
