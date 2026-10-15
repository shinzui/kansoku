-- | Registry-validated event properties that are safe to render in metric SQL.
module Kansoku.Metrics.Query.Property
  ( PropertyError (..),
    PropertyName,
    propertyEqualsPredicate,
    propertyFloatExpr,
    propertyGroupExpr,
    propertyNameText,
    resolveNumericProperty,
    resolveProperty,
  )
where

import Data.Aeson qualified as Aeson
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Foldable (traverse_)
import Data.List (find)
import Data.Text qualified as Text
import Kansoku.Event
  ( EventName,
    EventRegistry,
    EventSchema (..),
    PropertySpec (..),
    PropertyType (..),
    latestSchema,
  )
import Kansoku.Prelude

newtype PropertyName = PropertyName Text
  deriving stock (Generic, Eq, Ord, Show)

data PropertyError
  = PropertyErrorBadName !Text
  | PropertyErrorUnscopedMetric !Text
  | PropertyErrorUndeclared !Text !EventName
  | PropertyErrorNotNumeric !Text !EventName
  | PropertyErrorUnsupportedFilterValue !Text !Aeson.Value
  deriving stock (Generic, Eq, Show)

propertyNameText :: PropertyName -> Text
propertyNameText (PropertyName value) = value

resolveProperty :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
resolveProperty registry events value
  | not (validPropertyName value) = Left (PropertyErrorBadName value)
  | null events = Left (PropertyErrorUnscopedMetric value)
  | otherwise = do
      traverse_ (declaredProperty registry value) events
      pure (PropertyName value)

resolveNumericProperty :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
resolveNumericProperty registry events value = do
  property <- resolveProperty registry events value
  traverse_ (numericProperty registry value) events
  pure property

propertyGroupExpr :: PropertyName -> Text
propertyGroupExpr property = "toString(" <> propertySubcolumnExpr property <> ")"

propertyFloatExpr :: PropertyName -> Text
propertyFloatExpr property = "CAST(" <> propertySubcolumnExpr property <> ", 'Float64')"

propertyEqualsPredicate :: PropertyName -> Aeson.Value -> Either PropertyError Text
propertyEqualsPredicate property = \case
  Aeson.String value -> Right (propertyGroupExpr property <> " = " <> sqlString value)
  Aeson.Number value -> Right (propertyFloatExpr property <> " = " <> Text.pack (show value))
  Aeson.Bool value ->
    Right
      ( "CAST("
          <> propertySubcolumnExpr property
          <> ", 'Bool') = "
          <> if value then "true" else "false"
      )
  unsupported -> Left (PropertyErrorUnsupportedFilterValue (propertyNameText property) unsupported)

validPropertyName :: Text -> Bool
validPropertyName value =
  Text.length value >= 1
    && Text.length value <= 64
    && Text.all allowed value
  where
    allowed char =
      isAsciiLower char
        || isAsciiUpper char
        || isDigit char
        || char == '_'

declaredProperty :: EventRegistry -> Text -> EventName -> Either PropertyError ()
declaredProperty registry property event =
  case latestSchema event registry >>= findProperty property of
    Just _ -> Right ()
    Nothing -> Left (PropertyErrorUndeclared property event)

numericProperty :: EventRegistry -> Text -> EventName -> Either PropertyError ()
numericProperty registry property event =
  case latestSchema event registry >>= findProperty property of
    Just PropertySpec {propertyType = PTNumber} -> Right ()
    Just PropertySpec {propertyType = PTAny} -> Right ()
    _ -> Left (PropertyErrorNotNumeric property event)

findProperty :: Text -> EventSchema -> Maybe PropertySpec
findProperty property EventSchema {properties} =
  find (\PropertySpec {name} -> name == property) properties

sqlString :: Text -> Text
sqlString value =
  "'" <> Text.replace "\\" "\\\\" (Text.replace "'" "\\'" value) <> "'"

propertySubcolumnExpr :: PropertyName -> Text
propertySubcolumnExpr property =
  -- Unlike dot syntax, getSubcolumn also works when the JSON value crosses a view expression.
  "getSubcolumn(properties_json, " <> sqlString (propertyNameText property) <> ")"
