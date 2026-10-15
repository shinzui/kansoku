module Kansoku.HealthSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Text (Text)
import Data.Time.Clock
import Kansoku.Config (loadConfig)
import Kansoku.Health (probePaths)
import Kansoku.Server (ReadyProbe (..), kansokuAppWithChecks, newProbeChecks)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hContentType, status503)
import Network.Wai.Handler.Warp qualified as Warp
import Servant.Health
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Health production checks" $ do
  it "retains failure onset across requests, resets after recovery, and leaves liveness healthy" $ do
    available <- newIORef False
    let probe = healthy {clickhouseReachable = readIORef available}
    (live, ready) <- newProbeChecks probe
    first <- ready
    threadDelay 1_000
    ready `shouldReturn` first
    live `shouldReturn` Healthy
    writeIORef available True
    ready `shouldReturn` Healthy
    writeIORef available False
    later <- ready
    later `shouldNotBe` first

  it "converts synchronous check exceptions without disclosing details" $ do
    (_, ready) <- newProbeChecks (healthy {pgmqReachable = throwIO (userError "private credential")})
    verdict <- ready
    verdict `shouldSatisfy` named "pgmq_reachable"

  it "times out native-check slots within 750ms plus at most 250ms scheduling tolerance" $ do
    (_, ready) <- newProbeChecks (healthy {clickhouseReachable = threadDelay 5_000_000 >> pure True})
    started <- getCurrentTime
    ready >>= (`shouldSatisfy` named "clickhouse_query_reachable")
    elapsed <- realToFrac . (`diffUTCTime` started) <$> getCurrentTime :: IO Double
    elapsed `shouldSatisfy` (< 1.0)

  it "propagates asynchronous cancellation" $ do
    (_, ready) <- newProbeChecks (healthy {clickhouseReachable = threadDelay 5_000_000 >> pure True})
    withAsync ready $ \worker -> do
      threadDelay 20_000
      cancel worker
      waitCatch worker >>= (`shouldSatisfy` either (const True) (const False))

  it "serves both failing checks through production assembly outside ingest middleware" $ do
    cfg <- loadConfig >>= either (fail . show) pure
    now <- getCurrentTime
    let failed = pure (Unhealthy "injected" now)
        unused = error "probe touched analytics dependency"
        app = kansokuAppWithChecks failed failed cfg unused unused unused unused
    Warp.testWithApplication (pure app) $ \port -> do
      manager <- Http.newManager Http.defaultManagerSettings
      mapM_ (assertFailure manager port) ["/health/live", "/health/ready"]
    probePaths `shouldBe` ["/health/live", "/health/ready", "/health", "/ready"]

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
      pipelineReady = pure []
    }
