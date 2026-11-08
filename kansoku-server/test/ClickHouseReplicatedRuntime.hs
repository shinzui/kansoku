-- Owned lifecycle bridge plus a native client using the production constructor.
module Main (main) where

import ClickHaskell (closeConnection)
import ClickHouseMigrate.TestSupport.Server
import Control.Exception (IOException, bracket, displayException, throwIO, try)
import Control.Monad (unless, void)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as B
import Data.List (isInfixOf)
import Data.Text qualified as T
import Kansoku.Admin.Jobs (resumeJob)
import Kansoku.ClickHouse
import Kansoku.ClickHouse.Consistency
import Kansoku.ClickHouse.Native
import Kansoku.Config qualified as C
import Kansoku.Event (governedTraitEligible)
import Kansoku.Ingest.QueuedEvent (QueuedEvent)
import Kansoku.Ingest.QueuedEvent qualified as Q
import Kansoku.Postgres.Direct (withPostgres)
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
  args <- getArgs
  case args of
    "--native" : operation : rest -> native operation rest
    _ -> withReplicatedCandidate "altinity-linux-arm64-10002" $ \server -> do
      let database db = void (queryServer server ("CREATE DATABASE " <> db <> " ON CLUSTER fixture ENGINE=Replicated('/clickhouse/databases/{uuid}', '{shard}', '{replica}')"))
      database "analytics"
      database "kansoku_migration_ledger"
      a <- queryReplica server 0 "SELECT toString(serverUUID()) AS id"
      b <- queryReplica server 1 "SELECT toString(serverUUID()) AS id"
      withCreateProcess (proc "python3" (["scripts/clickhouse_replicated_runtime_acceptance.py", "--owned-bridge"] ++ args)) {std_in = CreatePipe, std_out = CreatePipe} $ \(Just input) (Just output) _ process -> do
        B.hPutStrLn input (A.encode (A.object ["endpoint" A..= serverEndpoint server, "root" A..= serverLogDirectory server, "replicas" A..= [a, b]]))
        hFlush input
        let loop = do
              done <- hIsEOF output
              unless done $ do
                line <- hGetLine output
                request <- either fail pure (A.eitherDecode (B.pack line))
                op <- field "op" request :: IO T.Text
                attempted <- try @IOException $ case op of
                  "query" -> field "sql" request >>= queryServer server
                  "replica" -> do
                    index <- field "index" request
                    sql <- field "sql" request
                    queryReplica server index sql
                  "stop" -> field "index" request >>= stopReplica server >> pure A.Null
                  "start" -> field "index" request >>= startReplica server >> pure A.Null
                  _ -> fail "Unknown fixture request"
                response <- case attempted of
                  Right value -> pure value
                  Left exception | "Owned fixture operation failed;" `isInfixOf` displayException exception -> pure (A.object ["fixtureError" A..= op])
                  Left exception -> throwIO exception
                B.hPutStrLn input (A.encode response)
                hFlush input
                loop
        timeout 1800000000 loop >>= maybe (fail "Owned runtime case deadline expired") pure
        code <- timeout 30000000 (waitForProcess process) >>= maybe (fail "Owned child exit deadline expired") pure
        unless (code == ExitSuccess) (fail "Replicated runtime acceptance failed")

native :: String -> [String] -> IO ()
native operation arguments = do
  cfg <- C.loadConfig >>= either (fail . show) pure
  let config = clickHouseConfigFromConfig cfg
      topology = C.clickHouseTopology cfg
      open = openClickHouse config
  case operation of
    "resume-trace" -> case arguments of
      [identifier] -> withPostgres (C.pgConnectionString cfg) $ \pg -> resumeJob cfg pg (A.object ["id" A..= identifier]) True Nothing >>= B.putStrLn . A.encode
      _ -> fail "missing owned resume identity"
    "inventory" -> withReplicaConnections topology open $ \replicas -> B.putStrLn (A.encode (map fst (replicaConnections replicas)))
    "topology" -> withReplicaConnections topology open $ \replicas -> do
      mapM_ (initializeRole topology Maintenance . snd) (replicaConnections replicas)
      synchronizeSchema replicas
      synchronizeTables replicas maintenanceTables
      B.putStrLn (A.encode (map fst (replicaConnections replicas)))
    "prepare" -> do
      payload <- B.getContents >>= either fail pure . A.eitherDecode :: IO [QueuedEvent]
      B.putStrLn (A.encode [q {Q.traitsEligible = governedTraitEligible (Q.event q)} | q <- payload])
    "write" -> do
      payload <- B.getContents >>= either fail pure . A.eitherDecode :: IO [QueuedEvent]
      writer <- newWriterConnection config
      insertWriterEvents writer payload
      putStrLn "acknowledged"
    "readback" -> withConsistentReadback topology open $ \connection -> do
      values <- chJSON connection A.Null "SELECT toJSONString(event_id) AS value FROM analytics.events_canonical ORDER BY event_id"
      public <- chJSON connection A.Null "SELECT toJSONString(event_id) AS value FROM analytics.events_resolved ORDER BY event_id"
      unless (values == public) (fail "public population differs")
      B.putStrLn (A.encode values)
    "pooled-readback" -> bracket (newQueryPool config 1) closeQueryPool $ \pool -> withReadbackQueryConnection topology pool $ \connection -> do
      values <- chJSON connection A.Null "SELECT toJSONString(event_id) AS value FROM analytics.events_canonical ORDER BY event_id"
      public <- chJSON connection A.Null "SELECT toJSONString(event_id) AS value FROM analytics.events_resolved ORDER BY event_id"
      unless (values == public) (fail "public population differs")
      B.putStrLn (A.encode values)
    "settings" -> bracket open closeConnection $ \connection -> do
      let role = case arguments of
            ["maintenance"] -> Maintenance
            ["readback"] -> Readback
            _ -> Writer
      initializeRole topology role connection
      settings <- mapM (\(name, _) -> chJSON connection A.Null ("SELECT toJSONString(tuple(name,value)) AS value FROM system.settings WHERE name='" <> name <> "'")) (roleSettings topology role)
      B.putStrLn (A.encode settings)
    _ -> fail "unknown native runtime operation"
