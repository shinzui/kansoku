-- | Metric definition writes share custom query validation.
module Kansoku.Metrics.DefinitionHandler (definitionsServer) where

import Data.UUID (UUID)
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (MetricsPrincipal (..))
import Kansoku.Cohort.Api (PageResult (..))
import Kansoku.Event (AccountId, defaultRegistry)
import Kansoku.Metrics.Custom (validateCustom)
import Kansoku.Metrics.Definition
import Kansoku.Metrics.DefinitionApi
import Kansoku.Metrics.DefinitionStore qualified as Store
import Kansoku.Prelude
import Relay.Pagination.Servant (RelayPageError (..))
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

definitionsServer :: Pool.Pool -> MetricDefinitions (AsServerT Handler)
definitionsServer pool =
  MetricDefinitions
    { createDefinition = \(MetricsPrincipal p) def -> save (p ^. #accountId) Nothing def,
      getDefinition = \(MetricsPrincipal p) ident -> load (p ^. #accountId) ident (pure . KansokuOk),
      listDefinitions = \(MetricsPrincipal p) page -> do
        result <- liftIO (Store.listDefinitions pool (p ^. #accountId) page)
        pure $ case result of
          Left (Left _) -> PageBad (RelayPageError "invalid_cursor" "cursor does not match the metric definition order" False Nothing)
          Left (Right _) -> PageUnavailable unavailableProblem
          Right connection -> PageOk connection,
      updateDefinition = \(MetricsPrincipal p) ident def -> load (p ^. #accountId) ident (\_ -> save (p ^. #accountId) (Just ident) def),
      deleteDefinition = \(MetricsPrincipal p) ident -> do
        result <- liftIO (Store.deleteDefinition pool (p ^. #accountId) ident)
        pure $ case result of Left _ -> KansokuUnavailable unavailableProblem; Right Nothing -> missing; Right (Just _) -> KansokuOk True
    }
  where
    save :: AccountId -> Maybe UUID -> CustomDefinition -> Handler (KansokuResult SavedMetric)
    save account ident def = case validateCustom defaultRegistry def of
      Left message -> pure (KansokuBadRequest (badRequest "invalid_metric" message))
      Right () -> do
        result <- liftIO (Store.saveMetric pool account ident def)
        pure $ case result of
          Left _ -> KansokuUnavailable unavailableProblem
          Right Nothing -> KansokuBadRequest (badRequest "invalid_metric" "name already exists or definition was deleted")
          Right (Just value) -> KansokuOk value
    load :: AccountId -> UUID -> (SavedMetric -> Handler (KansokuResult a)) -> Handler (KansokuResult a)
    load account ident action = do
      result <- liftIO (Store.loadMetric pool account ident)
      case result of Left _ -> pure (KansokuUnavailable unavailableProblem); Right Nothing -> pure missing; Right (Just value) -> action value
    missing = KansokuNotFound (notFound "metric_not_found" "metric does not exist in this account")
    unavailableProblem = unavailable "metric_store_unavailable" "metric definition store unavailable"
