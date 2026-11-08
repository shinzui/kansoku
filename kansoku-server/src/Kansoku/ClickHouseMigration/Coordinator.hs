-- | Bridge the toolkit's capability to an already retained application lease.
module Kansoku.ClickHouseMigration.Coordinator (withCoordinator, identity, sessionEvents, verifySessions) where

import ClickHouseMigrate.Definition qualified as Definition
import ClickHouseMigrate.Event qualified as Event
import ClickHouseMigrate.ExclusiveAccess qualified as E
import ClickHouseMigrate.Plan qualified as Plan
import ClickHouseMigrate.Target qualified as T
import Data.Aeson (Value)
import Data.IORef
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Kansoku.Admin.Coordination qualified as C
import Kansoku.ClickHouseMigration.Config qualified as Config

identity :: Config.Config -> IO C.SessionIdentity
identity config = do
  session <- maybe (fail "KANSOKU_CH_MIGRATION_SESSION is required") pure (Config.session config)
  pure (C.SessionIdentity session (T.targetKeyText (Config.target config)) (Config.sessionTarget config) (T.ledgerIdText (Config.ledger config)))

withCoordinator :: Config.Config -> Maybe (Integer, Text, Value) -> (E.ExclusiveAccess -> IO () -> (Bool -> [Text] -> IO ()) -> ([Text] -> IO ()) -> IO a) -> IO a
withCoordinator config mutation action = do
  settings <- maybe (fail "PG_CONNECTION_STRING is required for administrative coordination") pure (Config.postgres config)
  session <- identity config
  C.withSessionLease settings session mutation $ \connection -> do
    -- Each core scope invalidates its capability at release. The retained
    -- backend continues excluding other administrators until the outer scope
    -- ends; every future mutation needs a new persisted predecessor marker.
    let acquire target = do
          if target /= Config.target config then E.rejectAccessAcquisition E.AcquisitionFailed else pure ()
          retained <- C.leaseAlive connection
          if retained then newIORef True else E.rejectAccessAcquisition E.AccessLost
        release flag = writeIORef flag False
        alive flag = do
          live <- readIORef flag
          if live then C.leaseAlive connection else pure False
    provider <- either (const (fail "Invalid coordinator configuration")) pure (E.externallySerialized "kansoku-postgresql-administrator" "single tenant; persistent session fence and externally attested predecessor drain" 3000000 acquire release alive)
    action provider (C.finishSession connection session) (C.recordNativeOutcome connection session) (C.requireReceipts connection session)

-- The authored INSERT assertion is also the read-only final check. Extract its
-- SELECT from the compiled plan so the SQL cannot drift from the native step.
sessionAssertion :: Plan.MigrationPlan -> Maybe Text
sessionAssertion plan = case [ Text.dropWhileEnd (\c -> c == ';' || c == '\n') sql
                             | migration <- NE.toList (Plan.inspectSchedule plan),
                               Definition.migrationNameText (Definition.migrationIdName (Plan.migrationId migration)) == "0026_diagnostic_session_engagement",
                               step <- NE.toList (Plan.migrationSteps migration),
                               Definition.stepNameText (Plan.stepViewName step) == "verify-sessions",
                               Just sql <- [Text.stripPrefix "INSERT INTO analytics.__session_engagement_check\n" (Encoding.decodeUtf8 (Plan.stepSql step))]
                             ] of
  [sql] -> Just sql
  [] -> Nothing
  _ -> error "Invalid compiled session assertion"

sessionEvents :: Config.Config -> Plan.MigrationPlan -> Event.EventSink
sessionEvents config plan event
  | Event.migration event == Just "0026_diagnostic_session_engagement" && Event.phase event == Event.BeforeSql && Event.step event == Just "rebuild-sessions" = Config.sessionBarrier config "SELECT count() FROM analytics.sessions"
  | Event.migration event == Just "0026_diagnostic_session_engagement" && Event.phase event == Event.BeforeMigrationComplete = verifySessions config plan
  | otherwise = pure ()

verifySessions :: Config.Config -> Plan.MigrationPlan -> IO ()
verifySessions config plan = case sessionAssertion plan of
  Nothing -> pure ()
  Just sql -> Config.sessionBarrier config sql
