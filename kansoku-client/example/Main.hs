module Main (main) where

import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Kansoku.Client
import Kansoku.Prelude

main :: IO ()
main =
  withClient (defaultClientConfig "http://localhost:8080") $ \client -> do
    trackEvent
      client
      (emptyIds & #userId ?~ "user_42")
      "user_registered"
      ["plan" Aeson..= ("pro" :: Text)]
    flush client
