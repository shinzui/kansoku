-- | Bounded, query-free JSON access records under the serving request span.
module Kansoku.RequestLog (requestLogger, stdoutSink) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import Kansoku.Health (probePaths)
import Network.HTTP.Types (hUserAgent, statusCode)
import Network.Wai
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Instrumentation.Wai (requestContext)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as Id
import System.IO (stdout)

stdoutSink :: BS.ByteString -> IO ()
stdoutSink line = BS.hPut stdout (line <> "\n")

requestLogger :: (BS.ByteString -> IO ()) -> Middleware
requestLogger sink app request respond
  | rawPathInfo request `elem` probePaths = app request respond
  | otherwise = do
      started <- getMonotonicTimeNSec
      app request $ \response -> do
        finished <- getMonotonicTimeNSec
        now <- getCurrentTime
        correlation <- case requestContext request >>= Context.lookupSpan of
          Nothing -> pure []
          Just span' -> do
            context <- OTel.getSpanContext span'
            pure $
              if OTel.isValid context
                then
                  [ "trace_id" Aeson..= Id.traceIdBaseEncodedText Id.Base16 (OTel.traceId context),
                    "span_id" Aeson..= Id.spanIdBaseEncodedText Id.Base16 (OTel.spanId context)
                  ]
                else []
        let path = rawPathInfo request
            userAgent = lookup hUserAgent (requestHeaders request)
            fields =
              [ "method" Aeson..= text (requestMethod request),
                "path" Aeson..= text (BS.take 2048 path),
                "path_truncated" Aeson..= (BS.length path > 2048),
                "status" Aeson..= statusCode (responseStatus response),
                "time" Aeson..= now,
                "duration_ms" Aeson..= (fromIntegral (finished - started) / 1_000_000 :: Double)
              ]
                <> maybe
                  []
                  ( \agent ->
                      [ "user_agent" Aeson..= text (BS.take 512 agent),
                        "user_agent_truncated" Aeson..= (BS.length agent > 512)
                      ]
                  )
                  userAgent
                <> correlation
        sink (LBS.toStrict (Aeson.encode (Aeson.object fields)))
        respond response
  where
    text :: BS.ByteString -> Text
    text = decodeUtf8With lenientDecode
