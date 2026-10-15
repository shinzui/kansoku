-- | Whole retained session attributes shared by sessions and acquisition.
module Kansoku.Metrics.Query.Session (sessionProjection, materializedSessionProjection) where

import Data.Text qualified as Text
import Kansoku.Prelude hiding (index)

attributes :: [Text]
attributes = ["event_name", "source", "url", "referrer", "utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term", "browser_family", "os_family", "device_class", "channel", "country_code"]

engagementPredicate :: Text
engagementPredicate = "event_name NOT IN ('page_view','session_start','page_leave','identify','identify_once','alias','group','experiment_viewed')"

project :: Text -> Text
project body =
  Text.unlines
    [ "SELECT account_id,source_service,session_id,session_start_at AS occurred_at,session_end_at,page_view_count,engagement_count,entry_url,exit_url,session_is_bot AS is_bot,primary_subject,",
      Text.intercalate "," ["attribution." <> Text.pack (show index) <> " AS " <> name | (index, name) <- zip [1 :: Int ..] attributes],
      ",CAST(if(isValidJSON(attribution.15),attribution.15,'{}') AS JSON(max_dynamic_paths=128)) AS properties_json",
      "FROM (",
      body,
      ")"
    ]

-- | Canonical reference and identity-aware fallback. The source and subject
-- fragments belong to the compiler; callers cannot supply arbitrary SQL.
sessionProjection :: Text -> Bool -> Text
sessionProjection source resolved =
  project $
    Text.unlines
      [ "SELECT account_id,source_service,session_id,min(occurred_at) AS session_start_at,max(occurred_at) AS session_end_at,max(is_bot) AS session_is_bot,",
        "uniqExactIf(event_id,event_name='page_view') AS page_view_count,uniqExactIf(event_id," <> engagementPredicate <> ") AS engagement_count,",
        "argMinIf(tuple(url),tuple(occurred_at,event_id),event_name='page_view').1 AS entry_url,argMaxIf(tuple(url),tuple(occurred_at,event_id),event_name='page_view').1 AS exit_url,",
        "if(page_view_count>0,argMinIf(" <> attribution <> ",tuple(occurred_at,event_id),event_name='page_view'),argMin(" <> attribution <> ",tuple(occurred_at,event_id))) AS attribution,",
        subject <> " AS primary_subject",
        "FROM " <> source,
        "WHERE account_id={account_id:String} AND source='web' AND session_id!=''",
        "GROUP BY account_id,source_service,session_id"
      ]
  where
    attribution = "tuple(" <> Text.intercalate "," (map (\name -> "toString(" <> name <> ")") (attributes <> ["properties"])) <> ")"
    subject
      | resolved = "coalesce(nullIf(argMinIf(canonical_user,tuple(occurred_at,event_id),startsWith(canonical_user,'user:')),''),nullIf(argMinIf(canonical_user,tuple(occurred_at,event_id),startsWith(canonical_user,'anonymous:')),''),'')"
      | otherwise = "''"

-- | Finalize states across every retained block/part before applying dates.
materializedSessionProjection :: Text
materializedSessionProjection =
  project $
    Text.unlines
      [ "SELECT account_id,source_service,session_id,minMerge(started) AS session_start_at,maxMerge(ended) AS session_end_at,maxMerge(bot) AS session_is_bot,",
        "uniqExactIfMerge(page_ids) AS page_view_count,uniqExactIfMerge(engagement_ids) AS engagement_count,",
        "argMinIfMerge(first_page).3 AS entry_url,argMaxIfMerge(last_page).1 AS exit_url,",
        "if(page_view_count>0,argMinIfMerge(first_page),argMinMerge(first_event)) AS attribution,'' AS primary_subject",
        "FROM analytics.sessions WHERE account_id={account_id:String}",
        "GROUP BY account_id,source_service,session_id"
      ]
