-- | Closed metric dimensions, typed sort expressions and nullable text transport.
module Kansoku.Metrics.Query.Dimension
  ( GroupDimension (..),
    DimensionError (..),
    resolveDimension,
    resolveSessionDimension,
    dimensionLabel,
    dimensionType,
    dimensionExpr,
    dimensionErrorMessage,
    groupProjection,
  )
where

import Data.Bifunctor (first)
import Data.Text qualified as Text
import Kansoku.Event (EventName (..), EventRegistry, PropertySpec (..), PropertyType (..), lookupOrganizationTrait, lookupTrait)
import Kansoku.Metrics.Query.Property
import Kansoku.Prelude hiding (index)

data GroupDimension
  = GroupByCohort !Text !Text
  | GroupByOrganization
  | GroupByOrganizationTrait !Text !ScalarType
  | GroupByEventName
  | GroupBySource
  | GroupBySourceService
  | GroupByHost
  | GroupByRoute
  | GroupByChannel
  | GroupByBrowserFamily
  | GroupByOsFamily
  | GroupByDeviceClass
  | GroupByCountryCode
  | GroupByUtmSource
  | GroupByUtmMedium
  | GroupByUtmCampaign
  | GroupByUtmContent
  | GroupByUtmTerm
  | GroupByReferrerHost
  | GroupByBot
  | GroupByEntryPage
  | GroupByExitPage
  | GroupByUserTrait !Text !ScalarType
  | GroupByProperty !PropertyName
  deriving stock (Generic, Eq, Show)

data DimensionError = UnknownDimension !Text | InvalidDimensionProperty !PropertyError
  deriving stock (Generic, Eq, Show)

resolveDimension :: EventRegistry -> [EventName] -> Text -> Either DimensionError GroupDimension
resolveDimension registry events name = case name of
  "organization" -> Right GroupByOrganization
  "event_name" -> Right GroupByEventName
  "source" -> Right GroupBySource
  "source_service" -> Right GroupBySourceService
  "host" -> Right GroupByHost
  "route" -> Right GroupByRoute
  "channel" -> Right GroupByChannel
  "browser_family" -> Right GroupByBrowserFamily
  "os_family" -> Right GroupByOsFamily
  "device_class" -> Right GroupByDeviceClass
  "country_code" -> Right GroupByCountryCode
  "utm_source" -> Right GroupByUtmSource
  "utm_medium" -> Right GroupByUtmMedium
  "utm_campaign" -> Right GroupByUtmCampaign
  "utm_content" -> Right GroupByUtmContent
  "utm_term" -> Right GroupByUtmTerm
  "referrer_host" -> Right GroupByReferrerHost
  "is_bot" -> Right GroupByBot
  _ | Just key <- Text.stripPrefix "org:" name -> case lookupOrganizationTrait key of
    Just PropertySpec {propertyType = PTString} -> Right (GroupByOrganizationTrait key ScalarString)
    Just PropertySpec {propertyType = PTNumber} -> Right (GroupByOrganizationTrait key ScalarNumber)
    _ -> Left (UnknownDimension name)
  _ -> case Text.stripPrefix "user:" name of
    Just key -> case lookupTrait key of
      Just PropertySpec {propertyType = PTString} -> Right (GroupByUserTrait key ScalarString)
      Just PropertySpec {propertyType = PTNumber} -> Right (GroupByUserTrait key ScalarNumber)
      _ -> Left (UnknownDimension name)
    Nothing -> case Text.stripPrefix "prop:" name of
      Nothing -> Left (UnknownDimension name)
      Just property -> GroupByProperty <$> first InvalidDimensionProperty (resolveProperty registry events property)

-- Entry/exit names are scoped to whole-session sources, never ordinary rows.
resolveSessionDimension :: EventRegistry -> [EventName] -> Text -> Either DimensionError GroupDimension
resolveSessionDimension _ _ "entry_page" = Right GroupByEntryPage
resolveSessionDimension _ _ "exit_page" = Right GroupByExitPage
resolveSessionDimension _ _ name | name == "organization" || "org:" `Text.isPrefixOf` name = Left (UnknownDimension name)
resolveSessionDimension registry events name = resolveDimension registry events name

dimensionLabel :: GroupDimension -> Text
dimensionLabel = \case
  GroupByCohort ident _ -> "cohort:" <> ident
  GroupByOrganization -> "organization"
  GroupByOrganizationTrait name _ -> "org:" <> name
  GroupByEventName -> "event_name"
  GroupBySource -> "source"
  GroupBySourceService -> "source_service"
  GroupByHost -> "host"
  GroupByRoute -> "route"
  GroupByChannel -> "channel"
  GroupByBrowserFamily -> "browser_family"
  GroupByOsFamily -> "os_family"
  GroupByDeviceClass -> "device_class"
  GroupByCountryCode -> "country_code"
  GroupByUtmSource -> "utm_source"
  GroupByUtmMedium -> "utm_medium"
  GroupByUtmCampaign -> "utm_campaign"
  GroupByUtmContent -> "utm_content"
  GroupByUtmTerm -> "utm_term"
  GroupByReferrerHost -> "referrer_host"
  GroupByBot -> "is_bot"
  GroupByEntryPage -> "entry_page"
  GroupByExitPage -> "exit_page"
  GroupByUserTrait name _ -> "user:" <> name
  GroupByProperty property -> "prop:" <> propertyNameText property

dimensionType :: GroupDimension -> ScalarType
dimensionType (GroupByOrganizationTrait _ kind) = kind
dimensionType GroupByBot = ScalarBool
dimensionType (GroupByUserTrait _ kind) = kind
dimensionType (GroupByProperty property) = propertyScalarType property
dimensionType _ = ScalarString

dimensionExpr :: GroupDimension -> Text
dimensionExpr = \case
  GroupByCohort _ predicate -> "if(" <> predicate <> ", 'in', 'out')"
  GroupByOrganization -> "nullIf(organization_id, '')"
  GroupByOrganizationTrait name _ -> "org_trait_" <> name
  GroupByEventName -> "nullIf(toString(event_name), '')"
  GroupBySource -> "nullIf(toString(source), '')"
  GroupBySourceService -> "nullIf(source_service, '')"
  GroupByHost -> canonicalDomain "url"
  GroupByRoute -> "nullIf(path(coalesce(url, '')), '')"
  GroupByChannel -> "nullIf(toString(channel), '')"
  GroupByBrowserFamily -> "nullIf(toString(browser_family), '')"
  GroupByOsFamily -> "nullIf(toString(os_family), '')"
  GroupByDeviceClass -> "nullIf(toString(device_class), '')"
  GroupByCountryCode -> "nullIf(toString(country_code), '')"
  GroupByUtmSource -> "nullIf(toString(utm_source), '')"
  GroupByUtmMedium -> "nullIf(toString(utm_medium), '')"
  GroupByUtmCampaign -> "nullIf(toString(utm_campaign), '')"
  GroupByUtmContent -> "nullIf(toString(utm_content), '')"
  GroupByUtmTerm -> "nullIf(toString(utm_term), '')"
  GroupByReferrerHost -> "if(" <> canonicalDomain "referrer" <> " = " <> canonicalDomain "url" <> ", CAST(NULL, 'Nullable(String)'), " <> canonicalDomain "referrer" <> ")"
  GroupByBot -> "is_bot"
  GroupByEntryPage -> "nullIf(path(entry_url), '')"
  GroupByExitPage -> "nullIf(path(exit_url), '')"
  GroupByUserTrait name _ -> "user_trait_" <> name
  GroupByProperty property -> propertyTypedExpr property

canonicalDomain :: Text -> Text
canonicalDomain column = "nullIf(replaceRegexpOne(lowerUTF8(domain(coalesce(" <> column <> ", ''))), '[.]+$', ''), '')"

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
