module Main (main) where

import Kansoku.Admin (runAdmin)
import System.Environment (getArgs)

main :: IO ()
main = getArgs >>= runAdmin
