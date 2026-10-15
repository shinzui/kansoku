-- | Canonical query-time session attributes. EP-34 owns materialized session state.
module Kansoku.Metrics.Query.Session (sessionProjection) where

import Data.Text qualified as Text
import Kansoku.Prelude

-- | Assemble the entire retained session before applying date or attribute
-- filters. Source and subject selection are compiler-owned SQL fragments.
sessionProjection :: Text -> Bool -> Text
sessionProjection source resolved =
  Text.unlines
    [ "SELECT account_id,source_service,session_id,session_start_at AS occurred_at,session_is_bot AS is_bot,primary_subject,",
      Text.intercalate "," ["attribution." <> Text.pack (show index) <> " AS " <> name | (index, name) <- zip [1 :: Int ..] attributes],
      ",CAST(if(isValidJSON(attribution.15),attribution.15,'{}') AS JSON(max_dynamic_paths=128)) AS properties_json",
      "FROM (",
      "SELECT account_id,source_service,session_id,min(occurred_at) AS session_start_at,max(is_bot) AS session_is_bot,",
      "if(countIf(event_name='page_view')>0,argMinIf(" <> attribution <> ",tuple(occurred_at,event_id),event_name='page_view'),argMin(" <> attribution <> ",tuple(occurred_at,event_id))) AS attribution,",
      subject <> " AS primary_subject",
      "FROM " <> source,
      "WHERE account_id={account_id:String} AND source='web' AND session_id!=''",
      "GROUP BY account_id,source_service,session_id",
      ")"
    ]
  where
    attributes = ["event_name", "source", "url", "referrer", "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "browser_family", "os_family", "device_class", "channel", "country_code"]
    attribution = "tuple(" <> Text.intercalate "," (attributes <> ["properties"]) <> ")"
    subject
      | resolved = "coalesce(nullIf(argMinIf(canonical_user,tuple(occurred_at,event_id),startsWith(canonical_user,'user:')),''),nullIf(argMinIf(canonical_user,tuple(occurred_at,event_id),startsWith(canonical_user,'anonymous:')),''),'')"
      | otherwise = "''"
