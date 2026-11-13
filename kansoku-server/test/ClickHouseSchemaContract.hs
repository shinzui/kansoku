module Main (main) where

import Control.Monad (forM_, unless)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as Text
import Kansoku.Admin.Store (field)
import Kansoku.ClickHouseMigration.Schema qualified as S
import Kansoku.ClickHouseMigration.SchemaExpectation qualified as E
import Kansoku.ClickHouseMigrations qualified as M

main :: IO ()
main = do
  plan <- either (fail . show) pure M.plan
  unless (isRight (E.checkPlan plan)) (fail "Schema artifact does not match the compiled release")
  tables <- decoded (field "tables" E.document)
  columns <- decoded (field "columns" E.document)
  let compareObserved = S.compareSnapshot "analytics" "default" fresh (field "databaseEngine" E.document)
      checks =
        [ ("matching complete metadata", compareObserved tables columns == Right []),
          ("changed column type", mismatch (compareObserved tables (changeFirst "type" (A.String "UInt8") columns))),
          ("changed column default", mismatch (compareObserved tables (changeFirst "default_expression" (A.String "123") columns))),
          ("changed engine", mismatch (compareObserved (changeFirst "engine_full" (A.String "Memory") tables) columns)),
          ("missing object", mismatch (compareObserved (drop 1 tables) columns)),
          ("extra object", mismatch (compareObserved (tables <> changeFirst "name" (A.String "unexpected") (take 1 tables)) columns)),
          ("relation mapping preserves literal", normalize "analytics" source == normalize "scratch" restored),
          ("literal is not a namespace", normalize "analytics" source /= normalize "scratch" (Text.replace "'analytics.events_raw'" "'scratch.events_raw'" restored)),
          ("unrelated identifier is not a namespace", normalize "analytics" source /= normalize "scratch" (Text.replace "analytics_extra" "scratch_extra" restored)),
          ("wrong live reference", normalize "analytics" source /= normalize "scratch" (Text.replace "FROM scratch.events_raw" "FROM analytics.events_raw" restored)),
          ("quoted relation mapping", normalize "analytics" "CREATE VIEW `analytics`.v AS SELECT 1 FROM `analytics`.events_raw" == normalize "scratch" "CREATE VIEW `scratch`.v AS SELECT 1 FROM `scratch`.events_raw"),
          ("physical UUID is not logical identity", normalize "analytics" "CREATE VIEW analytics.v AS SELECT 1" == normalize "scratch" "CREATE VIEW scratch.v UUID '11111111-1111-4111-8111-111111111111' AS SELECT 1"),
          ("explicit principal mapping", S.normalizeDefinition "analytics" "default" "v" fresh "CREATE VIEW analytics.v DEFINER = default SQL SECURITY DEFINER AS SELECT 1" == S.normalizeDefinition "scratch" "reviewed_user" "v" fresh "CREATE VIEW scratch.v DEFINER = reviewed_user SQL SECURITY DEFINER AS SELECT 1"),
          ("wrong principal", isLeft (S.normalizeDefinition "scratch" "reviewed_user" "v" fresh "CREATE VIEW scratch.v DEFINER = foreign SQL SECURITY DEFINER AS SELECT 1")),
          ("matching operated TTL", S.normalizeDefinition "scratch" "default" "events_raw" operated (raw <> ttl) == S.normalizeDefinition "scratch" "default" "events_raw" fresh raw),
          ("foreign TTL cutoff", isLeft (S.normalizeDefinition "scratch" "default" "events_raw" operated (raw <> Text.replace "2026-11-01" "2026-10-01" ttl))),
          ("broadened TTL", isLeft (S.normalizeDefinition "scratch" "default" "events_raw" operated (raw <> ttl <> " OR 1"))),
          ("unrecorded TTL", isLeft (S.normalizeDefinition "scratch" "default" "events_raw" fresh (raw <> ttl))),
          ("missing applied TTL", isLeft (S.normalizeDefinition "scratch" "default" "events_raw" operated raw)),
          ("missing policy", isLeft (S.policyExpectation A.Null)),
          ("unsupported literal escape", isLeft (normalize "scratch" "CREATE VIEW scratch.v AS SELECT '\\x41'")),
          ("statement delimiter", isLeft (normalize "scratch" "CREATE VIEW scratch.v AS SELECT 1; DROP TABLE scratch.events_raw"))
        ]
  forM_ checks $ \(name, passed) -> unless passed (fail (Text.unpack name))
  putStrLn ("All " <> show (length checks + 1) <> " tests passed")
  where
    mismatch (Right differences) = not (null differences)
    mismatch _ = False
    normalize database = S.normalizeDefinition database "default" "v" fresh
    source = "CREATE VIEW analytics.v AS SELECT 'analytics.events_raw' AS literal, analytics_extra FROM analytics.events_raw"
    restored = "CREATE VIEW scratch.v AS SELECT 'analytics.events_raw' AS literal, analytics_extra FROM scratch.events_raw"
    raw = "CREATE TABLE scratch.events_raw (occurred_at DateTime64(3,'UTC')) ENGINE = MergeTree ORDER BY occurred_at"
    ttl = " TTL toDateTime(occurred_at) DELETE WHERE occurred_at < parseDateTime64BestEffort(JSONExtractString('{\"cutoff\":\"2026-11-01T12:00:00Z\"}', 'cutoff'), 3, 'UTC')"

fresh :: A.Value
fresh = A.object ["days" A..= (0 :: Int), "revision" A..= (0 :: Int), "cutoff" A..= A.Null]

operated :: A.Value
operated = A.object ["days" A..= (30 :: Int), "revision" A..= (7 :: Int), "cutoff" A..= ("2026-11-01T12:00:00Z" :: Text)]

changeFirst :: A.Key -> A.Value -> [A.Value] -> [A.Value]
changeFirst key value (A.Object object : rest) = A.Object (KM.insert key value object) : rest
changeFirst _ _ _ = error "Invalid metadata test fixture"

decoded :: (A.FromJSON a) => A.Value -> IO a
decoded value = case A.fromJSON value of A.Success result -> pure result; _ -> fail "Invalid embedded schema fixture"
