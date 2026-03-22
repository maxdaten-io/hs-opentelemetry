{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module OpenTelemetry.Metrics.MetricReader (
  PeriodicReaderConfig (..),
  defaultPeriodicReaderConfig,
  periodicReader,
  manualReader,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Monad (forever, join, unless)
import Data.HashMap.Strict (HashMap, insertWith)
import Data.IORef
import Data.Vector (Vector)
import OpenTelemetry.Exporter.Metric
import OpenTelemetry.Internal.Common.Types (ShutdownResult (..))
import OpenTelemetry.Metrics.Core (InstrumentationLibrary, MetricData, MetricReader (..), ScopeMetrics (..))
import OpenTelemetry.Resource (emptyMaterializedResources)


data PeriodicReaderConfig = PeriodicReaderConfig
  { periodicReaderInterval :: Int
  , periodicReaderTimeout :: Int
  }
  deriving (Show, Eq)


defaultPeriodicReaderConfig :: PeriodicReaderConfig
defaultPeriodicReaderConfig =
  PeriodicReaderConfig
    { periodicReaderInterval = 60000
    , periodicReaderTimeout = 30000
    }


periodicReader :: PeriodicReaderConfig -> MetricExporter -> IO MetricReader
periodicReader PeriodicReaderConfig {..} exporter = do
  collectRef <- newIORef (pure (emptyMaterializedResources, []))
  stopSignal <- newTVarIO False
  worker <- async $ forever $ do
    threadDelay (periodicReaderInterval * 1000)
    stopped <- readTVarIO stopSignal
    unless stopped $ do
      collect <- readIORef collectRef
      (resources, scopeMetrics) <- collect
      _ <- metricExporterExport exporter resources (groupByLibrary scopeMetrics)
      pure ()

  pure $
    MetricReader
      { metricReaderSetCollect = writeIORef collectRef
      , metricReaderCollect = join (readIORef collectRef)
      , metricReaderForceFlush = do
          collect <- readIORef collectRef
          (resources, scopeMetrics) <- collect
          _ <- metricExporterExport exporter resources (groupByLibrary scopeMetrics)
          pure ()
      , metricReaderShutdown = async $ do
          atomically $ writeTVar stopSignal True
          cancel worker
          metricExporterShutdown exporter
          pure ShutdownSuccess
      }


manualReader :: MetricExporter -> IO MetricReader
manualReader exporter = do
  collectRef <- newIORef (pure (emptyMaterializedResources, []))
  pure $
    MetricReader
      { metricReaderSetCollect = writeIORef collectRef
      , metricReaderCollect = join (readIORef collectRef)
      , metricReaderForceFlush = do
          collect <- readIORef collectRef
          (resources, scopeMetrics) <- collect
          _ <- metricExporterExport exporter resources (groupByLibrary scopeMetrics)
          pure ()
      , metricReaderShutdown = async $ do
          metricExporterShutdown exporter
          pure ShutdownSuccess
      }


groupByLibrary :: [ScopeMetrics] -> HashMap InstrumentationLibrary (Vector MetricData)
groupByLibrary =
  foldr
    (\ScopeMetrics {scopeMetricsScope, scopeMetricsMetrics} -> insertWith (<>) scopeMetricsScope scopeMetricsMetrics)
    mempty
