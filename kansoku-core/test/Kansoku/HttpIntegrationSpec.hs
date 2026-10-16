module Kansoku.HttpIntegrationSpec (spec) where

import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Test (withMigratedDatabase)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Api.Response (ProblemDetails)
import Kansoku.Auth.Issue (issueKey)
import Kansoku.Auth.Token (Token (..))
import Kansoku.Auth.Types (CredentialKind (ServiceToken))
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Config (Config (..))
import Kansoku.Event
import Kansoku.Ingest.Queue qualified as Queue
import Kansoku.Maintenance (closeMaintenancePool, newMaintenancePool)
import Kansoku.Metrics.Api (MetricResult)
import Kansoku.Migrations (kansokuMigrationPlan)
import Kansoku.Postgres (createPool)
import Kansoku.Prelude
import Kansoku.Server (ReadyProbe (..), kansokuApp)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (status200, status400)
import Network.HTTP.Types.Header (hAuthorization)
import Network.Wai.Handler.Warp qualified as Warp
import Test.Hspec

spec :: Spec
spec = describe "Kansoku property metrics HTTP integration" $ do
  it "serves account-scoped revenue and feature groups and rejects undeclared properties" $
    withClickHouse $ \clickHouse -> do
      resetTable clickHouse
      insertEvents clickHouse fixtures
      plan <-
        case kansokuMigrationPlan of
          Left err -> expectationFailure (show err) >> fail "invalid migration plan"
          Right validPlan -> pure validPlan
      migrated <-
        withMigratedDatabase plan $ \connection -> do
          connectionString <- requireConnectionString connection
          bracket ((,) <$> createPool connectionString <*> newMaintenancePool connectionString) (\(pool, maintenance) -> Pool.release pool >> closeMaintenancePool maintenance) $ \(pool, maintenance) -> do
            token <- requireServiceToken pool
            config <- requireConfig
            queryPool <- newQueryPool (clickHouseConfigFromConfig config) 2
            let appConfig =
                  config
                    & #pgConnectionString
                    .~ connectionString
                    & #internalMetricsEnabled
                    .~ False
                readyProbe =
                  ReadyProbe
                    { writerAlive = pure True,
                      pgmqReachable = pure (Right ()),
                      clickhouseReachable = pure True,
                      pipelineReady = pure []
                    }
            app <- kansokuApp maintenance (error "unused ingest metrics") appConfig readyProbe pool (Queue.eventsQueueName "ep17_http_unused") queryPool
            Warp.testWithApplication (pure app) $ \port -> do
              manager <- Http.newManager Http.defaultManagerSettings

              revenue <- getMetric manager port token "/metrics/revenue?from=2026-07-10&to=2026-07-11&groupBy=prop:plan"
              revenue ^. #metric `shouldBe` "revenue"
              metricGroups "prop:plan" revenue `shouldBe` Map.fromList [("free", 9), ("pro", 98)]

              adoption <- getMetric manager port token "/metrics/feature-adoption?from=2026-07-10&to=2026-07-11&groupBy=prop:feature"
              adoption ^. #metric `shouldBe` "feature_adoption"
              metricGroups "prop:feature" adoption `shouldBe` Map.fromList [("export", 1), ("search", 2)]

              rejected <- authorizedGet manager port token "/metrics/revenue?from=2026-07-10&to=2026-07-11&groupBy=prop:nope"
              Http.responseStatus rejected `shouldBe` status400
              envelope <- decodeBody rejected :: IO ProblemDetails
              envelope ^. #code `shouldBe` "unknown_property"
              envelope ^. #detail `shouldBe` "unknown property nope for event payment_completed"

      case migrated of
        Left err -> expectationFailure ("ephemeral HTTP integration database failed: " <> show err)
        Right () -> pure ()

getMetric :: Http.Manager -> Warp.Port -> Token -> String -> IO MetricResult
getMetric manager port token path = do
  response <- authorizedGet manager port token path
  Http.responseStatus response `shouldBe` status200
  decodeBody response

authorizedGet :: Http.Manager -> Warp.Port -> Token -> String -> IO (Http.Response LazyByteString.ByteString)
authorizedGet manager port (Token token) path = do
  initial <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
  Http.httpLbs
    initial
      { Http.requestHeaders =
          [(hAuthorization, "Bearer " <> Text.Encoding.encodeUtf8 token)],
        Http.checkResponse = \_ _ -> pure ()
      }
    manager

decodeBody :: (FromJSON value) => Http.Response LazyByteString.ByteString -> IO value
decodeBody response =
  case Aeson.eitherDecode (Http.responseBody response) of
    Left err -> expectationFailure ("invalid HTTP JSON body: " <> err) >> fail err
    Right value -> pure value

metricGroups :: Text -> MetricResult -> Map.Map Text Double
metricGroups property result =
  Map.fromList
    [ (groupValue, point ^. #value)
    | point <- result ^. #points,
      Just (Just groupValue) <- [Map.lookup property (point ^. #group)]
    ]

requireServiceToken :: Pool.Pool -> IO Token
requireServiceToken pool = do
  issued <- issueKey pool ServiceToken fixtureAccount "EP-17 HTTP integration"
  case issued of
    Left err -> expectationFailure ("service-token issuance failed: " <> show err) >> fail "service-token issuance failed"
    Right (_, token) -> pure token

requireConnectionString :: Connection.Connection -> IO Text
requireConnectionString connection = do
  result <- Connection.use connection (Session.statement () connectionInfoStatement)
  case result of
    Left err -> expectationFailure ("ephemeral connection-info query failed: " <> show err) >> fail "connection-info query failed"
    Right (socketDirectory, port, user, database) ->
      pure
        ( "host="
            <> socketDirectory
            <> " port="
            <> port
            <> " user="
            <> user
            <> " dbname="
            <> database
        )

connectionInfoStatement :: Statement.Statement () (Text, Text, Text, Text)
connectionInfoStatement =
  Statement.preparable
    "SELECT current_setting('unix_socket_directories'), current_setting('port'), current_user::text, current_database()::text"
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,,)
            <$> textColumn
            <*> textColumn
            <*> textColumn
            <*> textColumn
        )
    )
  where
    textColumn = Decoders.column (Decoders.nonNullable Decoders.text)

fixtureAccount :: AccountId
fixtureAccount = AccountId "acct_ep17_http"

fixtures :: [AnalyticsEvent]
fixtures =
  [ propertyEvent fixtureAccount "ep17-pay-1" "payment_completed" "user-1" [("amount", Aeson.Number 49), ("plan", Aeson.String "pro")],
    propertyEvent fixtureAccount "ep17-pay-2" "payment_completed" "user-2" [("amount", Aeson.Number 49), ("plan", Aeson.String "pro")],
    propertyEvent fixtureAccount "ep17-pay-3" "payment_completed" "user-3" [("amount", Aeson.Number 9), ("plan", Aeson.String "free")],
    propertyEvent fixtureAccount "ep17-feature-1" "feature_used" "user-1" [("feature", Aeson.String "search")],
    propertyEvent fixtureAccount "ep17-feature-2" "feature_used" "user-2" [("feature", Aeson.String "search")],
    propertyEvent fixtureAccount "ep17-feature-3" "feature_used" "user-3" [("feature", Aeson.String "export")],
    propertyEvent (AccountId "acct_ep17_other") "ep17-other-pay" "payment_completed" "other-user" [("amount", Aeson.Number 999), ("plan", Aeson.String "pro")]
  ]

propertyEvent :: AccountId -> Text -> Text -> Text -> [(Key, Aeson.Value)] -> AnalyticsEvent
propertyEvent account eventId eventName user properties =
  baseEvent (EventId eventId) (EventName eventName) Service (read "2026-07-10 12:00:00 UTC") (read "2026-07-10 12:00:01 UTC")
    & #accountId
    .~ Just account
    & #userId
    .~ Just (UserId user)
    & #properties
    .~ KeyMap.fromList properties
