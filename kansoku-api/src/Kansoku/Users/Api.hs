{-# LANGUAGE DataKinds #-}

module Kansoku.Users.Api where

import Data.Time (Day)
import Kansoku.Api.Response
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Cohort.Api (PageReply)
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Prelude
import Kansoku.Users.Types
import Relay.Pagination.Servant (RelayPage)
import Servant.API
import Servant.API.MultiVerb

type RequiredDates sub = QueryParam' '[Required, Strict] "from" Day :> QueryParam' '[Required, Strict] "to" Day :> sub

type Dates sub = QueryParam "from" Day :> QueryParam "to" Day :> sub

data Users mode = Users
  { activityCounts :: mode :- "users" :> "activity-counts" :> MetricsAuth :> Description "Exact distinct identified and anonymous activity subjects. Required paired UTC dates [from,to), 1..366 days; includeBots defaults false. Excludes identify/identify_once/alias/group and empty subjects. Sum equals whole-range metrics/users with timeGrain=none. No directory filters." :> RequiredDates (QueryParam "includeBots" Bool :> MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "Exact activity counts" UserActivityCounts) (KansokuResult UserActivityCounts)),
    events :: mode :- "users" :> MetricsAuth :> Capture "userId" Text :> "events" :> Description "Resolved retained history including pre-login and identity events. Paired optional UTC dates [from,to), 1..366 days; includeBots defaults false. At most one event_name eq/in term (1..100 names of 1..128 characters) and one host eq/in term (1..100 canonical lowercase hosts of 1..253 characters without scheme, port, path, whitespace or trailing dot), ANDed. Host matches node host; null hosts never match a host term. Occurrence/receipt/event ID descending. Exact-version declared scalar properties only, excluding identifiers, alias payloads and context. Identity/group properties require governed catalogs. Relay page size 1..100, default 20; both directions, current reads without snapshot. Unknown/foreign/erased user: user_not_found 404. Nonpagination errors use problem+json; Relay pagination errors use JSON." :> Dates (QueryParam "includeBots" Bool :> QueryParams "filter" MetricFilter :> RelayPage 20 100 :> PageReply UserEvent),
    hosts :: mode :- "users" :> MetricsAuth :> Capture "userId" Text :> "hosts" :> Description "Complete exact host counts for resolved retained history, including identity and pre-login events. Optional paired UTC dates [from,to), 1..366 days; includeBots defaults false. At most one event_name eq/in filter (1..100 names of 1..128 characters); host filters rejected. Same selection as history. Non-null hosts ordered by eventCount descending then host ascending; one null-host entry last, zero counts omitted. Sum of selected entries equals filtered history size for the same parameters on settled data; current reads without cross-request snapshot. At most 1000 entries including null, otherwise user_hosts_too_large 400 without partial output. Unknown/foreign/erased user: user_not_found 404; query failure/deadline: clickhouse_unavailable 503." :> Dates (QueryParam "includeBots" Bool :> QueryParams "filter" MetricFilter :> MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "User hosts" UserHosts) (KansokuResult UserHosts)),
    getProfile :: mode :- "users" :> MetricsAuth :> Capture "userId" Text :> Description "Current identified-user profile. RetainedEventCount includes all event kinds and bots; activity extrema exclude bots and identify/identify_once/alias/group. Traits include winning observedAt and set/set_once provenance. Evidence counts never expose values and fingerprint validity is 180 days; resolvedAnonymousCount counts original anonymous subjects stitched to this user. Organization is current explicit membership with governed traits or null. Unknown, foreign and erased users share user_not_found 404. One deadline and owned connection, eventual cross-table consistency. Analytical inference, never authorization." :> MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "User profile" UserProfile) (KansokuResult UserProfile),
    directory :: mode :- "users" :> MetricsAuth :> Description "Identified-user Relay directory. Optional paired UTC dates [from,to), 1..366 days, select activity but extrema span all retained history. search is literal case-insensitive substring, 1..256 code points. order is lastActivity (default) or firstActivity: timestamp descending, null last, userId ascending. includeBots defaults false; identify/identify_once/alias/group are not activity. Without dates profile-only users have null extrema. Up to eight typed user trait filters and one cohort eq/neq UUID, AND only, 16384 decoded bytes. Page size 1..100, default 20, first/after or last/before. Keep selections fixed; current reads require refresh/deduplication after concurrent changes. Exhaustion is a complete error; unknown/repeated scalar parameters are rejected. Relay pagination errors use JSON, other errors problem+json." :> Dates (QueryParam "search" Text :> QueryParam "order" Text :> QueryParam "includeBots" Bool :> QueryParams "filter" MetricFilter :> RelayPage 20 100 :> PageReply UserSummary)
  }
  deriving stock (Generic)
