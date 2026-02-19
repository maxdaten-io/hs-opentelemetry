{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module OpenTelemetry.MetricsSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (bracket)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as Vector
import Lens.Micro ((^.))
import OpenTelemetry.Attributes
import OpenTelemetry.Exporter.Metric
import qualified OpenTelemetry.Exporter.OTLP.Config as OTLPConfig
import qualified OpenTelemetry.Exporter.OTLP.Metric as OTLPMetric
import OpenTelemetry.Metrics
import OpenTelemetry.Metrics.Core (
  DataPoint (..),
  HistogramDataPoint (..),
  MeterProvider,
  MetricData (..),
  MetricReader (..),
  forceFlushMeterProvider,
 )
import OpenTelemetry.Metrics.MetricReader (PeriodicReaderConfig (..), manualReader, periodicReader)
import OpenTelemetry.Resource
import qualified Proto.Opentelemetry.Proto.Common.V1.Common_Fields as Common_Fields
import qualified Proto.Opentelemetry.Proto.Metrics.V1.Metrics_Fields as Metrics_Fields
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.Timeout (timeout)
import Test.Hspec


type ExportBatch = (MaterializedResources, Bool)


type MetricExportBatch = HashMap.HashMap InstrumentationLibrary (Vector.Vector MetricData)


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
          , metricExporterForceFlush = pure ()
          , metricExporterShutdown = writeIORef shutdownRef True
          , metricExporterTemporality = const CumulativeTemporality
          }
  pure (batchesRef, shutdownRef, exporter)


mkTemporalityCaptureExporter
  :: (InstrumentKind -> AggregationTemporality)
  -> IO (IORef [MetricExportBatch], MetricExporter)
mkTemporalityCaptureExporter temporalitySelector = do
  batchesRef <- newIORef []
  let exporter =
        MetricExporter
          { metricExporterExport = \_resources byScope -> do
              modifyIORef' batchesRef (byScope :)
              pure Success
          , metricExporterForceFlush = pure ()
          , metricExporterShutdown = pure ()
          , metricExporterTemporality = temporalitySelector
          }
  pure (batchesRef, exporter)


mkFlakyTemporalityCaptureExporter
  :: (InstrumentKind -> AggregationTemporality)
  -> IO (IORef [MetricExportBatch], MetricExporter)
mkFlakyTemporalityCaptureExporter temporalitySelector = do
  batchesRef <- newIORef []
  callsRef <- newIORef (0 :: Int)
  let exporter =
        MetricExporter
          { metricExporterExport = \_resources byScope -> do
              modifyIORef' batchesRef (byScope :)
              callCount <- readIORef callsRef
              writeIORef callsRef (callCount + 1)
              if callCount == 0
                then pure (Failure Nothing)
                else pure Success
          , metricExporterForceFlush = pure ()
          , metricExporterShutdown = pure ()
          , metricExporterTemporality = temporalitySelector
          }
  pure (batchesRef, exporter)


withMeterProvider :: [MetricExporter] -> (MeterProvider -> IO a) -> IO a
withMeterProvider exporters =
  bracket makeProvider shutdownMeterProvider
  where
    makeProvider = do
      readers <- mapM manualReader exporters
      createMeterProvider readers emptyMeterProviderOptions


flattenMetrics :: MetricExportBatch -> [MetricData]
flattenMetrics = concatMap Vector.toList . HashMap.elems


expectSumMetric :: Text -> MetricExportBatch -> IO MetricData
expectSumMetric metricName batch =
  case find isTargetMetric (flattenMetrics batch) of
    Just metricData -> pure metricData
    Nothing -> failSpec ("expected sum metric named " <> show metricName)
  where
    isTargetMetric SumData {sumName} = sumName == metricName
    isTargetMetric _ = False


sumMetricsNamed :: Text -> MetricExportBatch -> [MetricData]
sumMetricsNamed metricName =
  filter isTargetMetric . flattenMetrics
  where
    isTargetMetric SumData {sumName} = sumName == metricName
    isTargetMetric _ = False


expectHistogramMetric :: Text -> MetricExportBatch -> IO MetricData
expectHistogramMetric metricName batch =
  case find isTargetMetric (flattenMetrics batch) of
    Just metricData -> pure metricData
    Nothing -> failSpec ("expected histogram metric named " <> show metricName)
  where
    isTargetMetric HistogramData {histogramName} = histogramName == metricName
    isTargetMetric _ = False


expectGaugeMetric :: Text -> MetricExportBatch -> IO MetricData
expectGaugeMetric metricName batch =
  case find isTargetMetric (flattenMetrics batch) of
    Just metricData -> pure metricData
    Nothing -> failSpec ("expected gauge metric named " <> show metricName)
  where
    isTargetMetric GaugeData {gaugeName} = gaugeName == metricName
    isTargetMetric _ = False


singleSumPointValue :: MetricData -> IO Double
singleSumPointValue SumData {sumDataPoints} =
  case Vector.toList sumDataPoints of
    [DataPoint {dataPointValue}] -> pure dataPointValue
    points -> failSpec ("expected exactly one sum point, got " <> show (length points))
singleSumPointValue metricData = failSpec ("expected sum metric, got " <> show metricData)


singleSumPoint :: MetricData -> IO (DataPoint Double)
singleSumPoint SumData {sumDataPoints} =
  case Vector.toList sumDataPoints of
    [point] -> pure point
    points -> failSpec ("expected exactly one sum point, got " <> show (length points))
singleSumPoint metricData = failSpec ("expected sum metric, got " <> show metricData)


singleHistogramPoint :: MetricData -> IO HistogramDataPoint
singleHistogramPoint HistogramData {histogramDataPoints} =
  case Vector.toList histogramDataPoints of
    [point] -> pure point
    points -> failSpec ("expected exactly one histogram point, got " <> show (length points))
singleHistogramPoint metricData = failSpec ("expected histogram metric, got " <> show metricData)


singleGaugePointValue :: MetricData -> IO Double
singleGaugePointValue GaugeData {gaugeDataPoints} =
  case Vector.toList gaugeDataPoints of
    [DataPoint {dataPointValue}] -> pure dataPointValue
    points -> failSpec ("expected exactly one gauge point, got " <> show (length points))
singleGaugePointValue metricData = failSpec ("expected gauge metric, got " <> show metricData)


secondBatch :: IORef [MetricExportBatch] -> IO MetricExportBatch
secondBatch batchesRef = do
  batches <- reverse <$> readIORef batchesRef
  case batches of
    (_first : second : _) -> pure second
    _ -> failSpec ("expected at least two export batches, got " <> show (length batches))


failSpec :: String -> IO a
failSpec message = expectationFailure message >> fail message


withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key value action = bracket (lookupEnv key) restore $ \_ -> do
  case value of
    Nothing -> unsetEnv key
    Just v -> setEnv key v
  action
  where
    restore Nothing = unsetEnv key
    restore (Just v) = setEnv key v


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

  it "applies meter schema option to instrumentation scope" $ do
    (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)
    withMeterProvider [exporter] $ \provider -> do
      meter <-
        getMeter
          provider
          "spec.metrics.scope"
          (meterOptions {meterSchema = Just "https://opentelemetry.io/schemas/1.0.0"})
      counter <- createCounter meter "requests" "request count" "1"
      counterAdd counter 1 mempty
      forceFlushMeterProvider provider

    batches <- reverse <$> readIORef batchesRef
    case batches of
      (firstBatch : _) ->
        case find (\scope -> libraryName scope == "spec.metrics.scope") (HashMap.keys firstBatch) of
          Just scope -> librarySchemaUrl scope `shouldBe` "https://opentelemetry.io/schemas/1.0.0"
          Nothing -> expectationFailure "expected exported metrics for scope spec.metrics.scope"
      [] -> expectationFailure "expected at least one metric export batch"

  it "shutdown propagates to exporter" $ do
    (_batchesRef, shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    provider <- createMeterProvider [reader] emptyMeterProviderOptions

    shutdownMeterProvider provider
    readIORef shutdownRef `shouldReturn` True

  it "manual reader collect fails after shutdown" $ do
    (_batchesRef, _shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    _ <- metricReaderShutdown reader
    threadDelay 10000

    metricReaderCollect reader `shouldThrow` anyException

  it "force flush delegates to exporter force flush" $ do
    flushCountRef <- newIORef (0 :: Int)
    let exporter =
          MetricExporter
            { metricExporterExport = \_resources _byScope -> pure Success
            , metricExporterForceFlush = modifyIORef' flushCountRef (+ 1)
            , metricExporterShutdown = pure ()
            , metricExporterTemporality = const CumulativeTemporality
            }
    reader <- manualReader exporter
    provider <- createMeterProvider [reader] emptyMeterProviderOptions
    meter <- getMeter provider "spec.metrics" meterOptions
    counter <- createCounter meter "requests" "request count" "1"
    counterAdd counter 1 mempty
    forceFlushMeterProvider provider

    readIORef flushCountRef `shouldReturn` 1

  it "meters created after provider shutdown are no-op" $ do
    (batchesRef, _shutdownRef, exporter) <- mkCaptureExporter
    reader <- manualReader exporter
    provider <- createMeterProvider [reader] emptyMeterProviderOptions

    meter <- getMeter provider "spec.metrics" meterOptions
    counter <- createCounter meter "requests" "request count" "1"
    counterAdd counter 1 mempty
    forceFlushMeterProvider provider
    batchesBeforeShutdown <- length <$> readIORef batchesRef

    shutdownMeterProvider provider

    meterAfterShutdown <- getMeter provider "spec.metrics.after.shutdown" meterOptions
    counterAfterShutdown <- createCounter meterAfterShutdown "requests_after_shutdown" "request count" "1"
    counterAdd counterAfterShutdown 10 mempty
    forceFlushMeterProvider provider
    batchesAfterShutdown <- length <$> readIORef batchesRef

    batchesAfterShutdown `shouldBe` batchesBeforeShutdown

  describe "duplicate instrument registration" $ do
    it "merges identical duplicate counters into one exported metric" $ do
      (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.duplicates" meterOptions
        counter1 <- createCounter meter "requests_total" "requests" "1"
        counter2 <- createCounter meter "requests_total" "requests" "1"

        counterAdd counter1 3 mempty
        counterAdd counter2 5 mempty
        forceFlushMeterProvider provider
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      let duplicates = sumMetricsNamed "requests_total" exported
      length duplicates `shouldBe` 1
      case duplicates of
        [metricData] -> singleSumPointValue metricData `shouldReturn` 8
        _ -> failSpec "expected one merged counter metric"

    it "keeps first-seen metric name for case-insensitive duplicates" $ do
      (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.duplicates" meterOptions
        counter1 <- createCounter meter "requestCount" "requests" "1"
        counter2 <- createCounter meter "RequestCount" "requests" "1"

        counterAdd counter1 2 mempty
        counterAdd counter2 3 mempty
        forceFlushMeterProvider provider
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      let matchingNames =
            [ sumName
            | SumData {sumName} <- flattenMetrics exported
            , T.toCaseFold sumName == "requestcount"
            ]
      matchingNames `shouldBe` ["requestCount"]
      case sumMetricsNamed "requestCount" exported of
        [metricData] -> singleSumPointValue metricData `shouldReturn` 5
        _ -> failSpec "expected one merged metric with first-seen case"

  describe "gauge instruments" $ do
    it "records synchronous gauge values via gaugeRecord" $ do
      (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.gauge" meterOptions
        gauge <- createGauge meter "temperature" "temperature" "c"
        gaugeRecord gauge 21.2 mempty
        gaugeRecord gauge 22.8 mempty
        forceFlushMeterProvider provider
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      gaugeMetric <- expectGaugeMetric "temperature" exported
      singleGaugePointValue gaugeMetric `shouldReturn` 22.8

    it "exports asynchronous observable gauge callback value" $ do
      gaugeValueRef <- newIORef 3.5
      (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.gauge" meterOptions
        _ <-
          createObservableGauge
            meter
            "cpu_frequency"
            "cpu frequency"
            "GHz"
            [ do
                value <- readIORef gaugeValueRef
                pure [observation value mempty]
            ]

        forceFlushMeterProvider provider
        writeIORef gaugeValueRef 4.2
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      gaugeMetric <- expectGaugeMetric "cpu_frequency" exported
      singleGaugePointValue gaugeMetric `shouldReturn` 4.2

    it "supports multiple observations and callback unregister on observable gauge" $ do
      (batchesRef, exporter) <- mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.gauge" meterOptions
        observableGauge <- createObservableGauge meter "cpu_frequency" "cpu frequency" "GHz" []
        registration <-
          observableGaugeRegisterCallback observableGauge $
            pure
              [ observation 3.2 (HashMap.singleton "cpu" (toAttribute ("0" :: Text)))
              , observation 3.8 (HashMap.singleton "cpu" (toAttribute ("1" :: Text)))
              ]

        forceFlushMeterProvider provider
        unregisterCallback registration
        forceFlushMeterProvider provider

      batches <- reverse <$> readIORef batchesRef
      case batches of
        (firstBatch : secondBatch_ : _) -> do
          firstMetric <- expectGaugeMetric "cpu_frequency" firstBatch
          secondMetric <- expectGaugeMetric "cpu_frequency" secondBatch_
          let firstPoints = case firstMetric of
                GaugeData {gaugeDataPoints} -> Vector.length gaugeDataPoints
                _ -> 0
              secondPoints = case secondMetric of
                GaugeData {gaugeDataPoints} -> Vector.length gaugeDataPoints
                _ -> 0
          firstPoints `shouldBe` 2
          secondPoints `shouldBe` 0
        _ -> failSpec ("expected at least two export batches, got " <> show (length batches))

  describe "temporality per instrument kind" $ do
    it "supports Counter delta while ObservableCounter remains cumulative" $ do
      observableValueRef <- newIORef 3
      (batchesRef, exporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          CounterKind -> DeltaTemporality
          ObservableCounterKind -> CumulativeTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"
        _ <-
          createObservableCounter
            meter
            "workers_total"
            "workers"
            "1"
            [ do
                value <- readIORef observableValueRef
                pure [observation value mempty]
            ]

        counterAdd counter 5 mempty
        forceFlushMeterProvider provider

        writeIORef observableValueRef 9
        counterAdd counter 7 mempty
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      counterMetric <- expectSumMetric "requests_total" exported
      observableMetric <- expectSumMetric "workers_total" exported

      sumTemporality counterMetric `shouldBe` DeltaTemporality
      sumTemporality observableMetric `shouldBe` CumulativeTemporality
      singleSumPointValue counterMetric `shouldReturn` 7
      singleSumPointValue observableMetric `shouldReturn` 9

    it "supports ObservableCounter delta while Counter remains cumulative" $ do
      observableValueRef <- newIORef 2
      (batchesRef, exporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          CounterKind -> CumulativeTemporality
          ObservableCounterKind -> DeltaTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"
        _ <-
          createObservableCounter
            meter
            "workers_total"
            "workers"
            "1"
            [ do
                value <- readIORef observableValueRef
                pure [observation value mempty]
            ]

        counterAdd counter 5 mempty
        forceFlushMeterProvider provider

        writeIORef observableValueRef 5
        counterAdd counter 7 mempty
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      counterMetric <- expectSumMetric "requests_total" exported
      observableMetric <- expectSumMetric "workers_total" exported

      sumTemporality counterMetric `shouldBe` CumulativeTemporality
      sumTemporality observableMetric `shouldBe` DeltaTemporality
      singleSumPointValue counterMetric `shouldReturn` 12
      singleSumPointValue observableMetric `shouldReturn` 3

    it "supports UpDownCounter delta while ObservableUpDownCounter remains cumulative" $ do
      observableValueRef <- newIORef 10
      (batchesRef, exporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          UpDownCounterKind -> DeltaTemporality
          ObservableUpDownCounterKind -> CumulativeTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        upDownCounter <- createUpDownCounter meter "queue_depth" "depth" "1"
        _ <-
          createObservableUpDownCounter
            meter
            "pressure_level"
            "pressure"
            "1"
            [ do
                value <- readIORef observableValueRef
                pure [observation value mempty]
            ]

        upDownCounterAdd upDownCounter 4 mempty
        forceFlushMeterProvider provider

        writeIORef observableValueRef 6
        upDownCounterAdd upDownCounter (-1) mempty
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      upDownMetric <- expectSumMetric "queue_depth" exported
      observableMetric <- expectSumMetric "pressure_level" exported

      sumTemporality upDownMetric `shouldBe` DeltaTemporality
      sumTemporality observableMetric `shouldBe` CumulativeTemporality
      singleSumPointValue upDownMetric `shouldReturn` (-1)
      singleSumPointValue observableMetric `shouldReturn` 6

    it "converts cumulative histogram data to delta with min/max dropped" $ do
      (batchesRef, exporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          HistogramKind -> DeltaTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        histogram <- createHistogram meter "request_latency_ms" "latency" "ms"

        histogramRecord histogram 3 mempty
        histogramRecord histogram 7 mempty
        forceFlushMeterProvider provider

        histogramRecord histogram 5 mempty
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      histogramMetric <- expectHistogramMetric "request_latency_ms" exported
      point <- singleHistogramPoint histogramMetric

      histogramTemporality histogramMetric `shouldBe` DeltaTemporality
      histogramDataPointCount point `shouldBe` 1
      histogramDataPointSum point `shouldBe` 5
      histogramDataPointMin point `shouldBe` Nothing
      histogramDataPointMax point `shouldBe` Nothing
      sum (Vector.toList (histogramDataPointBucketCounts point)) `shouldBe` 1

    it "advances delta baseline on collection even when export fails" $ do
      (batchesRef, exporter) <-
        mkFlakyTemporalityCaptureExporter $ \kind -> case kind of
          CounterKind -> DeltaTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"

        counterAdd counter 5 mempty
        forceFlushMeterProvider provider

        counterAdd counter 7 mempty
        forceFlushMeterProvider provider

      exported <- secondBatch batchesRef
      counterMetric <- expectSumMetric "requests_total" exported
      sumTemporality counterMetric `shouldBe` DeltaTemporality
      singleSumPointValue counterMetric `shouldReturn` 7

    it "keeps temporality state independent across multiple readers" $ do
      (deltaBatchesRef, deltaExporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          CounterKind -> DeltaTemporality
          _ -> CumulativeTemporality
      (cumulativeBatchesRef, cumulativeExporter) <-
        mkTemporalityCaptureExporter (const CumulativeTemporality)

      withMeterProvider [deltaExporter, cumulativeExporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"

        counterAdd counter 5 mempty
        forceFlushMeterProvider provider

        counterAdd counter 7 mempty
        forceFlushMeterProvider provider

      deltaExported <- secondBatch deltaBatchesRef
      cumulativeExported <- secondBatch cumulativeBatchesRef
      deltaMetric <- expectSumMetric "requests_total" deltaExported
      cumulativeMetric <- expectSumMetric "requests_total" cumulativeExported

      sumTemporality deltaMetric `shouldBe` DeltaTemporality
      sumTemporality cumulativeMetric `shouldBe` CumulativeTemporality
      singleSumPointValue deltaMetric `shouldReturn` 7
      singleSumPointValue cumulativeMetric `shouldReturn` 12

    it "sets delta sum start timestamp to previous collection end" $ do
      (batchesRef, exporter) <-
        mkTemporalityCaptureExporter $ \kind -> case kind of
          CounterKind -> DeltaTemporality
          _ -> CumulativeTemporality

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"

        counterAdd counter 5 mempty
        forceFlushMeterProvider provider

        counterAdd counter 7 mempty
        forceFlushMeterProvider provider

      batches <- reverse <$> readIORef batchesRef
      case batches of
        (firstBatch : secondBatch_ : _) -> do
          firstMetric <- expectSumMetric "requests_total" firstBatch
          secondMetric <- expectSumMetric "requests_total" secondBatch_
          firstPoint <- singleSumPoint firstMetric
          secondPoint <- singleSumPoint secondMetric
          dataPointStartTimestamp secondPoint `shouldBe` Just (dataPointTimestamp firstPoint)
        _ -> failSpec ("expected at least two export batches, got " <> show (length batches))

    it "serializes concurrent force flush exports for a single reader" $ do
      activeExports <- newIORef (0 :: Int)
      maxConcurrent <- newIORef (0 :: Int)
      let exporter =
            MetricExporter
              { metricExporterExport = \_resources _byScope -> do
                  activeNow <- atomicModifyIORef' activeExports (\n -> let next = n + 1 in (next, next))
                  atomicModifyIORef' maxConcurrent (\m -> (max m activeNow, ()))
                  threadDelay 100000
                  atomicModifyIORef' activeExports (\n -> (n - 1, ()))
                  pure Success
              , metricExporterForceFlush = pure ()
              , metricExporterShutdown = pure ()
              , metricExporterTemporality = const CumulativeTemporality
              }

      withMeterProvider [exporter] $ \provider -> do
        meter <- getMeter provider "spec.metrics.temporality" meterOptions
        counter <- createCounter meter "requests_total" "requests" "1"
        counterAdd counter 1 mempty

        done1 <- newEmptyMVar
        done2 <- newEmptyMVar

        _ <- forkIO $ forceFlushMeterProvider provider >> putMVar done1 ()
        _ <- forkIO $ forceFlushMeterProvider provider >> putMVar done2 ()

        takeMVar done1
        takeMVar done2

      readIORef maxConcurrent `shouldReturn` 1

    it "honors OTLP metrics temporality preference from environment" $ do
      withEnvVar "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE" (Just "lowmemory") $ do
        conf <- OTLPConfig.loadExporterEnvironmentVariables
        exporter <- OTLPMetric.otlpExporter conf
        metricExporterTemporality exporter CounterKind `shouldBe` DeltaTemporality
        metricExporterTemporality exporter HistogramKind `shouldBe` DeltaTemporality
        metricExporterTemporality exporter ObservableCounterKind `shouldBe` CumulativeTemporality
        metricExporterTemporality exporter UpDownCounterKind `shouldBe` CumulativeTemporality

    it "includes instrumentation scope attributes in OTLP scope metrics" $ do
      let scopeAttrs = addAttribute defaultAttributeLimits emptyAttributes "scope.attribute" ("present" :: Text)
          scope =
            InstrumentationLibrary
              { libraryName = "spec.metrics.temporality"
              , libraryVersion = "1.0.0"
              , librarySchemaUrl = "https://opentelemetry.io/schemas/1.0.0"
              , libraryAttributes = scopeAttrs
              }
          scopeMetrics = OTLPMetric.makeScopeMetrics scope Vector.empty
          exportedScope = scopeMetrics ^. Metrics_Fields.scope
      exportedScope ^. Common_Fields.vec'attributes `shouldBe` OTLPMetric.attributesToProto scopeAttrs
      exportedScope ^. Common_Fields.droppedAttributesCount `shouldBe` fromIntegral (getDropped scopeAttrs)

    it "applies periodic reader timeout to force flush exports" $ do
      let exporter =
            MetricExporter
              { metricExporterExport = \_resources _byScope -> do
                  threadDelay 200000
                  pure Success
              , metricExporterForceFlush = pure ()
              , metricExporterShutdown = pure ()
              , metricExporterTemporality = const CumulativeTemporality
              }
      reader <- periodicReader (PeriodicReaderConfig 60000 20) exporter
      provider <- createMeterProvider [reader] emptyMeterProviderOptions
      meter <- getMeter provider "spec.metrics.temporality" meterOptions
      counter <- createCounter meter "requests_total" "requests" "1"
      counterAdd counter 1 mempty

      result <- timeout 100000 (forceFlushMeterProvider provider)
      shutdownMeterProvider provider
      result `shouldSatisfy` maybe False (const True)

    it "loads OTLP histogram aggregation preference from environment" $ do
      withEnvVar "OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION" (Just "explicit_bucket_histogram") $ do
        conf <- OTLPConfig.loadExporterEnvironmentVariables
        OTLPConfig.otlpMetricsDefaultHistogramAggregation conf
          `shouldBe` Just OTLPConfig.MetricsExplicitBucketHistogramAggregation

    it "treats OTEL_METRICS_EXPORTER as case-insensitive enum" $ do
      withEnvVar "OTEL_SDK_DISABLED" Nothing $
        withEnvVar "OTEL_METRICS_EXPORTER" (Just "OtLp") $ do
          (readers, _) <- getMeterProviderInitializationOptions
          length readers `shouldBe` 1

    it "treats empty OTEL_METRICS_EXPORTER as unset" $ do
      withEnvVar "OTEL_SDK_DISABLED" Nothing $
        withEnvVar "OTEL_METRICS_EXPORTER" (Just "") $ do
          (readers, _) <- getMeterProviderInitializationOptions
          length readers `shouldBe` 1

    it "ignores unknown OTEL_METRICS_EXPORTER values and falls back to default" $ do
      withEnvVar "OTEL_SDK_DISABLED" Nothing $
        withEnvVar "OTEL_METRICS_EXPORTER" (Just "does-not-exist") $ do
          (readers, _) <- getMeterProviderInitializationOptions
          length readers `shouldBe` 1
