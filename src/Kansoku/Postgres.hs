-- | PostgreSQL connection pool helpers.
module Kansoku.Postgres
  ( createPool,
  )
where

import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Kansoku.Prelude

createPool :: Text -> IO Pool.Pool
createPool connectionString = do
  let poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.staticConnectionSettings (Settings.connectionString connectionString)
          ]
  Pool.acquire poolConfig
