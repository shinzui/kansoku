module Main (main) where

import Kansoku.ClickHouseSpec qualified
import Kansoku.ConfigSpec qualified
import Kansoku.EventSpec qualified
import Kansoku.Ingest.QueueSpec qualified
import Kansoku.Metrics.RoutingSpec qualified
import Kansoku.MigrationsSpec qualified
import Kansoku.OpenApiSpec qualified
import Kansoku.QueryIntegrationSpec qualified
import Kansoku.QuerySpec qualified
import Kansoku.Writer.BatchSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Kansoku.ConfigSpec.spec
  Kansoku.ClickHouseSpec.spec
  Kansoku.EventSpec.spec
  Kansoku.Ingest.QueueSpec.spec
  Kansoku.MigrationsSpec.spec
  Kansoku.Metrics.RoutingSpec.spec
  Kansoku.OpenApiSpec.spec
  Kansoku.QueryIntegrationSpec.spec
  Kansoku.QuerySpec.spec
  Kansoku.Writer.BatchSpec.spec
