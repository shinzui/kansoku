module Main (main) where

import Kansoku.Auth.HandlerSpec qualified
import Kansoku.Auth.TokenSpec qualified
import Kansoku.ClickHouseSpec qualified
import Kansoku.ConfigSpec qualified
import Kansoku.ContractSpec qualified
import Kansoku.CorsSpec qualified
import Kansoku.EventSpec qualified
import Kansoku.HealthSpec qualified
import Kansoku.HttpIntegrationSpec qualified
import Kansoku.HttpTelemetrySpec qualified
import Kansoku.Identity.CacheSpec qualified
import Kansoku.Ingest.AcceptanceSpec qualified
import Kansoku.Ingest.AdmissionSpec qualified
import Kansoku.Ingest.BeaconSpec qualified
import Kansoku.Ingest.EnrichmentIntegrationSpec qualified
import Kansoku.Ingest.EnrichmentSpec qualified
import Kansoku.Ingest.GeoIPSpec qualified
import Kansoku.Ingest.HandlerSpec qualified
import Kansoku.Ingest.QueueSpec qualified
import Kansoku.Ingest.RateLimitSpec qualified
import Kansoku.Ingest.ServiceSpec qualified
import Kansoku.Ingest.TimestampSpec qualified
import Kansoku.LimitsSpec qualified
import Kansoku.Metrics.AcquisitionIntegrationSpec qualified
import Kansoku.Metrics.ActivityIntegrationSpec qualified
import Kansoku.Metrics.FilterIntegrationSpec qualified
import Kansoku.Metrics.FilterSpec qualified
import Kansoku.Metrics.FunnelIntegrationSpec qualified
import Kansoku.Metrics.FunnelReferenceSpec qualified
import Kansoku.Metrics.HandlerSpec qualified
import Kansoku.Metrics.LimitsSpec qualified
import Kansoku.Metrics.RoutingSpec qualified
import Kansoku.Metrics.SessionIntegrationSpec qualified
import Kansoku.Metrics.TraitsSpec qualified
import Kansoku.MigrationsSpec qualified
import Kansoku.Observability (registerPipelineMetrics)
import Kansoku.ObservabilitySpec qualified
import Kansoku.OpenApiSpec qualified
import Kansoku.ProblemSpec qualified
import Kansoku.QueryBenchmark qualified
import Kansoku.QueryIntegrationSpec qualified
import Kansoku.QueryPoolSpec qualified
import Kansoku.QuerySpec qualified
import Kansoku.ReadinessSpec qualified
import Kansoku.RequestLogSpec qualified
import Kansoku.Writer.BatchSpec qualified
import Kansoku.Writer.LifecycleSpec qualified
import Kansoku.Writer.OutageSpec qualified
import Kansoku.Writer.RecoverySpec qualified
import System.Environment (lookupEnv)
import Test.Hspec (hspec, runIO)

main :: IO ()
main = do
  sessionMode <- lookupEnv "KANSOKU_IDENTITY_BENCH_SESSION"
  benchmarkMode <- lookupEnv "KANSOKU_IDENTITY_BENCH_SQL"
  outageMode <- lookupEnv "KANSOKU_PIPELINE_OUTAGE_CHILD"
  childMode <- lookupEnv "KANSOKU_TELEMETRY_LIFECYCLE_CHILD"
  case (sessionMode, benchmarkMode, outageMode, childMode) of
    (Just _, _, _, _) -> Kansoku.QueryBenchmark.runSession
    (_, Just _, _, _) -> Kansoku.QueryBenchmark.emitSql
    (_, _, Just _, _) -> hspec Kansoku.Writer.OutageSpec.spec
    (_, _, _, Just _) -> Kansoku.HttpTelemetrySpec.lifecycleChild
    _ -> normalTests

normalTests :: IO ()
normalTests = hspec $ do
  metrics <- runIO registerPipelineMetrics
  Kansoku.Auth.HandlerSpec.spec
  Kansoku.Auth.TokenSpec.spec
  Kansoku.ConfigSpec.spec
  Kansoku.ContractSpec.spec
  Kansoku.CorsSpec.spec
  Kansoku.ClickHouseSpec.spec
  Kansoku.EventSpec.spec
  Kansoku.HealthSpec.spec
  Kansoku.Identity.CacheSpec.spec
  Kansoku.Ingest.BeaconSpec.spec metrics
  Kansoku.Ingest.AcceptanceSpec.spec metrics
  Kansoku.Ingest.HandlerSpec.spec
  Kansoku.Ingest.GeoIPSpec.spec
  Kansoku.Ingest.EnrichmentIntegrationSpec.spec metrics
  Kansoku.Ingest.EnrichmentSpec.spec
  Kansoku.Ingest.QueueSpec.spec
  Kansoku.Ingest.TimestampSpec.spec
  Kansoku.Ingest.ServiceSpec.spec metrics
  Kansoku.Ingest.RateLimitSpec.spec
  Kansoku.Ingest.AdmissionSpec.spec metrics
  Kansoku.HttpIntegrationSpec.spec
  Kansoku.LimitsSpec.spec
  Kansoku.MigrationsSpec.spec
  Kansoku.Metrics.FilterSpec.spec
  Kansoku.Metrics.AcquisitionIntegrationSpec.spec
  Kansoku.Metrics.ActivityIntegrationSpec.spec
  Kansoku.Metrics.SessionIntegrationSpec.spec
  Kansoku.Metrics.FilterIntegrationSpec.spec
  Kansoku.Metrics.TraitsSpec.spec
  Kansoku.Metrics.FunnelReferenceSpec.spec
  Kansoku.Metrics.FunnelIntegrationSpec.spec
  Kansoku.Metrics.HandlerSpec.spec
  Kansoku.Metrics.LimitsSpec.spec
  Kansoku.Metrics.RoutingSpec.spec
  Kansoku.OpenApiSpec.spec
  Kansoku.ProblemSpec.spec
  Kansoku.ObservabilitySpec.spec metrics
  Kansoku.QueryIntegrationSpec.spec
  Kansoku.QueryPoolSpec.spec
  Kansoku.QuerySpec.spec
  Kansoku.ReadinessSpec.spec
  Kansoku.RequestLogSpec.spec
  Kansoku.HttpTelemetrySpec.spec
  Kansoku.Writer.BatchSpec.spec metrics
  Kansoku.Writer.LifecycleSpec.spec metrics
  Kansoku.Writer.RecoverySpec.spec metrics
