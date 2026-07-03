module Main (main) where

import Kansoku.ClickHouseSpec qualified
import Kansoku.ConfigSpec qualified
import Kansoku.EventSpec qualified
import Kansoku.Ingest.QueueSpec qualified
import Kansoku.OpenApiSpec qualified
import Kansoku.QuerySpec qualified
import Kansoku.Writer.BatchSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Kansoku.ConfigSpec.spec
  Kansoku.ClickHouseSpec.spec
  Kansoku.EventSpec.spec
  Kansoku.Ingest.QueueSpec.spec
  Kansoku.OpenApiSpec.spec
  Kansoku.QuerySpec.spec
  Kansoku.Writer.BatchSpec.spec
