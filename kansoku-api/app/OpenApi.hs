-- | Write the OpenAPI document to @docs/api/openapi.json@.
module Main (main) where

import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Kansoku.Api.OpenApi (kansokuOpenApi)
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True "docs/api"
  BSL.writeFile "docs/api/openapi.json" (encodePretty' config kansokuOpenApi <> "\n")
  putStrLn "wrote docs/api/openapi.json"
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare, confTrailingNewline = False}
