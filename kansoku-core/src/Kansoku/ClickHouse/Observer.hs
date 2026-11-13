-- | Storage diagnostics never authorize an insertion or block HTTP startup.
module Kansoku.ClickHouse.Observer
  ( TopologyObservation (..),
    TopologyObserver,
    newTopologyObserver,
    readTopologyObservation,
    topologyFailure,
    runTopologyObserver,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (fromException)
import Data.IORef
import Data.Text (Text)
import Data.Time.Clock
import Effectful (runEff)
import Kansoku.ClickHouse (ClickHouseConfig, validateClickHouseTopology)
import Kansoku.ClickHouse.Native (ConsistencyCategory (..), ConsistencyError (..))
import Kansoku.Exception (trySynchronous)
import Kansoku.Logging (logWarn, runLogStderr)

-- Safe reasons are retained for transition logs, never sent in probe bodies.
data TopologyObservation = Unchecked | Observed !UTCTime !(Either ConsistencyError ())
  deriving stock (Eq, Show)

newtype TopologyObserver = TopologyObserver (IORef TopologyObservation)

newTopologyObserver :: IO TopologyObserver
newTopologyObserver = TopologyObserver <$> newIORef Unchecked

readTopologyObservation :: TopologyObserver -> IO TopologyObservation
readTopologyObservation (TopologyObserver cell) = readIORef cell

topologyFailure :: UTCTime -> TopologyObservation -> Maybe Text
topologyFailure _ Unchecked = Just "clickhouse_topology_unchecked"
topologyFailure now (Observed at result)
  | diffUTCTime now at > 20 = Just "clickhouse_topology_stale"
  | otherwise = case result of
      Right () -> Nothing
      Left (ConsistencyError StorageUnavailable _) -> Just "clickhouse_topology_unavailable"
      Left (ConsistencyError ObservedMismatch _) -> Just "clickhouse_topology_mismatch"

runTopologyObserver :: ClickHouseConfig -> TopologyObserver -> IO ()
runTopologyObserver config observer@(TopologyObserver cell) = loop
  where
    loop = do
      result <- trySynchronous (validateClickHouseTopology config)
      now <- getCurrentTime
      let outcome = case result of
            Right () -> Right ()
            Left exception -> Left $ case fromException exception of
              Just safe -> safe
              Nothing -> ConsistencyError StorageUnavailable "topology exchange failed; details redacted"
          observation = Observed now outcome
      previous <- readTopologyObservation observer
      atomicWriteIORef cell observation
      if topologyFailure now previous /= topologyFailure now observation
        then case outcome of
          Left (ConsistencyError _ reason) -> runEff $ runLogStderr $ logWarn reason
          Right () -> pure ()
        else pure ()
      threadDelay 5_000_000
      loop
