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
      , "shinzui/clickhouse-migrate" -- mori://shinzui/clickhouse-migrate
      , "shinzui/pg-migrate"
      , "shinzui/pgmq-hs"
      , "shinzui/servant-openapi-hs"
      , "shinzui/shibuya"
      , "shinzui/shibuya-pgmq-adapter"
      ]
    , apis =
      [ Schema.Api::{
        , name = "kansoku-api"
        , type = Schema.ApiType.OpenAPI
        , specPath = "docs/api/openapi.json"
        , owner = "kansoku-api"
        , ownerRef = Some Schema.MoriRef::{
          , namespace = "shinzui"
          , name = "kansoku"
          , kind = Some Schema.MoriArtifactKind.Package
          , key = Some "kansoku-api"
          }
        , dependencies =
          [ Schema.ApiDependency::{
            , package = "kansoku-client"
            , packageRef = Some Schema.MoriRef::{
              , namespace = "shinzui"
              , name = "kansoku"
              , kind = Some Schema.MoriArtifactKind.Package
              , key = Some "kansoku-client"
              }
            , role = Schema.ApiDependencyRole.Client
            }
          ]
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Durable architecture decisions"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Artifact review records with stable REV handles"
        }
      , Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "What Kansoku provides today, with stable CAP handles, compatibility limits and evidence"
        }
      , Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Kansoku-owned improvement requests with stable IR handles"
        }
      , Schema.OkfBundle::{
        , name = "terminology"
        , path = "docs/terminology"
        , profile = Some "docs/terminology/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Controlled Kansoku vocabulary with stable TERM handles and evidence anchors"
        }
      , Schema.OkfBundle::{
        , name = "guides"
        , path = "docs/guides"
        , profile = Some "docs/guides/profile.dhall"
        , profileBinding = Some
            ( Schema.ProfileBinding.Published
                Schema.PinnedImport::{
                , publisher = "shinzui/okf-profiles"
                , publisherRef = Some
                    Schema.MoriRef::{ namespace = "shinzui", name = "okf-profiles" }
                , export = Some "documentation.userDocumentation"
                , version = Some "v0.20.0"
                , pin = Some
                    "sha256:079a5b3679dccafd2070535b3d59a0ffdf28e20bf9cacfe095dca96c8012879a"
                }
            )
        , okfVersion = "0.2"
        , description = Some "Reader-facing guides, tutorials, explanations, reference material and operational runbooks with stable DOC handles"
        }
      , Schema.OkfBundle::{
        , name = "research"
        , path = "docs/research"
        , profile = Some "docs/research/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Research records with stable RES handles"
        }
      ]
    }
