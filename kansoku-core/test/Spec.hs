module Main (main) where

import Kansoku.Auth.HandlerSpec qualified
import Kansoku.Auth.TokenSpec qualified
import Kansoku.ClickHouseSpec qualified
import Kansoku.ConfigSpec qualified
import Kansoku.CorsSpec qualified
import Kansoku.EventSpec qualified
import Kansoku.HttpIntegrationSpec qualified
import Kansoku.Ingest.HandlerSpec qualified
import Kansoku.Ingest.QueueSpec qualified
import Kansoku.LimitsSpec qualified
import Kansoku.Metrics.HandlerSpec qualified
import Kansoku.Metrics.RoutingSpec qualified
import Kansoku.MigrationsSpec qualified
import Kansoku.Observability (registerPipelineMetrics)
import Kansoku.ObservabilitySpec qualified
import Kansoku.OpenApiSpec qualified
import Kansoku.QueryIntegrationSpec qualified
import Kansoku.QuerySpec qualified
import Kansoku.ReadinessSpec qualified
import Kansoku.Writer.BatchSpec qualified
import Test.Hspec (hspec, runIO)

main :: IO ()
main = hspec $ do
  metrics <- runIO registerPipelineMetrics
  Kansoku.Auth.HandlerSpec.spec
  Kansoku.Auth.TokenSpec.spec
  Kansoku.ConfigSpec.spec
  Kansoku.CorsSpec.spec
  Kansoku.ClickHouseSpec.spec
  Kansoku.EventSpec.spec
  Kansoku.Ingest.HandlerSpec.spec
  Kansoku.Ingest.QueueSpec.spec
  Kansoku.HttpIntegrationSpec.spec
  Kansoku.LimitsSpec.spec
  Kansoku.MigrationsSpec.spec
  Kansoku.Metrics.HandlerSpec.spec
  Kansoku.Metrics.RoutingSpec.spec
  Kansoku.OpenApiSpec.spec
  Kansoku.ObservabilitySpec.spec metrics
  Kansoku.QueryIntegrationSpec.spec
  Kansoku.QuerySpec.spec
  Kansoku.ReadinessSpec.spec
  Kansoku.Writer.BatchSpec.spec metrics
