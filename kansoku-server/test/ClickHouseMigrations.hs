module Main (main) where

import ClickHouseMigrate
import ClickHouseMigrate.Event qualified as E
import ClickHouseMigrate.Inspection qualified as I
import ClickHouseMigrate.Ledger qualified as L
import ClickHouseMigrate.Runner qualified as R
import ClickHouseMigrate.TestSupport.ExclusiveAccess
import ClickHouseMigrate.TestSupport.FaultProxy
import ClickHouseMigrate.TestSupport.Server
import Control.Monad (unless)
import Data.Aeson (FromJSON, Value)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Kansoku.ClickHouseMigrations qualified as M

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

fromJson :: (FromJSON a) => Value -> IO a
fromJson value = case A.fromJSON value of A.Success a -> pure a; _ -> fail "Invalid independent observation"

field :: (FromJSON a) => A.Key -> Value -> IO a
field key (A.Object row) = maybe (fail "Missing observation") fromJson (KM.lookup key row)
field _ _ = fail "Invalid observation"

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

countSql :: FaultProxy -> IO Int
countSql proxy = do
  events <- proxyEvents proxy >>= fromJson :: IO [Value]
  stages <- mapM (field "stage") events :: IO [Maybe T.Text]
  pure (length (filter (== Just "application-sql") stages))

main :: IO ()
main = withCandidateServer "lts-native" $ \server -> withFaultProxy server $ \proxy -> do
  plan <- right M.plan
  let migrations = NE.toList (inspectSchedule plan)
  assert "Wrong baseline" (length migrations == 25 && sum (map (NE.length . migrationSteps) migrations) == 257)
  rows <- queryServer server "SELECT toString(serverUUID()) AS id" >>= fromJson :: IO [Value]
  identity <- case rows of [row] -> field "id" row; _ -> fail "Missing identity"
  key <- right (targetKey "kansoku/owned-early-proof")
  endpoint <- right (directEndpoint (proxyEndpoint proxy))
  sid <- right (serverId identity)
  namespace <- right (ledgerNamespace "kansoku_migration_ledger")
  credentials <- right (basicCredentials "default" "test-password")
  ledger <- newLedgerId
  audit <- right (L.auditContext "owned acceptance" "reviewed fresh baseline" ["owned fresh server; no predecessor clients"])
  let config binding = targetConfig key endpoint sid namespace binding credentials defaultHttpLimits
      lockRoot = serverLogDirectory server ++ "/coordination"
  wrongId <- right (serverId "00000000-0000-0000-0000-000000000000")
  wrong <- I.status I.Observe (targetConfig key endpoint wrongId namespace FirstUse credentials defaultHttpLimits) plan
  assert "Wrong server UUID accepted" (case wrong of Left _ -> True; _ -> False)
  setFault proxy UnsupportedVersion
  unsupported <- I.status I.Observe (config FirstUse) plan
  assert "Unsupported version accepted" (case unsupported of Left _ -> True; _ -> False)
  assert "Probe rejection submitted application SQL" . (== 0) =<< countSql proxy
  setFault proxy Pass
  access <- hostLocalExclusiveAccess lockRoot 1000000 Nothing >>= right
  _ <- R.up (R.mutationContext (config FirstUse) access E.quietEvents E.redactedDiagnostics) (R.upOptions audit (Just (L.authorizeInitialization key ledger audit))) plan >>= right
  assert "Baseline request count differs" . (== 257) =<< countSql proxy
  scratch <- queryServer server "SELECT count() AS count FROM system.tables WHERE database='analytics' AND startsWith(name,'__chm_legacy_assert_')" >>= fromJson :: IO [Value]
  n <- case scratch of [row] -> field "count" row; _ -> fail "Missing scratch observation"
  assert "Assertions did not clean up" (n == (0 :: Int))
  -- Stop/restart retains identity and resolves predecessor server work. The
  -- persistent host-local marker is then reopened only with explicit evidence.
  restartCandidateServer server
  quietAudit <- right (L.auditContext "owned acceptance" "server restarted, clients stopped" [T.pack (serverLogDirectory server)])
  quiet <- right (L.attestQuiescence key quietAudit)
  again <- hostLocalExclusiveAccess lockRoot 1000000 (Just quiet) >>= right
  _ <- R.up (R.mutationContext (config (ExistingLedger ledger)) again E.quietEvents E.redactedDiagnostics) (R.upOptions audit Nothing) plan >>= right
  assert "Repeat submitted application SQL" . (== 257) =<< countSql proxy
  _ <- I.verify I.Observe (config (ExistingLedger ledger)) (I.verifyOptions True) plan >>= right
  putStrLn "4 cases passed: 25 migrations / 257 steps; assertions; restart and zero-SQL repeat"
