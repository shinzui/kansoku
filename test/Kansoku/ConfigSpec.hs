module Kansoku.ConfigSpec (spec) where

import Data.Generics.Labels ()
import Kansoku.Config (loadConfig)
import Kansoku.Prelude
import System.Environment (setEnv, unsetEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- | Ensure a clean slate for the variables loadConfig reads.
clearEnv :: IO ()
clearEnv =
  mapM_
    unsetEnv
    [ "PG_CONNECTION_STRING",
      "CLICKHOUSE_TCP_PORT",
      "CLICKHOUSE_HTTP_PORT",
      "KANSOKU_SERVER_PORT"
    ]

spec :: Spec
spec = describe "Kansoku.Config.loadConfig" $ do
  it "uses defaults when nothing is set" $ do
    clearEnv
    result <- loadConfig
    case result of
      Left err -> fail ("expected defaults, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #clickHouseHost) `shouldBe` "127.0.0.1"
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9000
        (cfg ^. #clickHouseHttpPort) `shouldBe` 8123
        (cfg ^. #clickHouseDatabase) `shouldBe` "analytics"
        (cfg ^. #serverPort) `shouldBe` 8080

  it "parses values from the environment" $ do
    clearEnv
    setEnv "PG_CONNECTION_STRING" "postgresql:///kansoku"
    setEnv "CLICKHOUSE_TCP_PORT" "9100"
    setEnv "KANSOKU_SERVER_PORT" "9999"
    result <- loadConfig
    clearEnv
    case result of
      Left err -> fail ("expected a config, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #pgConnectionString) `shouldBe` "postgresql:///kansoku"
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9100
        (cfg ^. #serverPort) `shouldBe` 9999

  it "rejects a non-numeric port with a Left" $ do
    clearEnv
    setEnv "KANSOKU_SERVER_PORT" "not-a-number"
    result <- loadConfig
    clearEnv
    result `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True
    isLeft _ = False
