{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module OpenTelemetry.Metrics.MetricReader (
  PeriodicReaderConfig (..),
  defaultPeriodicReaderConfig,
  periodicReader,
  manualReader,
) where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Exception (throwIO)
import Control.Monad (foldM, forever, join, unless, when)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import qualified Data.List as List
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import OpenTelemetry.Attributes (Attributes)
import OpenTelemetry.Exporter.Metric (MetricExporter (..))
import OpenTelemetry.Internal.Common.Types (ShutdownResult (..))
import OpenTelemetry.Metrics.Core (
  AggregationTemporality (..),
  DataPoint (..),
  HistogramDataPoint (..),
  InstrumentKind,
  InstrumentationLibrary,
  MetricData (..),
  MetricReader (..),
  ScopeMetrics (..),
  Timestamp,
 )
import OpenTelemetry.Resource (MaterializedResources, emptyMaterializedResources)


type SumSeriesKey = (InstrumentationLibrary, InstrumentKind, Text, Text, Text, Bool, Attributes)


type HistogramSeriesKey = (InstrumentationLibrary, InstrumentKind, Text, Text, Text, [Double], Attributes)


type GaugeSeriesKey = (InstrumentationLibrary, InstrumentKind, Text, Text, Text, Attributes)


data SumSeriesState = SumSeriesState
  { sumSeriesLastCumulative :: !(Maybe Double)
  , sumSeriesAccumulatedCumulative :: !(Maybe Double)
  , sumSeriesLastTimestamp :: !(Maybe Timestamp)
  , sumSeriesCumulativeStartTimestamp :: !(Maybe Timestamp)
  }


data HistogramSnapshot = HistogramSnapshot
  { histogramSnapshotCount :: !Int
  , histogramSnapshotSum :: !Double
  , histogramSnapshotMin :: !(Maybe Double)
  , histogramSnapshotMax :: !(Maybe Double)
  , histogramSnapshotBucketCounts :: !(Vector Int)
  }


data HistogramSeriesState = HistogramSeriesState
  { histogramSeriesLastCumulative :: !(Maybe HistogramSnapshot)
  , histogramSeriesAccumulatedCumulative :: !(Maybe HistogramSnapshot)
  , histogramSeriesLastTimestamp :: !(Maybe Timestamp)
  , histogramSeriesCumulativeStartTimestamp :: !(Maybe Timestamp)
  }


data GaugeSeriesState = GaugeSeriesState
  { gaugeSeriesLastTimestamp :: !(Maybe Timestamp)
  , gaugeSeriesCumulativeStartTimestamp :: !(Maybe Timestamp)
  }


data TemporalityState = TemporalityState
  { temporalityStateSums :: !(HashMap SumSeriesKey SumSeriesState)
  , temporalityStateHistograms :: !(HashMap HistogramSeriesKey HistogramSeriesState)
  , temporalityStateGauges :: !(HashMap GaugeSeriesKey GaugeSeriesState)
  }


emptyTemporalityState :: TemporalityState
emptyTemporalityState =
  TemporalityState
    { temporalityStateSums = mempty
    , temporalityStateHistograms = mempty
    , temporalityStateGauges = mempty
    }


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
  registrationRef <- newIORef False
  shutdownRef <- newIORef False
  stateRef <- newIORef emptyTemporalityState
  exportLock <- newMVar ()
  stopSignal <- newTVarIO False
  worker <- async $ forever $ do
    threadDelay (periodicReaderInterval * 1000)
    stopped <- readTVarIO stopSignal
    unless stopped $ do
      collect <- readIORef collectRef
      runSynchronizedExportWithTimeout (Just periodicReaderTimeout) False exportLock stateRef exporter collect

  pure $
    MetricReader
      { metricReaderSetCollect = \collect -> do
          alreadyRegistered <- atomicModifyIORef' registrationRef (\registered -> (True, registered))
          when alreadyRegistered $
            throwIO (userError "metric reader is already registered to a MeterProvider")
          writeIORef collectRef collect
      , metricReaderCollect = do
          shutdown <- readIORef shutdownRef
          if shutdown
            then throwIO (userError "metric reader is shut down")
            else join (readIORef collectRef)
      , metricReaderForceFlush = do
          shutdown <- readIORef shutdownRef
          unless shutdown $ do
            collect <- readIORef collectRef
            runSynchronizedExportWithTimeout (Just periodicReaderTimeout) True exportLock stateRef exporter collect
      , metricReaderShutdown = async $ do
          writeIORef shutdownRef True
          atomically $ writeTVar stopSignal True
          cancel worker
          metricExporterShutdown exporter
          pure ShutdownSuccess
      }


manualReader :: MetricExporter -> IO MetricReader
manualReader exporter = do
  collectRef <- newIORef (pure (emptyMaterializedResources, []))
  registrationRef <- newIORef False
  shutdownRef <- newIORef False
  stateRef <- newIORef emptyTemporalityState
  exportLock <- newMVar ()
  pure $
    MetricReader
      { metricReaderSetCollect = \collect -> do
          alreadyRegistered <- atomicModifyIORef' registrationRef (\registered -> (True, registered))
          when alreadyRegistered $
            throwIO (userError "metric reader is already registered to a MeterProvider")
          writeIORef collectRef collect
      , metricReaderCollect = do
          shutdown <- readIORef shutdownRef
          if shutdown
            then throwIO (userError "metric reader is shut down")
            else join (readIORef collectRef)
      , metricReaderForceFlush = do
          shutdown <- readIORef shutdownRef
          unless shutdown $ do
            collect <- readIORef collectRef
            runSynchronizedExportWithTimeout Nothing True exportLock stateRef exporter collect
      , metricReaderShutdown = async $ do
          writeIORef shutdownRef True
          metricExporterShutdown exporter
          pure ShutdownSuccess
      }


runSynchronizedExportWithTimeout
  :: Maybe Int
  -> Bool
  -> MVar ()
  -> IORef TemporalityState
  -> MetricExporter
  -> IO (MaterializedResources, [ScopeMetrics])
  -> IO ()
runSynchronizedExportWithTimeout timeoutMs shouldForceFlush exportLock stateRef exporter collect =
  withMVar exportLock $ \_ -> do
    let exportAction = runExport stateRef shouldForceFlush exporter collect
    case timeoutMs of
      Nothing -> exportAction
      Just ms
        | ms <= 0 -> exportAction
        | otherwise -> do
            _ <- race (threadDelay (ms * 1000)) exportAction
            pure ()


runExport :: IORef TemporalityState -> Bool -> MetricExporter -> IO (MaterializedResources, [ScopeMetrics]) -> IO ()
runExport stateRef shouldForceFlush exporter collect = do
  (resources, scopeMetrics) <- collect
  byScope <- prepareExportBatch stateRef (metricExporterTemporality exporter) scopeMetrics
  _ <- metricExporterExport exporter resources byScope
  when shouldForceFlush (metricExporterForceFlush exporter)
  pure ()


prepareExportBatch
  :: IORef TemporalityState
  -> (InstrumentKind -> AggregationTemporality)
  -> [ScopeMetrics]
  -> IO (HashMap InstrumentationLibrary (Vector MetricData))
prepareExportBatch stateRef selector scopeMetrics = do
  conversion <- atomicModifyIORef' stateRef $ \state ->
    case convertBatch selector state scopeMetrics of
      Left err -> (state, Left err)
      Right (nextState, byScope) -> (nextState, Right byScope)
  case conversion of
    Left err -> throwIO (userError err)
    Right byScope -> pure byScope


convertBatch
  :: (InstrumentKind -> AggregationTemporality)
  -> TemporalityState
  -> [ScopeMetrics]
  -> Either String (TemporalityState, HashMap InstrumentationLibrary (Vector MetricData))
convertBatch selector initialState scopeMetricsList =
  foldM
    ( \(state, byScope) scopeMetrics -> do
        (nextState, metrics_) <- convertScopeMetrics selector state scopeMetrics
        let scope = scopeMetricsScope scopeMetrics
        pure (nextState, HashMap.insertWith (<>) scope metrics_ byScope)
    )
    (initialState, mempty)
    scopeMetricsList


convertScopeMetrics
  :: (InstrumentKind -> AggregationTemporality)
  -> TemporalityState
  -> ScopeMetrics
  -> Either String (TemporalityState, Vector MetricData)
convertScopeMetrics selector initialState ScopeMetrics {scopeMetricsScope, scopeMetricsMetrics, scopeMetricsInstrumentKinds}
  | Vector.length scopeMetricsMetrics /= Vector.length scopeMetricsInstrumentKinds =
      Left $
        "scope metrics invariant violated for scope "
          <> show scopeMetricsScope
          <> ": metric count does not match instrument-kind count"
  | otherwise =
      let pairs = zip (Vector.toList scopeMetricsInstrumentKinds) (Vector.toList scopeMetricsMetrics)
          (nextState, revConverted) =
            List.foldl'
              ( \(state, acc) (kind, metricData) ->
                  let (state', convertedMetricData) = convertMetric selector scopeMetricsScope kind metricData state
                  in (state', convertedMetricData : acc)
              )
              (initialState, [])
              pairs
      in Right (nextState, Vector.fromList (reverse revConverted))


convertMetric
  :: (InstrumentKind -> AggregationTemporality)
  -> InstrumentationLibrary
  -> InstrumentKind
  -> MetricData
  -> TemporalityState
  -> (TemporalityState, MetricData)
convertMetric selector scope kind metricData state = case metricData of
  sumData@SumData {} ->
    convertSumData (selector kind) scope kind sumData state
  histogramData@HistogramData {} ->
    convertHistogramData (selector kind) scope kind histogramData state
  gaugeData@GaugeData {} ->
    convertGaugeData (selector kind) scope kind gaugeData state


convertSumData
  :: AggregationTemporality
  -> InstrumentationLibrary
  -> InstrumentKind
  -> MetricData
  -> TemporalityState
  -> (TemporalityState, MetricData)
convertSumData targetTemporality scope kind sumData@SumData {..} state =
  let (updatedSums, revPoints) =
        List.foldl'
          ( \(!sums, acc) point@DataPoint {dataPointAttributes, dataPointTimestamp, dataPointStartTimestamp, dataPointValue} ->
              let key = (scope, kind, sumName, sumDescription, sumUnit, sumIsMonotonic, dataPointAttributes)
                  series0 =
                    fromMaybe
                      SumSeriesState
                        { sumSeriesLastCumulative = Nothing
                        , sumSeriesAccumulatedCumulative = Nothing
                        , sumSeriesLastTimestamp = Nothing
                        , sumSeriesCumulativeStartTimestamp = Nothing
                        }
                      (HashMap.lookup key sums)
                  (nextValue, series1, deltaResetStart) =
                    case (sumTemporality, targetTemporality) of
                      (CumulativeTemporality, DeltaTemporality) ->
                        case sumSeriesLastCumulative series0 of
                          Nothing ->
                            ( dataPointValue
                            , series0 {sumSeriesLastCumulative = Just dataPointValue}
                            , Nothing
                            )
                          Just previous
                            | sumIsMonotonic && dataPointValue < previous ->
                                ( dataPointValue
                                , series0 {sumSeriesLastCumulative = Just dataPointValue}
                                , dataPointStartTimestamp <|> Just dataPointTimestamp
                                )
                            | otherwise ->
                                ( dataPointValue - previous
                                , series0 {sumSeriesLastCumulative = Just dataPointValue}
                                , Nothing
                                )
                      (DeltaTemporality, CumulativeTemporality) ->
                        let nextCumulative = maybe dataPointValue (+ dataPointValue) (sumSeriesAccumulatedCumulative series0)
                        in ( nextCumulative
                           , series0
                              { sumSeriesAccumulatedCumulative = Just nextCumulative
                              , sumSeriesLastCumulative = Just nextCumulative
                              }
                           , Nothing
                           )
                      (CumulativeTemporality, CumulativeTemporality) ->
                        ( dataPointValue
                        , series0 {sumSeriesLastCumulative = Just dataPointValue}
                        , Nothing
                        )
                      (DeltaTemporality, DeltaTemporality) ->
                        (dataPointValue, series0, Nothing)
                  startTimestamp =
                    case targetTemporality of
                      CumulativeTemporality ->
                        sumSeriesCumulativeStartTimestamp series1
                          <|> dataPointStartTimestamp
                          <|> Just dataPointTimestamp
                      DeltaTemporality ->
                        deltaResetStart
                          <|> sumSeriesLastTimestamp series1
                          <|> dataPointStartTimestamp
                          <|> Just dataPointTimestamp
                  series2 =
                    series1
                      { sumSeriesLastTimestamp = Just dataPointTimestamp
                      , sumSeriesCumulativeStartTimestamp =
                          case targetTemporality of
                            CumulativeTemporality -> startTimestamp
                            DeltaTemporality -> sumSeriesCumulativeStartTimestamp series1
                      }
                  point' =
                    point
                      { dataPointValue = nextValue
                      , dataPointStartTimestamp = startTimestamp
                      }
              in (HashMap.insert key series2 sums, point' : acc)
          )
          (temporalityStateSums state, [])
          (Vector.toList sumDataPoints)
      nextState = state {temporalityStateSums = updatedSums}
  in ( nextState
     , sumData
        { sumTemporality = targetTemporality
        , sumDataPoints = Vector.fromList (reverse revPoints)
        }
     )
convertSumData _ _ _ metricData state = (state, metricData)


convertHistogramData
  :: AggregationTemporality
  -> InstrumentationLibrary
  -> InstrumentKind
  -> MetricData
  -> TemporalityState
  -> (TemporalityState, MetricData)
convertHistogramData targetTemporality scope kind histogramData@HistogramData {..} state =
  let (updatedHistograms, revPoints) =
        List.foldl'
          ( \(!histograms, acc) point@HistogramDataPoint {histogramDataPointAttributes, histogramDataPointExplicitBounds, histogramDataPointTimestamp, histogramDataPointStartTimestamp} ->
              let key =
                    ( scope
                    , kind
                    , histogramName
                    , histogramDescription
                    , histogramUnit
                    , Vector.toList histogramDataPointExplicitBounds
                    , histogramDataPointAttributes
                    )
                  series0 =
                    fromMaybe
                      HistogramSeriesState
                        { histogramSeriesLastCumulative = Nothing
                        , histogramSeriesAccumulatedCumulative = Nothing
                        , histogramSeriesLastTimestamp = Nothing
                        , histogramSeriesCumulativeStartTimestamp = Nothing
                        }
                      (HashMap.lookup key histograms)
                  currentSnapshot = snapshotFromHistogramPoint point
                  (nextSnapshot, series1, deltaResetStart) =
                    case (histogramTemporality, targetTemporality) of
                      (CumulativeTemporality, DeltaTemporality) ->
                        case histogramSeriesLastCumulative series0 of
                          Nothing ->
                            ( currentSnapshot
                            , series0 {histogramSeriesLastCumulative = Just currentSnapshot}
                            , Nothing
                            )
                          Just previousSnapshot ->
                            if histogramReset previousSnapshot currentSnapshot
                              then
                                ( currentSnapshot
                                , series0 {histogramSeriesLastCumulative = Just currentSnapshot}
                                , histogramDataPointStartTimestamp <|> Just histogramDataPointTimestamp
                                )
                              else
                                ( subtractSnapshots currentSnapshot previousSnapshot
                                , series0 {histogramSeriesLastCumulative = Just currentSnapshot}
                                , Nothing
                                )
                      (DeltaTemporality, CumulativeTemporality) ->
                        let nextCumulative = case histogramSeriesAccumulatedCumulative series0 of
                              Nothing -> currentSnapshot
                              Just previousSnapshot
                                | Vector.length (histogramSnapshotBucketCounts previousSnapshot)
                                    == Vector.length (histogramSnapshotBucketCounts currentSnapshot) ->
                                    addSnapshots previousSnapshot currentSnapshot
                                | otherwise -> currentSnapshot
                        in ( nextCumulative
                           , series0
                              { histogramSeriesAccumulatedCumulative = Just nextCumulative
                              , histogramSeriesLastCumulative = Just nextCumulative
                              }
                           , Nothing
                           )
                      (CumulativeTemporality, CumulativeTemporality) ->
                        ( currentSnapshot
                        , series0 {histogramSeriesLastCumulative = Just currentSnapshot}
                        , Nothing
                        )
                      (DeltaTemporality, DeltaTemporality) ->
                        (currentSnapshot, series0, Nothing)
                  startTimestamp =
                    case targetTemporality of
                      CumulativeTemporality ->
                        histogramSeriesCumulativeStartTimestamp series1
                          <|> histogramDataPointStartTimestamp
                          <|> Just histogramDataPointTimestamp
                      DeltaTemporality ->
                        deltaResetStart
                          <|> histogramSeriesLastTimestamp series1
                          <|> histogramDataPointStartTimestamp
                          <|> Just histogramDataPointTimestamp
                  series2 =
                    series1
                      { histogramSeriesLastTimestamp = Just histogramDataPointTimestamp
                      , histogramSeriesCumulativeStartTimestamp =
                          case targetTemporality of
                            CumulativeTemporality -> startTimestamp
                            DeltaTemporality -> histogramSeriesCumulativeStartTimestamp series1
                      }
                  point' = histogramPointFromSnapshot targetTemporality point nextSnapshot startTimestamp
              in (HashMap.insert key series2 histograms, point' : acc)
          )
          (temporalityStateHistograms state, [])
          (Vector.toList histogramDataPoints)
      nextState = state {temporalityStateHistograms = updatedHistograms}
  in ( nextState
     , histogramData
        { histogramTemporality = targetTemporality
        , histogramDataPoints = Vector.fromList (reverse revPoints)
        }
     )
convertHistogramData _ _ _ metricData state = (state, metricData)


convertGaugeData
  :: AggregationTemporality
  -> InstrumentationLibrary
  -> InstrumentKind
  -> MetricData
  -> TemporalityState
  -> (TemporalityState, MetricData)
convertGaugeData targetTemporality scope kind gaugeData@GaugeData {..} state =
  let (updatedGauges, revPoints) =
        List.foldl'
          ( \(!gauges, acc) point@DataPoint {dataPointAttributes, dataPointTimestamp, dataPointStartTimestamp} ->
              let key = (scope, kind, gaugeName, gaugeDescription, gaugeUnit, dataPointAttributes)
                  series0 =
                    fromMaybe
                      GaugeSeriesState
                        { gaugeSeriesLastTimestamp = Nothing
                        , gaugeSeriesCumulativeStartTimestamp = Nothing
                        }
                      (HashMap.lookup key gauges)
                  startTimestamp =
                    case targetTemporality of
                      CumulativeTemporality ->
                        gaugeSeriesCumulativeStartTimestamp series0
                          <|> dataPointStartTimestamp
                          <|> Just dataPointTimestamp
                      DeltaTemporality ->
                        gaugeSeriesLastTimestamp series0
                          <|> dataPointStartTimestamp
                          <|> Just dataPointTimestamp
                  series1 =
                    series0
                      { gaugeSeriesLastTimestamp = Just dataPointTimestamp
                      , gaugeSeriesCumulativeStartTimestamp =
                          case targetTemporality of
                            CumulativeTemporality -> startTimestamp
                            DeltaTemporality -> gaugeSeriesCumulativeStartTimestamp series0
                      }
                  point' = point {dataPointStartTimestamp = startTimestamp}
              in (HashMap.insert key series1 gauges, point' : acc)
          )
          (temporalityStateGauges state, [])
          (Vector.toList gaugeDataPoints)
      nextState = state {temporalityStateGauges = updatedGauges}
  in (nextState, gaugeData {gaugeDataPoints = Vector.fromList (reverse revPoints)})
convertGaugeData _ _ _ metricData state = (state, metricData)


snapshotFromHistogramPoint :: HistogramDataPoint -> HistogramSnapshot
snapshotFromHistogramPoint HistogramDataPoint {..} =
  HistogramSnapshot
    { histogramSnapshotCount = histogramDataPointCount
    , histogramSnapshotSum = histogramDataPointSum
    , histogramSnapshotMin = histogramDataPointMin
    , histogramSnapshotMax = histogramDataPointMax
    , histogramSnapshotBucketCounts = histogramDataPointBucketCounts
    }


histogramPointFromSnapshot
  :: AggregationTemporality
  -> HistogramDataPoint
  -> HistogramSnapshot
  -> Maybe Timestamp
  -> HistogramDataPoint
histogramPointFromSnapshot targetTemporality point snapshot startTimestamp =
  point
    { histogramDataPointStartTimestamp = startTimestamp
    , histogramDataPointCount = histogramSnapshotCount snapshot
    , histogramDataPointSum = histogramSnapshotSum snapshot
    , histogramDataPointMin =
        case targetTemporality of
          DeltaTemporality -> Nothing
          CumulativeTemporality -> histogramSnapshotMin snapshot
    , histogramDataPointMax =
        case targetTemporality of
          DeltaTemporality -> Nothing
          CumulativeTemporality -> histogramSnapshotMax snapshot
    , histogramDataPointBucketCounts = histogramSnapshotBucketCounts snapshot
    }


histogramReset :: HistogramSnapshot -> HistogramSnapshot -> Bool
histogramReset previous current =
  histogramSnapshotCount current < histogramSnapshotCount previous
    || histogramSnapshotSum current < histogramSnapshotSum previous
    || Vector.length (histogramSnapshotBucketCounts current) /= Vector.length (histogramSnapshotBucketCounts previous)
    || Vector.any
      id
      (Vector.zipWith (<) (histogramSnapshotBucketCounts current) (histogramSnapshotBucketCounts previous))


subtractSnapshots :: HistogramSnapshot -> HistogramSnapshot -> HistogramSnapshot
subtractSnapshots current previous =
  HistogramSnapshot
    { histogramSnapshotCount = histogramSnapshotCount current - histogramSnapshotCount previous
    , histogramSnapshotSum = histogramSnapshotSum current - histogramSnapshotSum previous
    , histogramSnapshotMin = Nothing
    , histogramSnapshotMax = Nothing
    , histogramSnapshotBucketCounts =
        Vector.zipWith
          (-)
          (histogramSnapshotBucketCounts current)
          (histogramSnapshotBucketCounts previous)
    }


addSnapshots :: HistogramSnapshot -> HistogramSnapshot -> HistogramSnapshot
addSnapshots previous current =
  HistogramSnapshot
    { histogramSnapshotCount = histogramSnapshotCount previous + histogramSnapshotCount current
    , histogramSnapshotSum = histogramSnapshotSum previous + histogramSnapshotSum current
    , histogramSnapshotMin = combineMin (histogramSnapshotMin previous) (histogramSnapshotMin current)
    , histogramSnapshotMax = combineMax (histogramSnapshotMax previous) (histogramSnapshotMax current)
    , histogramSnapshotBucketCounts =
        Vector.zipWith
          (+)
          (histogramSnapshotBucketCounts previous)
          (histogramSnapshotBucketCounts current)
    }


combineMin :: Maybe Double -> Maybe Double -> Maybe Double
combineMin Nothing other = other
combineMin other Nothing = other
combineMin (Just left) (Just right) = Just (min left right)


combineMax :: Maybe Double -> Maybe Double -> Maybe Double
combineMax Nothing other = other
combineMax other Nothing = other
combineMax (Just left) (Just right) = Just (max left right)
