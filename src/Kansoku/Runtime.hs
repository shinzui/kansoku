-- | The application's effect stack and its runner. This is the extension point
-- every later plan builds on.
module Kansoku.Runtime
  ( AppEffects,
    runApp,
  )
where

import Effectful (Eff, IOE, runEff)
import Effectful.Reader.Static (Reader, runReader)
import Kansoku.Config (Config)
import Kansoku.Logging (Log, runLogStderr)
import Kansoku.Prelude ()

-- | The base effect stack for the service.
type AppEffects = '[Log, Reader Config, IOE]

-- | Run an AppEffects computation in IO by discharging each effect.
runApp :: Config -> Eff AppEffects a -> IO a
runApp cfg = runEff . runReader cfg . runLogStderr
