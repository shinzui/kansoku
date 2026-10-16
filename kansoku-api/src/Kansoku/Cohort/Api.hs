{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}

module Kansoku.Cohort.Api where

import Data.SOP (I (..), NS (..))
import Data.Time (Day)
import Data.UUID (UUID)
import Kansoku.Api.Response
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Cohort.Types
import Kansoku.Prelude
import Relay.Pagination (Connection)
import Relay.Pagination.Servant (RelayPage, RelayPageError)
import Servant.API
import Servant.API.MultiVerb

type Reply a = MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "Cohort result" a) (KansokuResult a)

type PageResponses a = '[RespondAs JSON 200 "Cohort page" (Connection a), RespondAs JSON 400 "Invalid pagination" RelayPageError, RespondAs ProblemJSON 404 "Not found" ProblemDetails, RespondAs ProblemJSON 503 "Storage unavailable" ProblemDetails]

data PageResult a = PageOk (Connection a) | PageBad RelayPageError | PageMissing ProblemDetails | PageUnavailable ProblemDetails

instance AsUnion (PageResponses a) (PageResult a) where
  toUnion = \case
    PageOk x -> Z (I x)
    PageBad x -> S (Z (I x))
    PageMissing x -> S (S (Z (I x)))
    PageUnavailable x -> S (S (S (Z (I x))))
  fromUnion = \case
    Z (I x) -> PageOk x
    S (Z (I x)) -> PageBad x
    S (S (Z (I x))) -> PageMissing x
    S (S (S (Z (I x)))) -> PageUnavailable x
    S (S (S (S impossible))) -> case impossible of {}

type PageReply a = MultiVerb 'GET '[JSON, ProblemJSON] (PageResponses a) (PageResult a)

type AtCohort sub = "cohorts" :> MetricsAuth :> Capture "id" UUID :> sub

data Cohorts mode = Cohorts
  { createCohort :: mode :- "cohorts" :> MetricsAuth :> ReqBody '[JSON] CohortDefinition :> MultiVerb 'POST '[JSON, ProblemJSON] (OkResponses "Saved cohort" Cohort) (KansokuResult Cohort),
    getCohort :: mode :- AtCohort (Reply Cohort),
    listCohorts :: mode :- "cohorts" :> MetricsAuth :> RelayPage 20 100 :> PageReply Cohort,
    updateCohort :: mode :- AtCohort (ReqBody '[JSON] CohortDefinition :> MultiVerb 'PUT '[JSON, ProblemJSON] (OkResponses "Saved cohort" Cohort) (KansokuResult Cohort)),
    deleteCohort :: mode :- AtCohort (MultiVerb 'DELETE '[JSON, ProblemJSON] (OkResponses "Deleted cohort" Bool) (KansokuResult Bool)),
    putMembers :: mode :- AtCohort ("members" :> ReqBody '[JSON] CohortMembers :> MultiVerb 'PUT '[JSON, ProblemJSON] (OkResponses "Cohort size" CohortSize) (KansokuResult CohortSize)),
    getMembers :: mode :- AtCohort ("members" :> QueryParam' '[Required, Strict] "from" Day :> QueryParam' '[Required, Strict] "to" Day :> RelayPage 20 100 :> PageReply Text),
    getSize :: mode :- AtCohort ("size" :> QueryParam' '[Required, Strict] "from" Day :> QueryParam' '[Required, Strict] "to" Day :> Reply CohortSize)
  }
  deriving stock (Generic)
