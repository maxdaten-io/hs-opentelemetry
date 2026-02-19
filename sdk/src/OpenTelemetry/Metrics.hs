{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module OpenTelemetry.Metrics (
  MeterProvider,
  MetricReader,
  initializeGlobalMeterProvider,
  initializeMeterProvider,
  getMeterProviderInitializationOptions,
  shutdownMeterProvider,
  getGlobalMeterProvider,
  setGlobalMeterProvider,
  createMeterProvider,
  MeterProviderOptions (..),
  emptyMeterProviderOptions,
  Meter,
  meterName,
  getMeter,
  makeMeter,
  MeterOptions (..),
  meterOptions,
  HasMeter (..),
  InstrumentationLibrary (..),
  detectInstrumentationLibrary,
  Counter (..),
  createCounter,
  UpDownCounter (..),
  createUpDownCounter,
  Histogram (..),
  createHistogram,
  Gauge (..),
  createGauge,
  Observation (..),
  observation,
  CallbackRegistration (..),
  ObservableGauge (..),
  createObservableGauge,
  ObservableCounter (..),
  createObservableCounter,
  ObservableUpDownCounter (..),
  createObservableUpDownCounter,
  PeriodicReaderConfig (..),
  defaultPeriodicReaderConfig,
  AggregationTemporality (..),
  InstrumentKind (..),
) where

import Control.Monad (forM_, when)
import Data.Either (partitionEithers)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import OpenTelemetry.Environment (lookupBooleanEnv)
import OpenTelemetry.Environment.Detect (detectAttributeLimits, detectResourceAttributes, readEnvDefault)
import OpenTelemetry.Exporter.OTLP.Config (loadExporterEnvironmentVariables)
import qualified OpenTelemetry.Exporter.OTLP.Metric as OTLPMetric
import OpenTelemetry.Metrics.Core
import OpenTelemetry.Metrics.MetricReader
import OpenTelemetry.Resource
import OpenTelemetry.Resource.Detector (detectBuiltInResources)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)


initializeGlobalMeterProvider :: IO MeterProvider
initializeGlobalMeterProvider = do
  provider <- initializeMeterProvider
  setGlobalMeterProvider provider
  pure provider


initializeMeterProvider :: IO MeterProvider
initializeMeterProvider = do
  (readers, opts) <- getMeterProviderInitializationOptions
  createMeterProvider readers opts


getMeterProviderInitializationOptions :: IO ([MetricReader], MeterProviderOptions)
getMeterProviderInitializationOptions = do
  disabled <- lookupBooleanEnv "OTEL_SDK_DISABLED"
  if disabled
    then pure ([], emptyMeterProviderOptions)
    else do
      attrLimits <- detectAttributeLimits
      builtInRs <- detectBuiltInResources
      envVarRs <- mkResource . map Just <$> detectResourceAttributes
      readers <- detectMetricReaders
      let resources = mergeResources (mempty :: Resource 'Nothing) (envVarRs <> builtInRs)
      pure
        ( readers
        , emptyMeterProviderOptions
            { meterProviderOptionsResources = materializeResources resources
            , meterProviderOptionsAttributeLimits = attrLimits
            }
        )


knownMetricReaders :: [(T.Text, IO MetricReader)]
knownMetricReaders =
  [
    ( "otlp"
    , do
        conf <- loadExporterEnvironmentVariables
        exporter <- OTLPMetric.otlpExporter conf
        interval <- readEnvDefault "OTEL_METRIC_EXPORT_INTERVAL" (periodicReaderInterval defaultPeriodicReaderConfig)
        timeout <- readEnvDefault "OTEL_METRIC_EXPORT_TIMEOUT" (periodicReaderTimeout defaultPeriodicReaderConfig)
        periodicReader (PeriodicReaderConfig interval timeout) exporter
    )
  ]


detectMetricReaders :: IO [MetricReader]
detectMetricReaders = do
  readersInEnv <- lookupEnv "OTEL_METRICS_EXPORTER"
  let normalized = normalizeMetricsExporters readersInEnv
  if normalized == Just ["none"]
    then pure []
    else do
      let selected = fromMaybe ["otlp"] normalized
          initializers = map (\name -> maybe (Left name) Right (lookup name knownMetricReaders)) selected
          (unknown, matched) = partitionEithers initializers
      forM_ unknown $ \unknownName ->
        warnMetrics $
          "unsupported OTEL_METRICS_EXPORTER value '"
            <> T.unpack unknownName
            <> "', ignoring"
      if null matched
        then do
          when (normalized /= Nothing) $
            warnMetrics "no supported OTEL_METRICS_EXPORTER values selected, defaulting to 'otlp'"
          case lookup "otlp" knownMetricReaders of
            Nothing -> pure []
            Just initializeDefault -> sequence [initializeDefault]
        else sequence matched


normalizeMetricsExporters :: Maybe String -> Maybe [T.Text]
normalizeMetricsExporters input = do
  raw <- input
  let stripped = T.strip (T.pack raw)
  if T.null stripped
    then Nothing
    else
      let values = fmap (T.toLower . T.strip) (T.splitOn "," stripped)
          nonEmpty = filter (not . T.null) values
      in if null nonEmpty then Nothing else Just nonEmpty


warnMetrics :: String -> IO ()
warnMetrics = hPutStrLn stderr . ("Warning: " <>)
