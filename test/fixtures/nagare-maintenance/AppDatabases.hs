{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Nagare.Dsl.AppDatabase
import Nagare.Dsl.Config (emitAppDatabases)
import Nagare.Dsl.Database (Engine (..))
import Nagare.Dsl.Types (mkAppDatabaseName, mkDatabaseName, mkNamespace)

ok :: Either Text a -> a
ok = either (error . show) id

app :: Text -> Text -> Engine -> [Text] -> AppDatabaseAccess -> AppDatabase
app name server engine (db : dbs) access = AppDatabase (ok (mkAppDatabaseName name)) Nothing (ok (mkDatabaseName server)) engine (ok (mkNamespace "personal")) (ok (mapM mkLogicalDatabaseName (db :| dbs))) access NagareManaged
app _ _ _ [] _ = error "empty database set"

main :: IO ()
main =
  emitAppDatabases
    [ app "kansoku-pg-app" "kansoku-pg" Postgres ["kansoku"] (noAppDatabaseAccess & #monitoring .~ [PgMonitor] & #privileges . #runtime . #createIn .~ [ok (mkSchemaName "pgmq")]),
      app
        "kansoku-ch-app"
        "kansoku-ch"
        ClickHouse
        ["analytics", "kansoku_migration_ledger"]
        ( noAppDatabaseAccess
            & #runtime .~ UserAccess [SystemParts, ArbitraryTemporaryTables] noUserLimits
            & #migration .~ UserAccess [SystemDisks, SystemStoragePolicies, SystemMutations] noUserLimits
        ),
      app "other-ch-app" "kansoku-ch" ClickHouse ["other_app"] noAppDatabaseAccess
    ]
