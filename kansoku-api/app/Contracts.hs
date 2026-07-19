-- | Write the public event schema catalog to @docs/contracts/events.json@.
module Main (main) where

import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Kansoku.Event (defaultRegistry, schemaCatalog)
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True "docs/contracts"
  BSL.writeFile "docs/contracts/events.json" (encodePretty' config (schemaCatalog defaultRegistry) <> "\n")
  putStrLn "wrote docs/contracts/events.json"
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare, confTrailingNewline = False}
