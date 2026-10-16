-- | Bridge the toolkit's capability to an already retained application lease.
module Kansoku.ClickHouseMigration.Coordinator (withCoordinator, identity) where

import ClickHouseMigrate.ExclusiveAccess qualified as E
import ClickHouseMigrate.Target qualified as T
import Data.Aeson (Value)
import Data.IORef
import Data.Text (Text)
import Kansoku.Admin.Coordination qualified as C
import Kansoku.ClickHouseMigration.Config qualified as Config

identity :: Config.Config -> IO C.SessionIdentity
identity config = do
  session <- maybe (fail "KANSOKU_CH_MIGRATION_SESSION is required") pure (Config.session config)
  pure (C.SessionIdentity session (T.targetKeyText (Config.target config)) (T.serverIdText (Config.server config)) (T.ledgerIdText (Config.ledger config)))

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
