module Main (main) where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Kansoku.Client
import System.Environment (getEnv)

main :: IO ()
main = do
  credential <- Text.pack <$> getEnv "KANSOKU_API_KEY"
  withClient (defaultClientConfig "http://localhost:8080" credential) $ \client -> do
    trackEvent
      client
      emptyIds {userId = Just "user_42"}
      "user_registered"
      ["userId" Aeson..= ("user_42" :: Text.Text)]
    flush client
