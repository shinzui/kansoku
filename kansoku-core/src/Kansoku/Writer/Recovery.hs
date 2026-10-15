{-# LANGUAGE OverloadedRecordDot #-}

-- | Pause source pulls while one bounded batch waits for storage recovery.
module Kansoku.Writer.Recovery
  ( WriterRecovery,
    RecoveryPolicy (..),
    BreakerState (..),
    defaultRecoveryPolicy,
    newWriterRecovery,
    readBreakerState,
    gateAdapter,
    recoverInsert,
  )
where

import ClickHaskell (ClientError (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, SomeException, fromException, throwIO)
import Control.Monad (unless, when)
import Data.Generics.Labels ()
import Effectful (IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (Concurrent)
import Effectful.Concurrent.Async qualified as Async
import Kansoku.Exception (trySynchronous)
import Kansoku.Logging (logWarn, runLogStderr)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Prelude (view)
import Prometheus qualified as P
import Shibuya.Adapter (Adapter (..))
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)

data BreakerState = Closed | Unavailable | Parked
  deriving stock (Eq, Show)

data RecoveryPolicy = RecoveryPolicy
  { probeIntervalMicros :: !Int,
    insertTimeoutMicros :: !Int,
    probeTimeoutMicros :: !Int
  }
  deriving stock (Eq, Show)

defaultRecoveryPolicy :: RecoveryPolicy
defaultRecoveryPolicy = RecoveryPolicy 5_000_000 30_000_000 750_000

data WriterRecovery = WriterRecovery
  { state :: !(TVar BreakerState),
    stopping :: !(TVar Bool),
    metrics :: !PipelineMetrics,
    policy :: !RecoveryPolicy,
    probe :: !(IO ())
  }

data InsertTimedOut = InsertTimedOut
  deriving stock (Show)
  deriving anyclass (Exception)

newWriterRecovery :: RecoveryPolicy -> PipelineMetrics -> IO () -> IO WriterRecovery
newWriterRecovery policy metrics probe
  | policy.probeIntervalMicros <= 0 || policy.insertTimeoutMicros <= 0 || policy.probeTimeoutMicros <= 0 =
      fail "writer recovery deadlines must be positive"
  | otherwise = WriterRecovery <$> newTVarIO Closed <*> newTVarIO False <*> pure metrics <*> pure policy <*> pure probe

readBreakerState :: WriterRecovery -> IO BreakerState
readBreakerState recovery = readTVarIO recovery.state

-- | The gate runs BEFORE uncons, including before the adapter's next database
-- read. Prefetch must remain disabled. One read already in progress when an
-- insert fails can still finish; the adapter chunk/inbox/batch bounds cover it.
gateAdapter :: (IOE :> es, Concurrent :> es) => WriterRecovery -> Adapter es msg -> Adapter es msg
gateAdapter recovery adapter =
  Adapter
    { adapterName = adapter.adapterName,
      source = Stream.unfoldrM step adapter.source,
      shutdown = do
        liftIO $ atomically $ writeTVar recovery.stopping True
        adapter.shutdown
    }
  where
    step remaining = do
      allowed <- liftIO $ atomically $ do
        stopped <- readTVar recovery.stopping
        if stopped
          then pure False
          else do
            state <- readTVar recovery.state
            check (state == Closed)
            pure True
      if not allowed
        then pure Nothing
        else do
          -- uncons can poll an empty adapter repeatedly before yielding. Wake
          -- and cancel that pull as soon as the breaker opens, rather than
          -- letting its internal empty-poll loop bypass the source gate.
          outcome <- Async.race (Stream.uncons remaining) $ liftIO $ atomically $ do
            stopped <- readTVar recovery.stopping
            state <- readTVar recovery.state
            check (stopped || state /= Closed)
          case outcome of
            Left item -> pure item
            Right () -> step remaining

-- | Keep the exact same queued payloads until insert succeeds. Lease renewal
-- uses one native batch update; probing owns a separate physical connection.
-- A ping permits only another insert attempt: source pulls resume after that
-- insert succeeds. Cancellation escapes all catches and closes native sockets.
recoverInsert :: WriterRecovery -> IO () -> ([a] -> IO ()) -> [a] -> IO ()
recoverInsert recovery renew insert events = attempt
  where
    attempt = do
      renewSafely
      result <- trySynchronous $ do
        finished <- timeout recovery.policy.insertTimeoutMicros (insert events)
        maybe (throwIO InsertTimedOut) pure finished
      case result of
        Right () -> do
          atomically $ writeTVar recovery.state Closed
          P.setGauge (view #writerBreakerState recovery.metrics) 0
        Left err -> do
          P.incCounter (view #writerInsertFailuresTotal recovery.metrics)
          previous <- readBreakerState recovery
          unless (previous == Closed) $ P.incCounter (view #writerRecoveryFailuresTotal recovery.metrics)
          let next = classify err
          atomically $ writeTVar recovery.state next
          P.setGauge (view #writerBreakerState recovery.metrics) (if next == Parked then 2 else 1)
          when (previous /= next) $
            runEff $
              runLogStderr $
                logWarn (if next == Parked then "writer storage rejected insert; source paused and batch parked" else "writer storage unavailable; source paused")
          awaitStorage

    awaitStorage = do
      renewSafely
      threadDelay recovery.policy.probeIntervalMicros
      result <- trySynchronous $ timeout recovery.policy.probeTimeoutMicros recovery.probe
      case result of
        Right (Just ()) -> attempt
        _ -> do
          P.incCounter (view #writerRecoveryFailuresTotal recovery.metrics)
          awaitStorage

    renewSafely = do
      result <- trySynchronous renew
      case result of
        Right () -> pure ()
        Left _ -> do
          previous <- readBreakerState recovery
          atomically $ writeTVar recovery.state Unavailable
          P.setGauge (view #writerBreakerState recovery.metrics) 1
          P.incCounter (view #writerRecoveryFailuresTotal recovery.metrics)
          when (previous == Closed) $ runEff $ runLogStderr $ logWarn "writer lease renewal unavailable; source paused"
          threadDelay recovery.policy.probeIntervalMicros
          renewSafely

-- Server SQL/schema responses park the batch and alert through state 2. They
-- retry at the probe cadence, rather than consuming queue delivery attempts.
classify :: SomeException -> BreakerState
classify err = case fromException err :: Maybe ClientError of
  Just DatabaseException {} -> Parked
  Just UnmatchedResult {} -> Parked
  _ -> Unavailable
