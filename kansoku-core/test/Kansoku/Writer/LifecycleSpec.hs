{-# LANGUAGE OverloadedRecordDot #-}

module Kansoku.Writer.LifecycleSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, finally)
import Control.Monad (void)
import Data.Aeson (Value (..), toJSON)
import Data.Either (isRight)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Event (EventId (..), EventName (..), EventSource (..), baseEvent)
import Kansoku.Ingest.Queue (eventsQueueName)
import Kansoku.Observability (PipelineMetrics, newWriterHeartbeat)
import Kansoku.Postgres (createPool)
import Kansoku.PostgresTestSupport (withMigratedStore)
import Kansoku.Writer.Batch (writerBatchHandler)
import Pgmq qualified
import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)
import Pgmq.Hasql.Statements.Types (SendMessage (..))
import Pgmq.Types (MessageBody (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq qualified as Adapter
import Shibuya.App
import Shibuya.Internal.Runner.Master (ProcessorLifecycle (..), getLifecycleSnapshot)
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Directory (doesFileExist)
import System.IO (Handle, hGetLine)
import System.Process
import System.Timeout (timeout)
import Test.Hspec

type QueueEffects = '[Tracing, Pgmq, Error PgmqRuntimeError, Concurrent, IOE]

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Writer.Lifecycle" $ do
  it "writes through the Kansoku handler and acknowledges a real leased message" $
    withMigratedStore $ \_ connection pool -> do
      seed pool event
      written <- newIORef (0 :: Int)
      heartbeat <- newWriterHeartbeat
      snapshot <- bounded $ runQueue pool $ do
        adapter <- makeAdapter pool config
        leased <- Stream.toList $ Stream.take 1 adapter.source
        app <- start (adapter {source = Stream.fromList leased}) (writerBatchHandler metrics heartbeat (\xs -> modifyIORef' written (+ length xs)))
        waitApp app
        getLifecycleSnapshot (getAppMaster app)
      Map.elems snapshot `shouldBe` [LifecycleStopped]
      readIORef written `shouldReturn` 1
      countRows connection "pgmq.q_writer_lifecycle" `shouldReturn` 0

  it "retains exhausted acknowledgement failure as processor failure" $
    withMigratedStore $ \_ connection pool -> do
      seed pool event
      failures <- newIORef (0 :: Int)
      heartbeat <- newWriterHeartbeat
      snapshot <- bounded $ runQueue pool $ do
        let env = (Adapter.mkPgmqAdapterEnv pool) {Adapter.onAckFailure = \_ _ -> modifyIORef' failures (+ 1)}
        adapter <- Adapter.pgmqAdapter env config >>= either (liftIO . fail . show) pure
        leased <- Stream.toList $ Stream.take 1 adapter.source
        liftIO $ execute connection "ALTER TABLE pgmq.q_writer_lifecycle RENAME TO q_writer_held"
        app <- runApp defaultAppConfig {strategy = IgnoreFailures, inboxSize = 1} [(ProcessorId "failed-ack", mkBatchProcessor (adapter {source = Stream.fromList leased}) (writerBatchHandler metrics heartbeat (const (pure ()))) defaultBatchConfig {batchSize = 1, batchTimeout = 0.01})] >>= either (liftIO . fail . show) pure
        waitApp app
        getLifecycleSnapshot (getAppMaster app)
      Map.size snapshot `shouldBe` 1
      Map.elems snapshot `shouldSatisfy` all isFailure
      readIORef failures >>= (`shouldSatisfy` (> 0))
      countRows connection "pgmq.q_writer_held" `shouldReturn` 1

  it "cancels a blocked insert and repeated stop returns within the total deadline" $
    withMigratedStore $ \_ _ pool -> do
      seed pool event
      entered <- newEmptyMVar
      blocked <- newEmptyMVar
      heartbeat <- newWriterHeartbeat
      (first, second) <- bounded $ runQueue pool $ do
        adapter <- makeAdapter pool config
        app <- start adapter (writerBatchHandler metrics heartbeat (\_ -> putMVar entered () >> takeMVar blocked))
        liftIO $ takeMVar entered
        let stop = stopAppGracefully defaultShutdownConfig {drainTimeout = 0.05, totalShutdownTimeout = 1} app
        first <- stop
        second <- stop
        waitApp app
        pure (first, second)
      first `shouldBe` False
      second `shouldBe` first

  it "retries a dead-letter move after a discarded commit result without duplicating it" $
    withMigratedStore $ \settings connection pool -> do
      seed pool (String "invalid queued event")
      Pool.use pool (Pgmq.createQueue (eventsQueueName "writer_dead_letters")) >>= (`shouldSatisfy` isRight)
      withCommitFault settings $ \proxiedSettings output ->
        bracket (createPool proxiedSettings) Pool.release $ \proxied -> do
          heartbeat <- newWriterHeartbeat
          snapshot <- bounded $ runQueue proxied $ do
            adapter <- makeAdapter proxied config {Adapter.deadLetterConfig = Just (Adapter.directDeadLetter (eventsQueueName "writer_dead_letters") False), Adapter.ackRetry = Adapter.PollRetryConfig 3 0.01 0.01}
            leased <- Stream.toList $ Stream.take 1 adapter.source
            app <- start (adapter {source = Stream.fromList leased}) (writerBatchHandler metrics heartbeat (const (fail "invalid payload must not be inserted")))
            waitApp app
            getLifecycleSnapshot (getAppMaster app)
          Map.elems snapshot `shouldBe` [LifecycleStopped]
          bounded (hGetLine output) `shouldReturn` "dropped-commit"
          countRows connection "pgmq.q_writer_lifecycle" `shouldReturn` 0
          countRows connection "pgmq.q_writer_dead_letters" `shouldReturn` 1
  where
    isFailure (LifecycleFailed _ _) = True
    isFailure _ = False

config :: Adapter.PgmqAdapterConfig
config = (Adapter.defaultConfig (eventsQueueName "writer_lifecycle")) {Adapter.batchSize = 1, Adapter.polling = Adapter.StandardPolling 0.01, Adapter.ackRetry = Adapter.PollRetryConfig 1 0 0, Adapter.prefetchConfig = Nothing}

makeAdapter :: Pool.Pool -> Adapter.PgmqAdapterConfig -> Eff QueueEffects (Adapter QueueEffects Value)
makeAdapter pool cfg = Adapter.pgmqAdapter (Adapter.mkPgmqAdapterEnv pool) cfg >>= either (liftIO . fail . show) pure

start :: Adapter QueueEffects Value -> BatchHandler QueueEffects Value -> Eff QueueEffects (AppHandle QueueEffects)
start adapter handler = runApp defaultAppConfig {strategy = StopAllOnFailure, inboxSize = 1} [(ProcessorId "kansoku-writer-test", mkBatchProcessor adapter handler defaultBatchConfig {batchSize = 1, batchTimeout = 0.01})] >>= either (liftIO . fail . show) pure

runQueue :: Pool.Pool -> Eff QueueEffects a -> IO a
runQueue pool action = runEff (runConcurrent (runErrorNoCallStack @PgmqRuntimeError (runPgmq pool (runTracingNoop action)))) >>= either (fail . show) pure

bounded :: IO a -> IO a
bounded action = timeout 8_000_000 action >>= maybe (fail "writer lifecycle operation exceeded its deadline") pure

seed :: Pool.Pool -> Value -> IO ()
seed pool payload = do
  Pool.use pool (Pgmq.createQueue (eventsQueueName "writer_lifecycle")) >>= either (fail . show) pure
  void $ Pool.use pool (Pgmq.sendMessage (SendMessage (eventsQueueName "writer_lifecycle") (MessageBody payload) Nothing)) >>= either (fail . show) pure

event :: Value
event = toJSON $ baseEvent (EventId "lifecycle-event") (EventName "page_viewed") Web (read "2026-07-01 12:00:00 UTC") (read "2026-07-01 12:00:01 UTC")

execute :: Connection.Connection -> Text -> IO ()
execute connection sql = Connection.use connection (Session.script sql) >>= either (fail . show) pure

countRows :: Connection.Connection -> Text -> IO Integer
countRows connection table = fromIntegral <$> (Connection.use connection (Session.statement () (Statement.preparable ("SELECT count(*) FROM " <> table) E.noParams (D.singleRow (D.column (D.nonNullable D.int8))))) >>= either (fail . show) pure)

withCommitFault :: Text -> (Text -> Handle -> IO a) -> IO a
withCommitFault settings action = do
  script <- doesFileExist "scripts/pg_commit_fault.py" >>= \exists -> pure (if exists then "scripts/pg_commit_fault.py" else "../scripts/pg_commit_fault.py")
  let fields = Text.words settings
      field key = maybe (error "missing private PostgreSQL setting") (Text.drop (Text.length key + 1)) (findField key fields)
      socket = Text.unpack (field "host" <> "/.s.PGSQL." <> field "port")
      process = (proc "python3" [script, socket]) {std_out = CreatePipe}
  withCreateProcess process $ \_ output _ handle -> (`finally` terminateProcess handle) $ do
    pipe <- maybe (fail "missing proxy output") pure output
    port <- bounded (hGetLine pipe)
    let target = Text.unwords (filter (\s -> not ("host=" `Text.isPrefixOf` s || "port=" `Text.isPrefixOf` s)) fields) <> " host=127.0.0.1 port=" <> Text.pack port <> " sslmode=disable gssencmode=disable"
    action target pipe
  where
    findField _ [] = Nothing
    findField key (x : xs)
      | (key <> "=") `Text.isPrefixOf` x = Just x
      | otherwise = findField key xs
