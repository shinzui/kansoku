module Kansoku.QueryPoolSpec (spec, Fault (..), Proxy (..), withProxy, through, drained) where

import ClickHaskell (closeConnection, ping)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race_, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forever, replicateM_, when)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.IORef
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Kansoku.ClickHouse
import Kansoku.Config (loadConfig)
import Kansoku.Exception (trySynchronous)
import Kansoku.Prelude ((&), (.~))
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Test.Hspec

-- This fixture forwards the actual native protocol; no driver operation is mocked.
data Fault = Pass | Stall | Drop deriving (Eq)

data Proxy = Proxy
  { proxyPort :: String,
    fault :: IORef Fault,
    active :: IORef Int,
    accepted :: IORef Int,
    expectedEvents :: Integer
  }

spec :: Spec
spec = describe "Kansoku.QueryPool native lifetime" $ do
  it "bounds failed connect and stalled handshake including socket disposal" $ withNative $ \cfg -> do
    -- Bind without listen: a real refused connect on an owned, unused endpoint.
    bracket newListener close $ \reserved -> do
      port <- socketPort reserved
      bracket (newQueryPool (cfg & #clickHouseTcpPort .~ show port) 1) closeQueryPool $ \pool ->
        boundedFailure (queryReachable pool)
    withProxy cfg $ \proxy ->
      bracket (newQueryPool (through proxy cfg) 1) closeQueryPool $ \pool -> do
        writeIORef (fault proxy) Stall
        replicateM_ 4 $ boundedFailure (queryReachable pool) >> drained proxy
        recover proxy pool

  it "bounds stalled query and failed reconnect, then reuses the same size-one pool" $ withNative $ \cfg ->
    withProxy cfg $ \proxy ->
      bracket (newQueryPool (through proxy cfg) 1) closeQueryPool $ \pool -> do
        queryReachable pool `shouldReturn` True
        replicateM_ 4 $ do
          writeIORef (fault proxy) Stall
          boundedFailure (withQueryConnection pool countEvents)
          drained proxy
          recover proxy pool
        acceptedBefore <- readIORef (accepted proxy)
        writeIORef (fault proxy) Drop
        boundedFailure (queryReachable pool)
        drained proxy
        -- An unwinding operation must not reconnect, even when that reconnect fails.
        readIORef (accepted proxy) `shouldReturn` acceptedBefore
        recover proxy pool

  it "propagates cancellation after cleanup and does not accumulate native workers" $ withNative $ \cfg ->
    withProxy cfg $ \proxy ->
      bracket (newQueryPool (through proxy cfg) 1) closeQueryPool $ \pool -> do
        replicateM_ 6 $ do
          queryReachable pool `shouldReturn` True
          writeIORef (fault proxy) Stall
          started <- newEmptyMVar
          withAsync (putMVar started () >> withQueryConnection pool ping) $ \worker -> do
            takeMVar started
            threadDelay 20_000
            began <- getCurrentTime
            cancel worker
            outcome <- waitCatch worker
            outcome `shouldSatisfy` either (const True) (const False)
            elapsed <- realToFrac . (`diffUTCTime` began) <$> getCurrentTime :: IO Double
            elapsed `shouldSatisfy` (< 0.25)
          drained proxy
          recover proxy pool

  it "includes pool acquisition in the external operation deadline" $ withNative $ \cfg ->
    bracket (newQueryPool cfg 1) closeQueryPool $ \pool -> do
      held <- newEmptyMVar
      release <- newEmptyMVar
      withAsync (withQueryConnection pool (\_ -> putMVar held () >> takeMVar release)) $ \_ -> do
        takeMVar held
        boundedFailure (queryReachable pool)
        putMVar release ()
      queryReachable pool `shouldReturn` True

boundedFailure :: IO a -> Expectation
boundedFailure action = do
  began <- getCurrentTime
  result <- timeout 750_000 (trySynchronous action)
  elapsed <- realToFrac . (`diffUTCTime` began) <$> getCurrentTime :: IO Double
  elapsed `shouldSatisfy` (< 1.0)
  case result of
    Nothing -> pure ()
    Just (Left _) -> pure ()
    Just (Right _) -> expectationFailure "native fault unexpectedly succeeded"

recover :: Proxy -> QueryPool -> Expectation
recover proxy pool = do
  writeIORef (fault proxy) Pass
  queryReachable pool `shouldReturn` True
  -- Real analytics SELECT, independently of ping and without requiring an events schema.
  (fromIntegral <$> withQueryConnection pool countEvents) `shouldReturn` expectedEvents proxy
  count <- readIORef (active proxy)
  count `shouldSatisfy` (<= 1)

drained :: Proxy -> Expectation
drained proxy = do
  let loop = do
        n <- readIORef (active proxy)
        when (n /= 0) (threadDelay 1_000 >> loop)
  done <- timeout 200_000 loop
  done `shouldBe` Just ()

through :: Proxy -> ClickHouseConfig -> ClickHouseConfig
through proxy cfg = cfg & #clickHouseHost .~ "127.0.0.1" & #clickHouseTcpPort .~ proxyPort proxy

withNative :: (ClickHouseConfig -> Expectation) -> Expectation
withNative action = do
  cfg <- loadConfig >>= either (fail . show) (pure . clickHouseConfigFromConfig)
  result <- timeout 1_000_000 (try @SomeException (bracket (openClickHouse cfg) closeConnection ping))
  case result of
    Just (Right ()) -> action cfg
    _ -> do
      required <- lookupEnv "KANSOKU_REQUIRED_INTEGRATION"
      if required == Just "1"
        then expectationFailure "required native ClickHouse endpoint unavailable"
        else pendingWith "run nix develop -c python3 scripts/native-query-pool.py"

newListener :: IO Socket
newListener = do
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  pure sock

withProxy :: ClickHouseConfig -> (Proxy -> IO a) -> IO a
withProxy cfg action = bracket newListener close $ \listener -> do
  listen listener 16
  port <- socketPort listener
  mode <- newIORef Pass
  live <- newIORef 0
  total <- newIORef 0
  baseline <- fromIntegral <$> bracket (openClickHouse cfg) closeConnection countEvents
  workers <- newIORef []
  let proxy = Proxy (show port) mode live total baseline
      bump ref n = atomicModifyIORef' ref (\x -> (x + n, ()))
      serve client =
        bracket (connectUpstream cfg) close $ \upstream ->
          race_ (forwardClient mode client upstream) (copy upstream client)
      acceptLoop = forever $ do
        (client, _) <- accept listener
        bump live 1
        bump total 1
        worker <- async ((serve client `finally` close client) `finally` bump live (-1))
        atomicModifyIORef' workers (\xs -> (worker : xs, ()))
      cleanup = readIORef workers >>= mapM_ cancel
  withAsync acceptLoop (\_ -> action proxy) `finally` cleanup

connectUpstream :: ClickHouseConfig -> IO Socket
connectUpstream cfg = do
  addresses <- getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just (clickHouseHost cfg)) (Just (clickHouseTcpPort cfg))
  case addresses of
    [] -> fail "no native address"
    addr : _ -> do
      sock <- socket (addrFamily addr) Stream defaultProtocol
      connect sock (addrAddress addr)
      pure sock

forwardClient :: IORef Fault -> Socket -> Socket -> IO ()
forwardClient mode source destination = do
  bytes <- recv source 65536
  when (not (BS.null bytes)) $ do
    readIORef mode >>= \case
      Pass -> sendAll destination bytes >> forwardClient mode source destination
      Stall -> forwardClient mode source destination
      Drop -> pure ()

copy :: Socket -> Socket -> IO ()
copy source destination = do
  bytes <- recv source 65536
  when (not (BS.null bytes)) (sendAll destination bytes >> copy source destination)
