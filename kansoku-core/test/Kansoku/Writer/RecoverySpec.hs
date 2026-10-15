{-# LANGUAGE OverloadedRecordDot #-}

module Kansoku.Writer.RecoverySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Effectful (IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Kansoku.Observability (PipelineMetrics)
import Kansoku.Writer.Recovery
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Writer.Recovery" $ do
  it "gates pulls before the source and retains the same batch through failed probes and reinsertion" $ do
    attempts <- newIORef ([] :: [[Int]])
    probes <- newIORef (0 :: Int)
    pulls <- newIORef (0 :: Int)
    renewals <- newIORef (0 :: Int)
    paused <- newEmptyMVar
    release <- newEmptyMVar
    let probe = do
          n <- atomicModifyIORef' probes (\n -> (n + 1, n + 1))
          case n of
            1 -> fail "injected probe failure"
            2 -> pure ()
            _ -> putMVar paused () >> takeMVar release
        insert rows = do
          n <- atomicModifyIORef' attempts (\previous -> (previous <> [rows], length previous))
          if n < 2 then fail "injected insert failure" else pure ()
    recovery <- newWriterRecovery fast metrics probe
    writer <- async (recoverInsert recovery (modifyIORef' renewals (+ 1)) insert [1, 2])
    bounded (takeMVar paused)
    readBreakerState recovery `shouldReturn` Unavailable
    let adapter = gateAdapter recovery (countedAdapter pulls)
    reader <- async $ fmap length $ runEff $ runConcurrent $ Stream.toList $ Stream.take 1 adapter.source
    threadDelay 20_000
    readIORef pulls `shouldReturn` 0
    -- A successful ping followed by another failed insert has not opened the gate.
    readIORef attempts `shouldReturn` [[1, 2], [1, 2]]
    putMVar release ()
    bounded (wait writer)
    bounded (wait reader) `shouldReturn` 1
    readIORef attempts `shouldReturn` [[1, 2], [1, 2], [1, 2]]
    readIORef renewals >>= (`shouldSatisfy` (>= 3))
    readBreakerState recovery `shouldReturn` Closed

  it "wakes a stopped gate without pulling and propagates cancellation from a stalled probe" $ do
    entered <- newEmptyMVar
    never <- newEmptyMVar
    pulls <- newIORef (0 :: Int)
    recovery <- newWriterRecovery fast metrics (putMVar entered () >> takeMVar never)
    writer <- async (recoverInsert recovery (pure ()) (const (fail "storage down")) [()])
    bounded (takeMVar entered)
    let adapter = gateAdapter recovery (countedAdapter pulls)
    reader <- async $ fmap length $ runEff $ runConcurrent $ Stream.toList adapter.source
    runEff $ runConcurrent adapter.shutdown
    bounded (wait reader) `shouldReturn` 0
    readIORef pulls `shouldReturn` 0
    bounded (cancel writer)
    waitCatch writer >>= (`shouldSatisfy` isLeft)

  it "interrupts an adapter's internal empty polling when the breaker opens" $ do
    polls <- newIORef (0 :: Int)
    probeEntered <- newEmptyMVar
    blocked <- newEmptyMVar
    recovery <- newWriterRecovery fast metrics (putMVar probeEntered () >> takeMVar blocked)
    let empty =
          Adapter
            "empty-polling"
            (Stream.mapMaybe id (Stream.repeatM (liftIO (modifyIORef' polls (+ 1) >> threadDelay 1_000) >> pure Nothing)))
            (pure ())
        adapter = gateAdapter recovery empty
    reader <- async $ fmap length $ runEff $ runConcurrent $ Stream.toList adapter.source
    threadDelay 10_000
    writer <- async $ recoverInsert recovery (pure ()) (const (fail "storage down")) [()]
    bounded (takeMVar probeEntered)
    threadDelay 10_000
    pausedPolls <- readIORef polls
    pausedPolls `shouldSatisfy` (> 0)
    threadDelay 20_000
    readIORef polls `shouldReturn` pausedPolls
    runEff $ runConcurrent adapter.shutdown
    bounded (wait reader) `shouldReturn` 0
    bounded (cancel writer)

  it "keeps recovery live through a failed lease renewal and bounds a stalled insert" $ do
    renewals <- newIORef (0 :: Int)
    probes <- newEmptyMVar
    blocked <- newEmptyMVar
    let renew = do
          n <- atomicModifyIORef' renewals (\n -> (n + 1, n))
          if n == 0 then fail "lease temporarily unavailable" else pure ()
    recovery <- newWriterRecovery fast {insertTimeoutMicros = 10_000} metrics (putMVar probes () >> takeMVar blocked)
    writer <- async (recoverInsert recovery renew (const (threadDelay 10_000_000)) [()])
    bounded (takeMVar probes)
    readIORef renewals >>= (`shouldSatisfy` (>= 2))
    readBreakerState recovery `shouldReturn` Unavailable
    bounded (cancel writer)
    waitCatch writer >>= (`shouldSatisfy` isLeft)

fast :: RecoveryPolicy
fast = defaultRecoveryPolicy {probeIntervalMicros = 1_000, probeTimeoutMicros = 1_000_000}

countedAdapter :: IORef Int -> Adapter '[Concurrent, IOE] ()
countedAdapter pulls = Adapter "counted" (Stream.repeatM (liftIO (modifyIORef' pulls (+ 1)) >> pure item)) (pure ())
  where
    item = mkIngested (mkEnvelope (MessageId "gate-test") ()) (AckHandle (const (pure ())))

bounded :: IO a -> IO a
bounded action = timeout 2_000_000 action >>= maybe (fail "writer recovery exceeded its test deadline") pure
