module Kansoku.RequestLogSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.IORef
import Kansoku.Health (probePaths)
import Kansoku.RequestLog (requestLogger)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Internal (ResponseReceived (..))
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.RequestLog" $ do
  it "writes one bounded JSON record without credentials, query values or body" $ do
    output <- newIORef []
    let request =
          defaultRequest
            { rawPathInfo = BS.replicate 2050 120,
              rawQueryString = "?secret=hidden-query",
              queryString = [("secret", Just "hidden-query")],
              requestHeaders = [(hAuthorization, "hidden-token"), (hUserAgent, BS.replicate 514 117)]
            }
        sink line = modifyIORef' output (line :)
        app _ respond = respond (responseLBS status503 [] "hidden-response")
    _ <- requestLogger sink app request (const (pure ResponseReceived))
    records <- readIORef output
    length records `shouldBe` 1
    bytes <- case records of
      [record] -> pure record
      _ -> expectationFailure "expected one record" >> fail "missing record"
    mapM_ (\secret -> bytes `shouldSatisfy` (not . BS.isInfixOf secret)) ["hidden-query", "hidden-token", "hidden-response"]
    case Aeson.decodeStrict bytes of
      Just (Aeson.Object fields) -> do
        KeyMap.lookup "status" fields `shouldBe` Just (Aeson.Number 503)
        KeyMap.lookup "path_truncated" fields `shouldBe` Just (Aeson.Bool True)
        KeyMap.lookup "user_agent_truncated" fields `shouldBe` Just (Aeson.Bool True)
        KeyMap.lookup "trace_id" fields `shouldBe` Nothing
      _ -> expectationFailure "access record is not JSON"

  it "excludes only the four exact probe paths" $ do
    output <- newIORef []
    let sink line = modifyIORef' output (line :)
        app _ respond = respond (responseLBS status200 [] "")
        send path = requestLogger sink app (defaultRequest {rawPathInfo = path}) (const (pure ResponseReceived))
    mapM_ send probePaths
    readIORef output `shouldReturn` []
    _ <- send "/health/live/extra"
    length <$> readIORef output `shouldReturn` 1
