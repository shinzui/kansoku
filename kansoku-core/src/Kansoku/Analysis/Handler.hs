module Kansoku.Analysis.Handler (analysesServer) where

import Data.Generics.Labels ()
import Hasql.Pool qualified as Pool
import Kansoku.Analysis.Api
import Kansoku.Analysis.Store qualified as Store
import Kansoku.Analysis.Types
import Kansoku.Analysis.Validation
import Kansoku.Api.Response
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (MetricsPrincipal (..))
import Kansoku.Cohort.Api (PageResult (..))
import Kansoku.Prelude
import Relay.Pagination.Servant (RelayPageError (..))
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

analysesServer :: Text -> Int -> Pool.Pool -> Analyses (AsServerT Handler)
analysesServer settings limit pool =
  Analyses
    { createAnalysis = \(MetricsPrincipal p) input -> validated input (Store.createAnalysis settings limit (p ^. #accountId)),
      getAnalysis = \(MetricsPrincipal p) ident -> mapStore (Store.loadAnalysis pool (p ^. #accountId) ident),
      listAnalyses = \(MetricsPrincipal p) kind page -> do
        result <- liftIO (Store.listAnalyses pool (p ^. #accountId) kind page)
        pure $ case result of
          Left (Left _) -> PageBad (RelayPageError "invalid_cursor" "cursor does not match the analysis order" False Nothing)
          Left (Right _) -> PageUnavailable unavailableProblem
          Right connection -> PageOk connection,
      replaceAnalysis = \(MetricsPrincipal p) ident replacement -> validated (replacementInput replacement) (Store.replaceAnalysis settings (p ^. #accountId) ident (replacement ^. #revision)),
      deleteAnalysis = \(MetricsPrincipal p) ident revision -> mapStore (Store.deleteAnalysis settings (p ^. #accountId) ident revision)
    }
  where
    validated input action = case validateAnalysis input of
      Left message -> pure (AnalysisBadRequest (badRequest "invalid_analysis" message))
      Right value -> mapStore (action value)

mapStore :: IO (Store.StoreResult a) -> Handler (AnalysisResult a)
mapStore action = do
  result <- liftIO action
  pure $ case result of
    Store.Stored value -> AnalysisOk value
    Store.Missing -> AnalysisNotFound (notFound "analysis_not_found" "analysis does not exist in this account")
    Store.Stale -> AnalysisConflict (problem 409 "analysis_revision_conflict" "analysis changed; read it again before replacing or deleting")
    Store.LimitReached -> AnalysisConflict (problem 409 "analysis_limit_reached" "account analysis limit reached")
    Store.StoreUnavailable -> AnalysisUnavailable unavailableProblem

unavailableProblem :: ProblemDetails
unavailableProblem = unavailable "analysis_store_unavailable" "analysis store unavailable"
