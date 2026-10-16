{-# LANGUAGE TypeApplications #-}

-- | Authenticated management and Relay member endpoints.
module Kansoku.Cohort.Handler (cohortsServer) where

import Control.Exception (bracket_)
import Data.Aeson qualified as A
import Data.Generics.Labels ()
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (MetricsPrincipal (..))
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Cohort.Api
import Kansoku.Cohort.Members
import Kansoku.Cohort.Query
import Kansoku.Cohort.Store qualified as Store
import Kansoku.Cohort.Types
import Kansoku.Event (AccountId (..))
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), validateDateRange)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import Relay.Pagination qualified as R
import Relay.Pagination.Hasql qualified as R
import Relay.Pagination.Servant (RelayPageError (..))
import Servant (Handler)
import Servant qualified
import Servant.Server.Generic (AsServerT)

cohortsServer :: Text -> Pool.Pool -> QueryPool -> Cohorts (AsServerT Handler)
cohortsServer settings pgPool queryPool =
  Cohorts
    { createCohort = \(MetricsPrincipal p) def -> save (p ^. #accountId) Nothing def,
      getCohort = \(MetricsPrincipal p) ident -> withDefinition (p ^. #accountId) ident (pure . KansokuOk),
      listCohorts = \(MetricsPrincipal p) page -> do
        result <- liftIO (Store.listDefinitions pgPool (p ^. #accountId) page)
        pure $ case result of
          Left (Left _) -> PageBad (cursorError page)
          Left (Right _) -> PageUnavailable storeUnavailable
          Right connection -> PageOk connection,
      updateCohort = \(MetricsPrincipal p) ident def -> locked (p ^. #accountId) ident $ withDefinition (p ^. #accountId) ident $ \_ -> save (p ^. #accountId) (Just ident) def,
      deleteCohort = \(MetricsPrincipal p) ident -> locked (p ^. #accountId) ident $ do
        result <- liftIO (Store.deleteDefinition pgPool (p ^. #accountId) ident)
        pure $ case result of Left _ -> KansokuUnavailable storeUnavailable; Right Nothing -> missing; Right (Just _) -> KansokuOk True,
      putMembers = \(MetricsPrincipal p) ident (CohortMembers users) -> locked (p ^. #accountId) ident $ withDefinition (p ^. #accountId) ident $ \saved ->
        if kind (definition saved) /= "static" || length users > 50000 || any (\u -> T.null u || T.length u > 1024) users
          then pure (KansokuBadRequest (badRequest "invalid_cohort" "static uploads require at most 50000 nonempty user ids of at most 1024 characters"))
          else let uniqueUsers = Set.toAscList (Set.fromList users) in storage $ replaceMembers queryPool (p ^. #accountId) (UUID.toText ident) uniqueUsers >> pure (CohortSize (fromIntegral (length uniqueUsers))),
      getMembers = \(MetricsPrincipal p) ident fromDay toDay page -> do
        loaded <- liftIO (Store.loadCohort pgPool (p ^. #accountId) ident)
        case loaded of
          Left _ -> pure (PageUnavailable storeUnavailable)
          Right Nothing -> pure (PageMissing missingProblem)
          Right (Just saved) -> case (validateDateRange fromDay toDay, memberBoundary page, memberPopulation (UUID.toText ident) fromDay toDay (definition saved)) of
            (Left (QueryLimitError code message), _, _) -> pure (PageBad (RelayPageError code message False Nothing))
            (_, Left _, _) -> pure (PageBad (cursorError page))
            (_, _, Left message) -> pure (PageBad (RelayPageError "invalid_cohort" message False Nothing))
            (Right (), Right boundary, Right (population, membership)) -> do
              let comparison = if R.direction page == R.Forward then ">" else "<"
                  ordering = if R.direction page == R.Forward then "ASC" else "DESC"
                  predicate = maybe "" (const (" WHERE user_id" <> comparison <> "{member_cursor:String}")) boundary
                  sql = "SELECT CAST(user_id,'String') AS member FROM (" <> population <> ")" <> predicate <> " ORDER BY user_id " <> ordering <> " LIMIT {member_limit:UInt64}"
                  params = memberParameters (p ^. #accountId) (UUID.toText ident) fromDay toDay membership <> [("member_limit", T.pack (show (R.pageSize page + 1)))] <> maybe [] (\key -> [("member_cursor", key)]) boundary
              result <- liftIO (trySynchronous (fetchMembers queryPool (p ^. #accountId) (since membership) toDay params sql))
              pure $ either (const (PageUnavailable queryUnavailable)) (PageOk . R.mkConnection memberSort page) result,
      getSize = \(MetricsPrincipal p) ident fromDay toDay -> withDefinition (p ^. #accountId) ident $ \saved -> case validateDateRange fromDay toDay of
        Left (QueryLimitError code message) -> pure (KansokuBadRequest (badRequest code message))
        Right () -> case memberPopulation (UUID.toText ident) fromDay toDay (definition saved) of
          Left message -> pure (KansokuBadRequest (badRequest "invalid_cohort" message))
          Right (population, membership) -> storage $ do
            rows <- fetchMembers queryPool (p ^. #accountId) (since membership) toDay (memberParameters (p ^. #accountId) (UUID.toText ident) fromDay toDay membership) ("SELECT toString(count()) AS member FROM (" <> population <> ")")
            case rows of [value] | [(n, "")] <- reads (T.unpack value) -> pure (CohortSize n); _ -> fail "invalid cohort size projection"
    }
  where
    save :: AccountId -> Maybe UUID.UUID -> CohortDefinition -> Handler (KansokuResult Cohort)
    save account ident def = case validateCohort def of
      Left message -> pure (KansokuBadRequest (badRequest "invalid_cohort" message))
      Right () -> do
        result <- liftIO (Store.saveCohort pgPool account ident def)
        pure $ case result of Left _ -> KansokuUnavailable storeUnavailable; Right Nothing -> KansokuBadRequest (badRequest "invalid_cohort" "name already exists or cohort kind changed"); Right (Just saved) -> KansokuOk saved
    withDefinition :: AccountId -> UUID.UUID -> (Cohort -> Handler (KansokuResult a)) -> Handler (KansokuResult a)
    withDefinition account ident action = do
      result <- liftIO (Store.loadCohort pgPool account ident)
      case result of Left _ -> pure (KansokuUnavailable storeUnavailable); Right Nothing -> pure missing; Right (Just saved) -> action saved
    -- A dedicated PostgreSQL session holds a transaction advisory lock across
    -- the entire cross-store operation, including failure and retry cleanup.
    locked :: AccountId -> UUID.UUID -> Handler (KansokuResult a) -> Handler (KansokuResult a)
    locked account ident action = do
      result <- liftIO $ trySynchronous $ withPostgres settings $ \connection -> bracket_ (pgScript connection "BEGIN") (pgScript connection "ROLLBACK") $ do
        void (pg connection "SELECT to_jsonb(pg_advisory_xact_lock(hashtextextended($1->>'key',0)))" (A.object ["key" A..= (unAccountId account <> ":" <> UUID.toText ident)]))
        Servant.runHandler action
      case result of Left _ -> pure (KansokuUnavailable storeUnavailable); Right (Left e) -> Servant.throwError e; Right (Right value) -> pure value
    storage :: IO a -> Handler (KansokuResult a)
    storage action = do
      result <- liftIO (trySynchronous action)
      pure $ either (const (KansokuUnavailable queryUnavailable)) KansokuOk result

missingProblem :: ProblemDetails
missingProblem = notFound "cohort_not_found" "cohort does not exist in this account"

missing :: KansokuResult a
missing = KansokuNotFound missingProblem

storeUnavailable :: ProblemDetails
storeUnavailable = unavailable "cohort_store_unavailable" "cohort store unavailable"

queryUnavailable :: ProblemDetails
queryUnavailable = unavailable "clickhouse_unavailable" "cohort membership query unavailable or resource limit exceeded"

cursorError :: R.PageRequest -> RelayPageError
cursorError page = RelayPageError "invalid_cursor" "cursor does not match the cohort list order" False (Just (if R.direction page == R.Forward then "after" else "before"))
