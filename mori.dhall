let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/3522f4a51181d73c9c90fc27a7c0838bd29ae95f/package.dhall
        sha256:dcb19e2312e790bad14e622cc98a1281cd2298c5b564a2f0d0534d3c718d8803

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
      , "shinzui/openapi-hs"
      , "shinzui/pg-migrate"
      , "shinzui/pgmq-hs"
      , "shinzui/servant-openapi-hs"
      , "shinzui/shibuya"
      , "shinzui/shibuya-pgmq-adapter"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Durable architecture decisions"
        }
      ]
    }
