-- | Actual compiler queries and connection lifecycle for the owned benchmark.
module Kansoku.QueryBenchmark (emitSql, runSession) where

import ClickHaskell (ChString, ClickHaskell, Column, Float64, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Char (isAlphaNum)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day)
import GHC.Clock (getMonotonicTime)
import GHC.Generics (Generic)
import Kansoku.ClickHouse
import Kansoku.Config (loadConfig)
import Kansoku.Event (AccountId (..), defaultRegistry)
import Kansoku.Exception (trySynchronous)
import Kansoku.Identity.Cache (identityCacheRevisionSQL, identityCacheSql)
import Kansoku.Metrics.Query
import Kansoku.Metrics.Query.Validate (mkSqlName)
import Kansoku.Metrics.Registry (BuiltinMetric (Ratioed), conversionRate)
import System.Environment (getEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, isEOF, stdout)
import Text.Read (readMaybe)

queriesFor :: Day -> Day -> Map.Map Text Text
queriesFor fromDay toDay =
  let req = QueryRequest (AccountId "bench-a") fromDay toDay Nothing Nothing [] False
      step value = either (error . show) id (mkSqlName value)
      ratio = either (error . show) id (buildSQL defaultRegistry (Ratioed conversionRate) req)
   in Map.fromList
        [ ("source", resolvedSource req),
          ("funnel", buildFunnelSQL req 604800 (step <$> ["signup_started", "signup_completed"])),
          ("retention", buildRetentionSQL req [0, 1, 7]),
          ("conversion", ratio)
        ]

emitSql :: IO ()
emitSql = do
  fromDay <- day "KANSOKU_IDENTITY_BENCH_FROM"
  toDay <- day "KANSOKU_IDENTITY_BENCH_TO"
  LBS.putStrLn (Aeson.encode (Aeson.object ["queries" Aeson..= queriesFor fromDay toDay, "cacheSetup" Aeson..= identityCacheSql, "revisionSQL" Aeson..= identityCacheRevisionSQL]))
  where
    day name = getEnv name >>= maybe (fail ("invalid benchmark day: " <> name)) pure . readMaybe @Day

data Request = Request
  { fromDay :: Day,
    toDay :: Day,
    queryName :: Text,
    baseline :: Bool,
    cold :: Bool,
    evidenceOnly :: Bool,
    tag :: Text
  }
  deriving stock (Generic)
  deriving anyclass (Aeson.FromJSON)

data Row = Row {bucket :: ByteString, group_key :: ByteString, value :: Double}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "bucket" ChString, Column "group_key" ChString, Column "value" Float64])

-- One persistent, size-one production pool keeps caches on their actual native
-- connection. The benchmark logs every preflight/preparation as well as SELECT.
runSession :: IO ()
runSession = do
  hSetBuffering stdout LineBuffering
  cfg <- loadConfig >>= either (fail . show) pure
  bracket (newQueryPool (clickHouseConfigFromConfig cfg) 1) closeQueryPool loop
  where
    loop pool = do
      finished <- isEOF
      unless finished $ do
        request <- BS.getLine >>= either fail pure . Aeson.eitherDecodeStrict'
        outcome <- trySynchronous (execute pool request)
        LBS.putStrLn $ Aeson.encode $ case outcome of
          Left err -> Aeson.object ["error" Aeson..= show err]
          Right result -> result
        loop pool

    execute pool Request {fromDay, toDay, queryName, baseline, cold, evidenceOnly, tag} = do
      unless (Text.all (\c -> isAlphaNum c || c == '_') tag) (fail "invalid benchmark tag")
      let sql = maybe (error "unknown benchmark query") id (Map.lookup queryName (queriesFor fromDay toDay))
          chosen = if evidenceOnly then "SELECT CAST('evidence','String') AS bucket,CAST('','String') AS group_key,toFloat64(0) AS value" else if baseline then Text.replace "analytics.events_resolved_http" "analytics.events_unresolved_http" sql else sql
          checkout = if baseline then withMetricsQueryConnection pool else withIdentityQueryConnection pool "bench-a" (Text.pack (show fromDay)) (Text.pack (show toDay))
      if cold then closeQueryPool pool else pure ()
      -- Instrumentation setup stays outside measured application time.
      withQueryConnection pool $ \conn -> command conn (fromString ("SET log_queries=1,log_comment='" <> Text.unpack tag <> "'"))
      began <- getMonotonicTime
      count <- checkout $ \conn -> sum . fmap length <$> select (statement chosen) conn pure
      ended <- getMonotonicTime
      pure (Aeson.object ["wall_seconds" Aeson..= (ended - began), "result_rows" Aeson..= count])

statement :: Text -> Select '[Column "bucket" ChString, Column "group_key" ChString, Column "value" Float64] Row
statement sql =
  passParameters parameters $
    unsafeMkSelect $
      const $
        Text.encodeUtf8Builder $
          sql <> "\nSETTINGS enable_analyzer=1,short_circuit_function_evaluation='force_enable', compile_expressions=0,compile_aggregate_expressions=0,compile_sort_description=0,use_query_cache=0"
  where
    parameters =
      foldr
        (\(key, value) rest -> addParameter key (toChType (Text.encodeUtf8 (Text.pack (value :: String))) :: ChString) . rest)
        id
        [ ("account_id", "bench-a"),
          ("funnel_step_1", "signup_started"),
          ("funnel_step_2", "signup_completed"),
          ("numerator_event_name_1", "signup_completed"),
          ("denominator_event_name_1", "signup_started")
        ]
