{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module OpenTelemetry.MetricsSpec (spec) where

import Data.IORef
import Data.Text (Text)
import OpenTelemetry.Attributes
import OpenTelemetry.Exporter.Metric
import OpenTelemetry.Metrics
import OpenTelemetry.Metrics.Core (forceFlushMeterProvider)
import OpenTelemetry.Metrics.MetricReader (manualReader)
import OpenTelemetry.Resource
import Test.Hspec


type ExportBatch = (MaterializedResources, Bool)


mkCaptureExporter :: IO (IORef [ExportBatch], IORef Bool, MetricExporter)
mkCaptureExporter = do
  batchesRef <- newIORef []
  shutdownRef <- newIORef False
  let exporter =
        MetricExporter
          { metricExporterExport = \resources byScope -> do
              let hasMetrics = any (not . null) byScope
              modifyIORef' batchesRef ((resources, hasMetrics) :)
              pure Success
          , metricExporterShutdown = writeIORef shutdownRef True
          , metricExporterTemporality = const CumulativeTemporality
          }
  pure (batchesRef, shutdownRef, exporter)


spec :: Spec
spec = describe "Metrics" $ do
  it "manual reader exports metrics on force flush" $ do
    (batchesRef, _shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    provider <- createMeterProvider [reader] emptyMeterProviderOptions
    meter <- getMeter provider "spec.metrics" meterOptions
    counter <- createCounter meter "requests" "request count" "1"
    counterAdd counter 1 mempty
    forceFlushMeterProvider provider

    batches <- readIORef batchesRef
    any snd batches `shouldBe` True

  it "propagates provider resource to metric exporter" $ do
    (batchesRef, _shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    let resource =
          materializeResources $
            mkResource @'Nothing
              [ "service.name" .= ("metrics-spec" :: Text)
              ]
        opts =
          emptyMeterProviderOptions
            { meterProviderOptionsResources = resource
            }
    provider <- createMeterProvider [reader] opts
    meter <- getMeter provider "spec.metrics" meterOptions
    counter <- createCounter meter "requests" "request count" "1"
    counterAdd counter 1 mempty
    forceFlushMeterProvider provider

    batches <- readIORef batchesRef
    case batches of
      [] -> expectationFailure "expected at least one export batch"
      ((resources, _) : _) ->
        lookupAttribute (getMaterializedResourcesAttributes resources) "service.name"
          `shouldBe` Just (toAttribute ("metrics-spec" :: Text))

  it "shutdown propagates to exporter" $ do
    (_batchesRef, shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    provider <- createMeterProvider [reader] emptyMeterProviderOptions

    shutdownMeterProvider provider
    readIORef shutdownRef `shouldReturn` True
