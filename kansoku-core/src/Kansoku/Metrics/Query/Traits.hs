-- | One bounded current-trait pivot per resolved source. Trait names are chosen
-- only from the shared ingest catalog; no caller text becomes an SQL identifier.
module Kansoku.Metrics.Query.Traits
  ( referencedTraits,
    eventSource,
    organizationSource,
    referencedOrganizationTraits,
    sessionSource,
  )
where

import Data.List (nub)
import Data.Text qualified as Text
import Kansoku.Event (PropertySpec (..), PropertyType (..), lookupOrganizationTrait, lookupTrait)
import Kansoku.Prelude

referencedTraits :: [Text] -> [Text]
referencedTraits dimensions = nub [name | dimension <- dimensions, Just name <- [Text.stripPrefix "user:" dimension], isJust (lookupTrait name)]

eventSource :: [Text] -> Text -> Text
eventSource [] source = source
eventSource names source = "(" <> attach names "e.subject_kind='user' AND e.subject_id=traits.user_id" source <> ")"

sessionSource :: [Text] -> Text -> Text
sessionSource [] source = source
sessionSource names source = attach names "startsWith(e.primary_subject,'user:') AND substring(e.primary_subject,6)=traits.user_id" ("(" <> source <> ")")

attach :: [Text] -> Text -> Text -> Text
attach names predicate source =
  "SELECT e.*,"
    <> Text.intercalate "," ["traits.user_trait_" <> name <> " AS user_trait_" <> name | name <- names]
    <> " FROM "
    <> source
    <> " AS e LEFT JOIN (SELECT account_id,user_id,"
    <> Text.intercalate "," (map projection names)
    <> " FROM analytics.user_traits WHERE account_id={account_id:String} AND name IN ("
    <> Text.intercalate "," ["'" <> name <> "'" | name <- names]
    <> ") GROUP BY account_id,user_id) AS traits ON e.account_id=traits.account_id AND "
    <> predicate

projection :: Text -> Text
projection name =
  let (column, kind) = case lookupTrait name of
        Just PropertySpec {propertyType = PTNumber} -> ("number_value", "Float64")
        _ -> ("text_value", "String")
   in "if(countIf(name='" <> name <> "')>0,anyIf(" <> column <> ",name='" <> name <> "'),CAST(NULL,'Nullable(" <> kind <> ")')) AS user_trait_" <> name

referencedOrganizationTraits :: [Text] -> [Text]
referencedOrganizationTraits dimensions = nub [name | dimension <- dimensions, Just name <- [Text.stripPrefix "org:" dimension], isJust (lookupOrganizationTrait name)]

organizationSource :: [Text] -> Text -> Text
organizationSource [] source = source
organizationSource names source =
  "(SELECT e.*,"
    <> Text.intercalate "," ["traits.org_trait_" <> name <> " AS org_trait_" <> name | name <- names]
    <> " FROM "
    <> source
    <> " AS e LEFT JOIN (SELECT account_id,organization_id,"
    <> Text.intercalate "," (map project names)
    <> " FROM analytics.organization_traits WHERE account_id={account_id:String} AND name IN ("
    <> Text.intercalate "," ["'" <> name <> "'" | name <- names]
    <> ") GROUP BY account_id,organization_id) AS traits ON e.account_id=traits.account_id AND e.organization_id=traits.organization_id)"
  where
    project name =
      let (column, kind) = case lookupOrganizationTrait name of
            Just PropertySpec {propertyType = PTNumber} -> ("number_value", "Float64")
            _ -> ("text_value", "String")
       in "if(countIf(name='" <> name <> "')>0,anyIf(" <> column <> ",name='" <> name <> "'),CAST(NULL,'Nullable(" <> kind <> ")')) AS org_trait_" <> name
