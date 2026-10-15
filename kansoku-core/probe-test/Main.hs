module Main (main) where

import Kansoku.Config (loadConfig)
import Kansoku.Server (kansokuAppWithChecks)
import Servant.Health.TestKit (probeContractTests)
import Test.Tasty (defaultMain)

main :: IO ()
main = defaultMain (probeContractTests "Kansoku production probes" build)
  where
    build live ready = do
      config <- loadConfig >>= either (fail . show) pure
      pure (kansokuAppWithChecks live ready config unused unused unused unused)
    unused = error "probe touched an analytics dependency"
