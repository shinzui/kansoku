module Kansoku.Users.HandlerSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Kansoku.Api.Response qualified as Response
import Kansoku.Auth.Types (ApiKeyId (..), AuthenticatedPrincipal (..), CredentialKind (..), MetricsPrincipal (..))
import Kansoku.Cohort.Api (PageResult (..))
import Kansoku.Event (AccountId (..))
import Kansoku.Metrics.Filter (FilterOp (..), mkMetricFilter, parseMetricFilter)
import Kansoku.Prelude
import Kansoku.Users.Api qualified as Api
import Kansoku.Users.Handler (usersServer)
import Kansoku.Users.Validation
import Relay.Pagination qualified as R
import Servant (runHandler)
import Test.Hspec

spec :: Spec
spec = describe "Users request bounds" $ do
  it "requires paired bounded dates" $ do
    validateDates (Just (read "2026-01-01")) Nothing `shouldSatisfy` isLeft
    validateDates (Just (read "2024-01-01")) (Just (read "2026-01-01")) `shouldSatisfy` isLeft
  it "rejects empty searches and unknown orders" $ do
    validateDirectory Nothing Nothing (Just "") Nothing [] `shouldSatisfy` isLeft
    validateDirectory Nothing Nothing Nothing (Just "other") [] `shouldSatisfy` isLeft
  it "rejects event dimensions and incorrectly typed traits" $ do
    forM_ ["event_name:eq:identify", "user:company_size:eq:large", "{\"or\":[{\"dimension\":\"user:plan\",\"op\":\"eq\",\"value\":\"pro\"}]}"] $ \raw -> case parseMetricFilter raw of
      Left _ -> pure ()
      Right f -> validateDirectory Nothing Nothing Nothing Nothing [f] `shouldSatisfy` isLeft
  it "accepts canonical host eq/in and ANDs one event-name term" $ do
    forM_ [[host FilterEq (A.String "app.example")], [host FilterIn (A.toJSON (["app.example", "docs.example"] :: [Text]))], [host FilterEq (A.String "app.example"), term "event_name" FilterEq (A.String "page_view")], [host FilterEq (A.String (T.replicate 253 "a"))], [host FilterIn (A.toJSON (replicate 100 ("app.example" :: Text)))]] $ \filters ->
      history filters `shouldBe` Right ()
  it "rejects duplicate dimensions and unsupported host operations" $ do
    let h = host FilterEq (A.String "app.example")
        e = term "event_name" FilterEq (A.String "page_view")
    forM_ [[h, h], [e, e], [h, e, h], [host FilterNeq (A.String "app.example")], [host FilterContains (A.String "app")], [mkMetricFilter "host" FilterUnset Nothing]] $ \filters ->
      history filters `shouldSatisfy` isLeft
  it "bounds raw host values and requires canonical strings" $ do
    forM_ ["", "App.Example", "app.example.", "app.example:443", "https://app.example", "app.example/path", "app.example?q", "app.example#f", "user@app.example", "app example", "app\texample", T.replicate 254 "a"] $ \value ->
      history [host FilterEq (A.String value)] `shouldSatisfy` isLeft
    forM_ [A.toJSON ([] :: [Text]), A.toJSON (replicate 101 ("app.example" :: Text)), A.toJSON ([1] :: [Int])] $ \values ->
      history [host FilterIn values] `shouldSatisfy` isLeft
    history [host FilterEq (A.Bool True)] `shouldSatisfy` isLeft
  it "rejects OR groups even when they contain only a host" $
    case parseMetricFilter "{\"or\":[{\"dimension\":\"host\",\"op\":\"eq\",\"value\":\"app.example\"}]}" of
      Left err -> expectationFailure (T.unpack err)
      Right f -> validateHistory [f] `shouldSatisfy` isLeft
  it "preserves bounded event-name validation" $ do
    history [term "event_name" FilterIn (A.toJSON (["page_view", "unknown_valid"] :: [Text]))] `shouldBe` Right ()
    forM_ ["", "PageView", T.replicate 129 "a"] $ \name -> history [term "event_name" FilterEq (A.String name)] `shouldSatisfy` isLeft
  it "allows only one event-name term on the hosts facet" $ do
    validateHostFacet [] `shouldBe` Right ()
    (sequence [term "event_name" FilterEq (A.String "page_view")] >>= validateHostFacet) `shouldBe` Right ()
    forM_ [[host FilterEq (A.String "app.example")], [term "event_name" FilterEq (A.String "page_view"), term "event_name" FilterEq (A.String "identify")], [term "user:plan" FilterEq (A.String "pro")]] $ \filters ->
      (sequence filters >>= validateHostFacet) `shouldSatisfy` isLeft
  it "guards direct handler calls before accessing either database" $ do
    f <- either (fail . T.unpack) pure (host FilterEq (A.String "App.Example"))
    let server = usersServer (error "unexpected PostgreSQL access") (error "unexpected ClickHouse access")
        principal = MetricsPrincipal (AuthenticatedPrincipal (ApiKeyId UUID.nil) ServiceToken (AccountId "test"))
    result <- runHandler (Api.events server principal "alice" Nothing Nothing Nothing [f] (R.PageRequest 1 R.Forward Nothing))
    case result of
      Right (PageBad err) -> case A.toJSON err of
        A.Object fields -> KM.lookup "code" fields `shouldBe` Just (A.String "invalid_users_query")
        _ -> expectationFailure "history error is not an object"
      _ -> expectationFailure "direct history call did not reject a noncanonical host"
    facet <- runHandler (Api.hosts server principal "alice" Nothing Nothing Nothing [f])
    case facet of
      Right (Response.KansokuBadRequest problem) -> Response.code problem `shouldBe` "invalid_users_query"
      _ -> expectationFailure "direct hosts call did not reject a host filter"
  where
    history filters = traverse id filters >>= validateHistory
    term dimension op value = mkMetricFilter dimension op (Just value)
    host = term "host"
    isLeft (Left _) = True; isLeft _ = False
