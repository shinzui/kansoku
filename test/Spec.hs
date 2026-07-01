module Main (main) where

import Kansoku.ClickHouseSpec qualified
import Kansoku.ConfigSpec qualified
import Kansoku.EventSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Kansoku.ConfigSpec.spec
  Kansoku.ClickHouseSpec.spec
  Kansoku.EventSpec.spec
