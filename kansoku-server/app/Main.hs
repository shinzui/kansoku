module Main (main) where

import Control.Concurrent.Async (poll, race_, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (bracket)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types
  ( CredentialKind (..),
    apiKeyIdText,
    credentialKindText,
  )
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    closeQueryPool,
    newQueryPool,
    queryReachable,
  )
import Kansoku.Config (loadConfig)
import Kansoku.Event (AccountId (..))
import Kansoku.Ingest.Queue (eventsQueueName, provisionQueue)
import Kansoku.Observability
  ( lastWriterBeat,
    newQueueDepthCell,
    newWriterHeartbeat,
    readQueueDepth,
    registerPipelineMetrics,
    runQueueDepthPoller,
  )
import Kansoku.Postgres (createPool)
import Kansoku.Prelude
import Kansoku.Readiness
  ( ReadyThresholds (..),
    evaluatePipelineReadiness,
  )
import Kansoku.Runtime (runApp)
import Kansoku.Server (ReadyProbe (..), kansokuApp, pgmqReady, startServer)
import Kansoku.Telemetry (Telemetry (..), makeTelemetry)
import Kansoku.Writer.Run (runWriter)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> runServer
    "issue-key" : issueArgs -> runIssueKey issueArgs
    _ -> usageFailure

runServer :: IO ()
runServer = do
  shutdownVar <- newEmptyMVar
  let requestShutdown = void (tryPutMVar shutdownVar ())
  void $ installHandler sigTERM (Catch requestShutdown) Nothing
  void $ installHandler sigINT (Catch requestShutdown) Nothing
  result <- loadConfig
  case result of
    Left err -> do
      hPutStrLn stderr ("configuration error: " <> show err)
      exitFailure
    Right cfg -> do
      let queueName = eventsQueueName (cfg ^. #eventsQueueName)
      bracket (createPool (cfg ^. #pgConnectionString)) Pool.release $ \pool -> do
        provisionQueue pool queueName
        bracket (newQueryPool (clickHouseConfigFromConfig cfg) (cfg ^. #clickHouseQueryPoolSize)) closeQueryPool $ \queryPool ->
          bracket makeTelemetry shutdownTelemetry $ \telemetry -> do
            startedAt <- getCurrentTime
            let tracer = telemetry ^. #tracer
            metrics <- registerPipelineMetrics
            heartbeat <- newWriterHeartbeat
            queueDepth <- newQueueDepthCell
            withAsync
              ( runWriter
                  metrics
                  heartbeat
                  pool
                  tracer
                  (clickHouseConfigFromConfig cfg)
                  queueName
                  (cfg ^. #writerVisibilityTimeoutSec)
                  (cfg ^. #writerAdapterBatchSize)
                  (cfg ^. #writerMaxBatchSize)
                  (cfg ^. #writerMaxLatencyMs)
                  (readMVar shutdownVar)
              )
              ( \writerAsync ->
                  withAsync
                    ( runQueueDepthPoller
                        pool
                        queueName
                        metrics
                        queueDepth
                        (cfg ^. #queuePollIntervalSec)
                    )
                    ( \pollerAsync ->
                        let probe =
                              ReadyProbe
                                { writerAlive = isNothing <$> poll writerAsync,
                                  pgmqReachable = pgmqReady pool queueName,
                                  clickhouseReachable = queryReachable queryPool,
                                  pipelineReady = do
                                    queueSample <- readQueueDepth queueDepth
                                    lastFlush <- lastWriterBeat heartbeat
                                    now <- getCurrentTime
                                    pure $
                                      evaluatePipelineReadiness
                                        ReadyThresholds
                                          { maxQueueDepth = cfg ^. #readyMaxQueueDepth,
                                            maxFlushAgeSec = cfg ^. #readyMaxFlushAgeSec,
                                            sampleMaxAgeSec = 3 * (cfg ^. #queuePollIntervalSec)
                                          }
                                        startedAt
                                        queueSample
                                        lastFlush
                                        now
                                }
                         in do
                              app <- kansokuApp cfg probe pool queueName queryPool
                              race_
                                (wait writerAsync)
                                ( race_
                                    (wait pollerAsync)
                                    (runApp cfg (startServer app))
                                )
                    )
              )

data IssueOptions = IssueOptions
  { kind :: !CredentialKind,
    accountId :: !AccountId,
    description :: !Text
  }
  deriving stock (Generic)

runIssueKey :: [String] -> IO ()
runIssueKey args =
  case parseIssueOptions args of
    Left message -> hPutStrLn stderr message >> usageFailure
    Right options -> do
      result <- loadConfig
      case result of
        Left err -> hPutStrLn stderr ("configuration error: " <> show err) >> exitFailure
        Right cfg ->
          bracket (createPool (cfg ^. #pgConnectionString)) Pool.release $ \pool -> do
            issued <- issueKey pool (options ^. #kind) (options ^. #accountId) (options ^. #description)
            case issued of
              Left err -> hPutStrLn stderr ("key issuance failed: " <> show err) >> exitFailure
              Right (keyId, Token token) -> do
                putStrLn
                  ( "issued "
                      <> Text.unpack (credentialKindText (options ^. #kind))
                      <> " "
                      <> Text.unpack (apiKeyIdText keyId)
                      <> " for account "
                      <> Text.unpack (unAccountId (options ^. #accountId))
                  )
                putStrLn (Text.unpack token)
                putStrLn "store this token now; it cannot be shown again"

parseIssueOptions :: [String] -> Either String IssueOptions
parseIssueOptions = go Nothing Nothing ""
  where
    go maybeKind maybeAccount description = \case
      [] -> do
        kind <- maybe (Left "missing --kind") Right maybeKind
        account <- maybe (Left "missing --account") Right maybeAccount
        unless (not (Text.null account)) (Left "--account must not be empty")
        pure IssueOptions {kind, accountId = AccountId account, description}
      "--kind" : value : rest -> do
        kind <-
          case value of
            "write" -> Right WriteKey
            "service" -> Right ServiceToken
            _ -> Left "--kind must be write or service"
        go (Just kind) maybeAccount description rest
      "--account" : value : rest ->
        go maybeKind (Just (Text.pack value)) description rest
      "--description" : value : rest ->
        go maybeKind maybeAccount (Text.pack value) rest
      flag : _ -> Left ("unrecognized or incomplete issue-key argument: " <> flag)

usageFailure :: IO a
usageFailure = do
  hPutStrLn stderr "usage: kansoku-server issue-key --kind write|service --account ACCOUNT [--description TEXT]"
  exitFailure
