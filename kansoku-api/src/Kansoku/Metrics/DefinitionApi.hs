-- | Account-scoped saved metric definitions and cursor pages.
module Kansoku.Metrics.DefinitionApi where

import Data.UUID (UUID)
import Kansoku.Api.Response
import Kansoku.Auth.Api (MetricsAuth)
import Kansoku.Cohort.Api (PageReply)
import Kansoku.Metrics.Definition
import Kansoku.Prelude
import Relay.Pagination.Servant (RelayPage)
import Servant.API
import Servant.API.MultiVerb

type AtDefinition sub = "metric-definitions" :> MetricsAuth :> Capture "id" UUID :> sub

data MetricDefinitions mode = MetricDefinitions
  { createDefinition :: mode :- "metric-definitions" :> MetricsAuth :> ReqBody '[JSON] CustomDefinition :> MultiVerb 'POST '[JSON, ProblemJSON] (OkResponses "Saved metric" SavedMetric) (KansokuResult SavedMetric),
    getDefinition :: mode :- AtDefinition (MultiVerb 'GET '[JSON, ProblemJSON] (OkResponses "Saved metric" SavedMetric) (KansokuResult SavedMetric)),
    listDefinitions :: mode :- "metric-definitions" :> MetricsAuth :> RelayPage 20 100 :> PageReply SavedMetric,
    updateDefinition :: mode :- AtDefinition (ReqBody '[JSON] CustomDefinition :> MultiVerb 'PUT '[JSON, ProblemJSON] (OkResponses "Saved metric" SavedMetric) (KansokuResult SavedMetric)),
    deleteDefinition :: mode :- AtDefinition (MultiVerb 'DELETE '[JSON, ProblemJSON] (OkResponses "Deleted metric" Bool) (KansokuResult Bool))
  }
  deriving stock (Generic)
