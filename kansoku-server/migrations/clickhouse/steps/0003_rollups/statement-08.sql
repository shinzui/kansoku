

-- ---------- Page views by route ----------
-- url is Nullable(String) in EP-3's schema; coalesce(url, '') keeps path()
-- non-Nullable so the insert into the String route column cannot fail.
CREATE TABLE IF NOT EXISTS analytics.page_views_by_route
(
    day   Date,
    route String,
    views AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, route);