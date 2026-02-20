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
  ObservableCounter (..),
  createObservableCounter,
  ObservableUpDownCounter (..),
  createObservableUpDownCounter,
  PeriodicReaderConfig (..),
  defaultPeriodicReaderConfig,
  AggregationTemporality (..),
  InstrumentKind (..),
) where

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
  readersInEnv <- fmap (T.splitOn "," . T.pack) <$> lookupEnv "OTEL_METRICS_EXPORTER"
  if readersInEnv == Just ["none"]
    then pure []
    else do
      let selected = fromMaybe ["otlp"] readersInEnv
          initializers = map (\name -> maybe (Left name) Right (lookup name knownMetricReaders)) selected
          (_unknown, matched) = partitionEithers initializers
      sequence matched
