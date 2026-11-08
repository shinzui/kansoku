-- Owned fixture bridge: Python drives the actual CLIs; observations use public APIs.
module Main (main) where

import ClickHouseMigrate.TestSupport.Server
import Control.Monad (unless, void)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as B
import Data.Text qualified as T
import System.Environment (getArgs)
import System.Exit (ExitCode (..))
import System.IO
import System.Process
import System.Timeout (timeout)

field :: (A.FromJSON a) => A.Key -> A.Value -> IO a
field key (A.Object row) = case KM.lookup key row of
  Just value -> case A.fromJSON value of A.Success a -> pure a; _ -> fail "Invalid fixture field"
  _ -> fail "Missing fixture field"
field _ _ = fail "Invalid fixture response"

main :: IO ()
main = do
  cases <- getArgs
  mapM_ runCase (if null cases then ["tiny", "direct", "full", "missing-id", "unexpected-id", "pinned", "stopped", "missing-ledger", "atomic-ledger", "missing-app", "atomic-app", "nonempty", "foreign-v1"] else cases)
  putStrLn (show (if null cases then 13 else length cases) ++ " owned cases passed; zero failures; zero skipped")
  where
    runCase "direct" = withCandidateServer "altinity-linux-arm64-10002" $ \server -> bridge "direct" server
    runCase name = withReplicatedCandidate "altinity-linux-arm64-10002" $ \server -> do
      let database db engine = void (queryServer server ("CREATE DATABASE " <> db <> " ON CLUSTER fixture ENGINE=" <> engine))
          replicated = "Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')"
      unless (name == "missing-app") (database "analytics" (if name == "atomic-app" then "Atomic" else replicated))
      unless (name == "missing-ledger") (database "kansoku_migration_ledger" (if name == "atomic-ledger" then "Atomic" else replicated))
      unless (name /= "nonempty") (void (queryServer server "CREATE TABLE analytics.existing (id UInt8) ENGINE=ReplicatedMergeTree ORDER BY id"))
      bridge name server
    bridge name server = do
      a <- if name == "direct" then queryServer server "SELECT toString(serverUUID()) AS id" else queryReplica server 0 "SELECT toString(serverUUID()) AS id"
      b <- if name == "direct" then pure A.Null else queryReplica server 1 "SELECT toString(serverUUID()) AS id"
      withCreateProcess (proc "python3" ["scripts/clickhouse_replicated_migrations_acceptance.py", name]) {std_in = CreatePipe, std_out = CreatePipe} $ \(Just input) (Just output) _ process -> do
        B.hPutStrLn input (A.encode (A.object ["endpoint" A..= serverEndpoint server, "root" A..= serverLogDirectory server, "replicas" A..= [a, b]]))
        hFlush input
        let loop = do
              done <- hIsEOF output
              unless done $ do
                line <- hGetLine output
                request <- either fail pure (A.eitherDecode (B.pack line))
                op <- field "op" request :: IO T.Text
                response <- case op of
                  "query" -> field "sql" request >>= queryServer server
                  "replica" -> do
                    index <- field "index" request
                    sql <- field "sql" request
                    queryReplica server index sql
                  "stop" -> field "index" request >>= stopReplica server >> pure A.Null
                  _ -> fail "Unknown owned fixture request"
                B.hPutStrLn input (A.encode response)
                hFlush input
                loop
        timeout 900000000 loop >>= maybe (fail "Owned case deadline expired") pure
        code <- timeout 30000000 (waitForProcess process) >>= maybe (fail "Owned child exit deadline expired") pure
        unless (code == ExitSuccess) (fail ("Replicated acceptance failed: " ++ name))
