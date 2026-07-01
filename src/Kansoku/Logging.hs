{-# LANGUAGE TypeFamilies #-}

-- | A minimal structured-logging effect. One JSON object per line to stderr.
module Kansoku.Logging
  ( Log,
    LogLevel (..),
    logError,
    logInfo,
    logMsg,
    logWarn,
    runLogStderr,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    IOE,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)
import Kansoku.Prelude
import System.IO qualified as IO

-- | Severity of a log line.
data LogLevel = Info | Warn | Error
  deriving stock (Generic, Eq, Show)

-- | The logging effect. A single first-order operation: emit one message.
data Log :: Effect where
  LogMsg :: LogLevel -> Text -> Log m ()

type instance DispatchOf Log = Dynamic

-- | Emit a message at an explicit level.
logMsg :: (Log :> es) => LogLevel -> Text -> Eff es ()
logMsg lvl msg = send (LogMsg lvl msg)

-- | Convenience wrappers.
logInfo, logWarn, logError :: (Log :> es) => Text -> Eff es ()
logInfo = logMsg Info
logWarn = logMsg Warn
logError = logMsg Error

-- | Interpret the Log effect by writing one JSON object per line to stderr.
runLogStderr :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLogStderr = interpret $ \_ -> \case
  LogMsg lvl msg ->
    liftIO . LBS8.hPutStrLn IO.stderr $
      Aeson.encode (Aeson.object ["level" Aeson..= levelText lvl, "message" Aeson..= msg])
  where
    levelText :: LogLevel -> Text
    levelText = \case
      Info -> "info"
      Warn -> "warn"
      Error -> "error"
