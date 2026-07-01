module Main (main) where

import Kansoku.ConfigSpec qualified
import Kansoku.EventSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Kansoku.ConfigSpec.spec
  Kansoku.EventSpec.spec
