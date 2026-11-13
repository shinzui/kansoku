module Kansoku.HealthSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.IORef
import Data.Text (Text)
import Data.Time.Clock
import Kansoku.Config (loadConfig)
import Kansoku.Health (probePaths)
import Kansoku.Prelude ((&), (.~))
import Kansoku.Readiness (ReadyCheckFailure (..))
import Kansoku.Server (ReadyProbe (..), kansokuAppWithChecks, kansokuAppWithPipelineChecks, newPipelineProbeChecks, newProbeChecks)
import Kansoku.Writer.Recovery (BreakerState (Closed))
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hContentType, status200, status404, status503)
import Network.Wai.Handler.Warp qualified as Warp
import Servant.Health
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Health production checks" $ do
  it "retains failure onset across requests, resets after recovery, and leaves liveness healthy" $ do
    available <- newIORef False
    let probe = healthy & #clickhouseReachable .~ readIORef available
    (live, admission, ready) <- newPipelineProbeChecks probe
    first <- ready
    threadDelay 1_000
    ready `shouldReturn` first
    live `shouldReturn` Healthy
    admission `shouldReturn` Healthy
    writeIORef available True
    ready `shouldReturn` Healthy
    writeIORef available False
    later <- ready
    later `shouldNotBe` first

  it "never evaluates storage or writer checks for admission" $ do
    let unavailable :: IO a
        unavailable = fail "admission evaluated a storage callback"
        probe = healthy & #writerAlive .~ unavailable & #clickhouseReachable .~ unavailable & #topologyReady .~ unavailable & #storageState .~ unavailable & #pipelineReady .~ unavailable
    (_, ready) <- newProbeChecks probe
    ready `shouldReturn` Healthy

  it "converts synchronous check exceptions without disclosing details" $ do
    (_, ready) <- newProbeChecks (healthy & #pgmqReachable .~ throwIO (userError "private credential"))
    verdict <- ready
    verdict `shouldSatisfy` named "pgmq_reachable"

  it "times out native-check slots within 750ms plus at most 250ms scheduling tolerance" $ do
    (_, _, ready) <- newPipelineProbeChecks (healthy & #clickhouseReachable .~ (threadDelay 5_000_000 >> pure True))
    started <- getCurrentTime
    ready >>= (`shouldSatisfy` named "clickhouse_query_reachable")
    elapsed <- realToFrac . (`diffUTCTime` started) <$> getCurrentTime :: IO Double
    elapsed `shouldSatisfy` (< 1.0)

  it "propagates asynchronous cancellation" $ do
    (_, _, ready) <- newPipelineProbeChecks (healthy & #clickhouseReachable .~ (threadDelay 5_000_000 >> pure True))
    withAsync ready $ \worker -> do
      threadDelay 20_000
      cancel worker
      waitCatch worker >>= (`shouldSatisfy` either (const True) (const False))

  it "serves both failing checks through production assembly outside ingest middleware" $ do
    cfg <- loadConfig >>= either (fail . show) pure
    now <- getCurrentTime
    let failed = pure (Unhealthy "injected" now)
        unused = error "probe touched analytics dependency"
        app = kansokuAppWithChecks failed failed unused cfg unused unused unused
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      mapM_ (assertFailure manager port) ["/health/live", "/health/ready", "/health/pipeline"]
    probePaths `shouldBe` ["/health/live", "/health/ready", "/health/pipeline"]

  it "reports the first failing pipeline check through pipeline health while admission stays healthy" $ do
    let probe = healthy & #pipelineReady .~ pure [QueueDepthExceeded {observed = 101, limit = 100}]
    (live, admission, ready) <- newPipelineProbeChecks probe
    ready >>= (`shouldSatisfy` named "queue_depth")
    live `shouldReturn` Healthy
    admission `shouldReturn` Healthy

  it "serves pipeline failure independently of admission with the canonical schema" $ do
    cfg <- loadConfig >>= either (fail . show) pure
    now <- getCurrentTime
    let unused = error "probe touched analytics dependency"
        app = kansokuAppWithPipelineChecks (pure Healthy) (pure Healthy) (pure (Unhealthy "clickhouse_topology_mismatch" now)) unused cfg unused unused unused
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      req <- Http.parseRequest ("http://127.0.0.1:" <> show port <> "/health/ready")
      Http.httpLbs req manager >>= (\response -> Http.responseStatus response `shouldBe` status200)
      assertFailure manager port "/health/pipeline"

  it "bounds the complete pipeline endpoint even when individually healthy slots accumulate" $ do
    let probe =
          healthy
            & #writerAlive
            .~ (threadDelay 600_000 >> pure True)
            & #pgmqReachable
            .~ (threadDelay 600_000 >> pure (Right ()))
            & #topologyReady
            .~ (threadDelay 600_000 >> pure Nothing)
            & #storageState
            .~ (threadDelay 600_000 >> pure Closed)
    (_, _, pipeline) <- newPipelineProbeChecks probe
    started <- getCurrentTime
    pipeline >>= (`shouldSatisfy` named "pipeline")
    elapsed <- realToFrac . (`diffUTCTime` started) <$> getCurrentTime :: IO Double
    elapsed `shouldSatisfy` (< 2.25)

  it "keeps admission and pipeline failure onset independent" $ do
    pg <- newIORef (Left "unavailable")
    let probe = healthy & #pgmqReachable .~ readIORef pg & #topologyReady .~ pure (Just "clickhouse_topology_unavailable")
    (_, ready, pipeline) <- newPipelineProbeChecks probe
    firstReady <- ready
    firstPipeline <- pipeline
    threadDelay 1_000
    writeIORef pg (Right ())
    ready `shouldReturn` Healthy
    next <- pipeline
    case (firstPipeline, next) of
      (Unhealthy "pgmq_reachable" began, Unhealthy "clickhouse_topology_unavailable" continued) -> continued `shouldBe` began
      _ -> expectationFailure "pipeline failure onset did not survive a changed failing check"
    writeIORef pg (Left "unavailable")
    ready >>= (`shouldNotBe` firstReady)

  it "returns ordinary routing failures for the retired probe endpoints" $ do
    cfg <- loadConfig >>= either (fail . show) pure
    let unused = error "retired probe touched analytics dependency"
        app = kansokuAppWithChecks (pure Healthy) (pure Healthy) unused cfg unused unused unused
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      mapM_
        ( \path -> do
            req <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
            response <- Http.httpLbs req manager
            Http.responseStatus response `shouldBe` status404
            lookup hContentType (Http.responseHeaders response) `shouldBe` Just "application/problem+json"
        )
        ["/health", "/ready"]

assertFailure :: Http.Manager -> Int -> String -> Expectation
assertFailure manager port path = do
  req <- Http.parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- Http.httpLbs req manager
  Http.responseStatus response `shouldBe` status503
  lookup hContentType (Http.responseHeaders response) `shouldBe` Just "application/json;charset=utf-8"
  let decoded = Aeson.decode (Http.responseBody response) :: Maybe ProbeStatus
  fmap status decoded `shouldBe` Just "failed"

named :: Text -> ProbeVerdict -> Bool
named name (Unhealthy check _) = check == name
named _ Healthy = False

healthy :: ReadyProbe
healthy =
  ReadyProbe
    { writerAlive = pure True,
      pgmqReachable = pure (Right ()),
      clickhouseReachable = pure True,
      topologyReady = pure Nothing,
      storageState = pure Closed,
      pipelineReady = pure []
    }
