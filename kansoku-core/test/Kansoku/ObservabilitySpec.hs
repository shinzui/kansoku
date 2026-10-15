module Kansoku.ObservabilitySpec (spec) where

import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Kansoku.Observability
  ( PipelineMetrics,
    beatWriter,
    lastWriterBeat,
    newWriterHeartbeat,
  )
import Kansoku.Prelude
import Prometheus qualified
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec _metrics = describe "Kansoku.Observability" $ do
  it "registers and exports pipeline metric families" $ do
    scrape <- Prometheus.exportMetricsAsText
    traverse_
      (\metricName -> LBS.toStrict scrape `shouldSatisfy` BS8.isInfixOf metricName)
      [ "kansoku_queue_length",
        "kansoku_queue_oldest_message_age_seconds",
        "kansoku_writer_batches_total",
        "kansoku_writer_events_written_total",
        "kansoku_writer_batch_flush_seconds",
        "kansoku_writer_insert_failures_total",
        "kansoku_writer_dead_letters_total",
        "kansoku_writer_breaker_state",
        "kansoku_writer_recovery_failures_total",
        "kansoku_queue_archive_length"
      ]

  it "records the writer's latest successful flush" $ do
    heartbeat <- newWriterHeartbeat
    lastWriterBeat heartbeat `shouldReturn` Nothing
    beatWriter heartbeat
    latest <- lastWriterBeat heartbeat
    latest `shouldSatisfy` isJust
