-- Fast Nix-native checks by default; retain exact production-version qualification.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitWith)
import System.Process (rawSystem)

main :: IO ()
main = do
  args <- getArgs
  let (script, cases) = case args of
        "--production-fixture" : rest -> ("scripts/apple_clickhouse_fixture.py", rest)
        _ -> ("scripts/native_clickhouse_fixture.py", args)
  rawSystem "python3" (script : cases) >>= exitWith
