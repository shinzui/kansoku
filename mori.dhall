let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/06588f0a31e97784398f1260bc88321684219908/package.dhall
        sha256:4f9f90bd930eb8d27e8bce70e504d7d366bc302d58a139c9b6874b8c51c952e4

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "kansoku"
      , namespace = "shinzui"
      , type = Schema.PackageType.Application
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "First-party product, web, and server-side analytics service — a ClickHouse-native observation layer for user, application, and business-event behavior"
      , domains = [ "Analytics", "Backend" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "kansoku", github = Some "shinzui/kansoku" } ]
    , packages =
      [ Schema.Package::{
        , name = "kansoku-api"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kansoku-api"
        , description = Some "servant route types, wire DTOs, event model, validation, and shared prelude"
        }
      , Schema.Package::{
        , name = "kansoku-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kansoku-core"
        , description = Some "core runtime, storage adapters, ingestion, metrics, OpenAPI generation, and HTTP app assembly"
        , dependencies = [ Schema.Dependency.ByName "kansoku-api" ]
        }
      , Schema.Package::{
        , name = "kansoku-server"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "kansoku-server"
        , description = Some "servant/warp HTTP application — the kansoku-server executable"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "kansoku-core"
          , Schema.Dependency.ByName "kansoku-api"
          ]
        }
      , Schema.Package::{
        , name = "kansoku-client"
        , type = Schema.PackageType.Client
        , language = Schema.Language.Haskell
        , path = Some "kansoku-client"
        , description = Some "typed Haskell client derived from kansoku-api"
        , dependencies = [ Schema.Dependency.ByName "kansoku-api" ]
        }
      ]
    , dependencies =
      [ "KovalevDima/ClickHaskell"
      , "shinzui/hasql-migration"
      , "shinzui/openapi-hs"
      , "shinzui/pgmq-hs"
      , "shinzui/servant-openapi-hs"
      , "shinzui/shibuya"
      , "shinzui/shibuya-pgmq-adapter"
      ]
    }
