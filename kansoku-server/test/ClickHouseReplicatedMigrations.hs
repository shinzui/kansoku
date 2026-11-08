-- Run the repository-owned fixture on the required local Apple Container runtime.
module Main (main) where

import System.Environment (getArgs)
import System.Exit (exitWith)
import System.Process (rawSystem)

main :: IO ()
main = getArgs >>= \args -> rawSystem "python3" ("scripts/apple_clickhouse_fixture.py" : args) >>= exitWith
