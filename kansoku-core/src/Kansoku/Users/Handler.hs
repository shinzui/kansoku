module Kansoku.Users.Handler (usersServer) where

import Data.Aeson qualified as A
import Data.Generics.Labels ()
import Data.Time (addDays, utctDay)
import Data.UUID qualified as UUID
import Hasql.Pool qualified as Pool
import Kansoku.Api.Response
import Kansoku.Auth.Handler ()
import Kansoku.Auth.Types (MetricsPrincipal (..))
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Cohort.Api (PageResult (..))
import Kansoku.Cohort.Query qualified as C
import Kansoku.Cohort.Store qualified as Store
import Kansoku.Cohort.Types qualified as C
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Prelude
import Kansoku.Users.Api
import Kansoku.Users.History qualified as History
import Kansoku.Users.Profile qualified as Profile
import Kansoku.Users.Query
import Kansoku.Users.Validation
import Relay.Pagination qualified as R
import Relay.Pagination.Hasql qualified as R
import Relay.Pagination.Servant (RelayPageError (..))
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

usersServer :: Pool.Pool -> QueryPool -> Users (AsServerT Handler)
usersServer pg pool =
  Users
    { activityCounts = \(MetricsPrincipal p) lo hi bots -> case validateDates (Just lo) (Just hi) of
        Right () -> do
          result <- liftIO (trySynchronous (countRows pool (p ^. #accountId) lo hi (fromMaybe False bots)))
          pure (either (const (KansokuUnavailable unavailableProblem)) KansokuOk result)
        _ -> pure (KansokuBadRequest (badRequest "invalid_users_query" "activity counts require paired dates spanning 1..366 days")),
      events = \(MetricsPrincipal p) ident lo hi bots filters page -> case (validateDates lo hi >> validateHistory filters, History.historyBoundary page) of
        _ | R.pageSize page < 1 -> pure (PageBad (RelayPageError "invalid_page_size" "page size must be in 1..100" False Nothing))
        (Left message, _) -> pure (PageBad (RelayPageError "invalid_users_query" message False Nothing))
        (_, Left _) -> pure (PageBad (RelayPageError "invalid_cursor" "cursor does not match history order" False Nothing))
        (Right (), Right boundary) -> do
          result <- liftIO (trySynchronous (History.history pool (p ^. #accountId) ident lo hi (fromMaybe False bots) filters page boundary))
          pure $ case result of
            Left _ -> PageUnavailable unavailableProblem
            Right Nothing -> PageMissing (notFound "user_not_found" "user does not exist in this account")
            Right (Just rows) -> PageOk (R.mkConnection History.historySort page rows),
      hosts = \(MetricsPrincipal p) ident lo hi bots filters -> case validateDates lo hi >> validateHostFacet filters of
        Left message -> pure (KansokuBadRequest (badRequest "invalid_users_query" message))
        Right () -> do
          result <- liftIO (trySynchronous (History.hosts pool (p ^. #accountId) ident lo hi (fromMaybe False bots) filters))
          pure $ case result of
            Left _ -> KansokuUnavailable unavailableProblem
            Right Nothing -> KansokuNotFound (notFound "user_not_found" "user does not exist in this account")
            Right (Just History.HostsTooLarge) -> KansokuBadRequest (badRequest "user_hosts_too_large" "user hosts exceed 1000 entries; narrow the selection")
            Right (Just (History.HostsFound value)) -> KansokuOk value,
      getProfile = \(MetricsPrincipal p) ident -> do
        result <- liftIO (trySynchronous (Profile.profile pool (p ^. #accountId) ident))
        pure $ case result of
          Left _ -> KansokuUnavailable unavailableProblem
          Right Nothing -> KansokuNotFound (notFound "user_not_found" "user does not exist in this account")
          Right (Just value) -> KansokuOk value,
      directory = \(MetricsPrincipal p) lo hi search order bots filters page -> do
        let ordering = fromMaybe "lastActivity" order
            account = p ^. #accountId
        case (validateDirectory lo hi search order filters, summaryBoundary ordering page) of
          _ | R.pageSize page < 1 -> pure (PageBad (RelayPageError "invalid_page_size" "page size must be in 1..100" False Nothing))
          (Left message, _) -> pure (PageBad (RelayPageError "invalid_users_query" message False Nothing))
          (_, Left _) -> pure (PageBad (RelayPageError "invalid_cursor" "cursor does not match user order" False Nothing))
          (Right (), Right boundary) -> do
            anchor <- maybe (addDays 1 . utctDay <$> liftIO getCurrentTime) pure hi
            loaded <- case [f | f <- filters, F.dimension f == "cohort"] of
              [] -> pure (Right Nothing)
              f : _ -> case F.value f of
                Just (A.String ident) | Just uuid <- UUID.fromText ident -> do
                  found <- liftIO (Store.loadCohort pg account uuid)
                  pure $ case found of
                    Left _ -> Left (PageUnavailable unavailableProblem)
                    Right Nothing -> Left (PageMissing (notFound "cohort_not_found" "cohort does not exist in this account"))
                    Right (Just saved) -> case C.compileMembership ident anchor (C.definition saved) of
                      Left _ -> Left (PageUnavailable unavailableProblem)
                      Right membership -> Right (Just (membership, F.op f == F.FilterNeq))
                _ -> pure (Left (PageBad (RelayPageError "invalid_filter" "invalid cohort" False Nothing)))
            case loaded of
              Left failure -> pure failure
              Right membership -> do
                result <- liftIO (trySynchronous (directoryRows pool account anchor lo hi search ordering (fromMaybe False bots) filters membership page boundary))
                pure (either (const (PageUnavailable unavailableProblem)) (PageOk . R.mkConnection (summarySort ordering) page) result)
    }

unavailableProblem :: ProblemDetails
unavailableProblem = unavailable "clickhouse_unavailable" "users query unavailable or resource limit exceeded"
