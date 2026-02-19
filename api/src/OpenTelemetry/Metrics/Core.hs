{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module OpenTelemetry.Metrics.Core (
  MeterProvider,
  MetricReader (..),
  createMeterProvider,
  shutdownMeterProvider,
  forceFlushMeterProvider,
  getGlobalMeterProvider,
  setGlobalMeterProvider,
  emptyMeterProviderOptions,
  MeterProviderOptions (..),
  getMeterProviderResources,
  Meter,
  meterName,
  HasMeter (..),
  makeMeter,
  getMeter,
  getMeterMeterProvider,
  InstrumentationLibrary (..),
  detectInstrumentationLibrary,
  MeterOptions (..),
  meterOptions,
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
  InstrumentKind (..),
  AggregationTemporality (..),
  MetricData (..),
  DataPoint (..),
  HistogramDataPoint (..),
  ScopeMetrics (..),
  Timestamp,
  getTimestamp,
) where

import Control.Concurrent.Async (wait)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class
import qualified Data.HashMap.Strict as H
import Data.IORef
import qualified Data.IntMap.Strict as IntMap
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import OpenTelemetry.Attributes
import OpenTelemetry.Common
import OpenTelemetry.Internal.Common.Types
import OpenTelemetry.Internal.Metrics.Types
import OpenTelemetry.Resource
import System.Clock
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)


data MeterProviderOptions = MeterProviderOptions
  { meterProviderOptionsResources :: MaterializedResources
  , meterProviderOptionsAttributeLimits :: AttributeLimits
  }


emptyMeterProviderOptions :: MeterProviderOptions
emptyMeterProviderOptions =
  MeterProviderOptions
    { meterProviderOptionsResources = emptyMaterializedResources
    , meterProviderOptionsAttributeLimits = defaultAttributeLimits
    }


newtype MeterOptions = MeterOptions
  { meterSchema :: Maybe Text
  }


meterOptions :: MeterOptions
meterOptions = MeterOptions Nothing


class HasMeter s where
  meterL :: Lens' s Meter


type Lens s t a b = forall f. (Functor f) => (a -> f b) -> s -> f t


type Lens' s a = Lens s s a a


globalMeterProvider :: IORef MeterProvider
globalMeterProvider = unsafePerformIO $ do
  p <- createMeterProvider [] emptyMeterProviderOptions
  newIORef p
{-# NOINLINE globalMeterProvider #-}


getGlobalMeterProvider :: (MonadIO m) => m MeterProvider
getGlobalMeterProvider = liftIO $ readIORef globalMeterProvider


setGlobalMeterProvider :: (MonadIO m) => MeterProvider -> m ()
setGlobalMeterProvider = liftIO . writeIORef globalMeterProvider


getMeterProviderResources :: MeterProvider -> MaterializedResources
getMeterProviderResources = meterProviderResources


createMeterProvider :: (MonadIO m) => [MetricReader] -> MeterProviderOptions -> m MeterProvider
createMeterProvider readers opts = liftIO $ do
  meterProviderMetricStreams <- newIORef []
  meterProviderRegisteredInstruments <- newIORef H.empty
  meterProviderIsShutdown <- newIORef False
  let provider =
        MeterProvider
          { meterProviderMetricReaders = V.fromList readers
          , meterProviderResources = meterProviderOptionsResources opts
          , meterProviderAttributeLimits = meterProviderOptionsAttributeLimits opts
          , meterProviderMetricStreams
          , meterProviderRegisteredInstruments
          , meterProviderIsShutdown
          }
      collect = collectScopeMetrics provider
  forM_ readers $ \reader -> metricReaderSetCollect reader collect
  pure provider


shutdownMeterProvider :: (MonadIO m) => MeterProvider -> m ()
shutdownMeterProvider MeterProvider {..} = liftIO $ do
  alreadyShutdown <- atomicModifyIORef' meterProviderIsShutdown (\shutdown -> (True, shutdown))
  unless alreadyShutdown $ do
    jobs <- forM meterProviderMetricReaders metricReaderShutdown
    mapM_ wait jobs


forceFlushMeterProvider :: (MonadIO m) => MeterProvider -> m ()
forceFlushMeterProvider MeterProvider {..} = liftIO $ do
  shutdown <- readIORef meterProviderIsShutdown
  unless shutdown $
    mapM_ metricReaderForceFlush meterProviderMetricReaders


makeMeter :: MeterProvider -> InstrumentationLibrary -> MeterOptions -> Meter
makeMeter provider lib MeterOptions {meterSchema} =
  let scope =
        lib
          { librarySchemaUrl = fromMaybe (librarySchemaUrl lib) meterSchema
          }
  in Meter {meterName = scope, meterProvider = provider}


getMeter :: (MonadIO m) => MeterProvider -> InstrumentationLibrary -> MeterOptions -> m Meter
getMeter provider lib opts = liftIO $ do
  when (T.null (libraryName lib)) $
    warnMetrics "invalid meter name: empty instrumentation scope name"
  pure $ makeMeter provider lib opts


getMeterMeterProvider :: Meter -> MeterProvider
getMeterMeterProvider = meterProvider


registerMetricStream :: MeterProvider -> MetricStream -> IO ()
registerMetricStream MeterProvider {meterProviderMetricStreams, meterProviderRegisteredInstruments} stream@MetricStream {..} = do
  let registryKey = (metricStreamScope, T.toCaseFold metricStreamName)
      identity = (metricStreamInstrumentKind, metricStreamName, metricStreamDescription, metricStreamUnit)
  previous <- atomicModifyIORef' meterProviderRegisteredInstruments $ \registry ->
    case H.lookup registryKey registry of
      Nothing -> (H.insert registryKey identity registry, Nothing)
      Just existing -> (registry, Just existing)
  case previous of
    Nothing -> pure ()
    Just (existingKind, existingName, existingDescription, existingUnit)
      | existingKind == metricStreamInstrumentKind
          && T.toCaseFold existingName == T.toCaseFold metricStreamName
          && existingDescription == metricStreamDescription
          && existingUnit == metricStreamUnit ->
          when (existingName /= metricStreamName) $
            warnMetrics $
              "case-insensitive duplicate instrument registration for '"
                <> T.unpack metricStreamName
                <> "', reusing first-seen name '"
                <> T.unpack existingName
                <> "'"
      | otherwise ->
          warnMetrics $
            "duplicate instrument registration for '"
              <> T.unpack metricStreamName
              <> "' conflicts with existing kind="
              <> show existingKind
              <> ", unit="
              <> T.unpack existingUnit
              <> ", description="
              <> show existingDescription
  atomicModifyIORef' meterProviderMetricStreams (\streams -> (streams <> [stream], ()))


isProviderShutdown :: MeterProvider -> IO Bool
isProviderShutdown MeterProvider {meterProviderIsShutdown} = readIORef meterProviderIsShutdown


collectScopeMetrics :: MeterProvider -> IO (MaterializedResources, [ScopeMetrics])
collectScopeMetrics MeterProvider {meterProviderMetricStreams, meterProviderResources} = do
  streams <- readIORef meterProviderMetricStreams
  scoped <- forM streams $ \MetricStream {..} -> do
    metric <- metricStreamCollect
    pure
      ( metricStreamScope
      , ScopeMetrics
          { scopeMetricsScope = metricStreamScope
          , scopeMetricsMetrics = V.singleton metric
          , scopeMetricsInstrumentKinds = V.singleton metricStreamInstrumentKind
          }
      )
  let grouped = H.fromListWith combineScopeMetrics scoped
  pure (meterProviderResources, fmap mergeScopeMetrics (H.elems grouped))
  where
    combineScopeMetrics left right =
      ScopeMetrics
        { scopeMetricsScope = scopeMetricsScope left
        , scopeMetricsMetrics = scopeMetricsMetrics right <> scopeMetricsMetrics left
        , scopeMetricsInstrumentKinds = scopeMetricsInstrumentKinds right <> scopeMetricsInstrumentKinds left
        }


type MetricIdentity = (Text, InstrumentKind, Text, Text, Maybe Bool)


mergeScopeMetrics :: ScopeMetrics -> ScopeMetrics
mergeScopeMetrics scopeMetrics@ScopeMetrics {scopeMetricsMetrics, scopeMetricsInstrumentKinds}
  | V.length scopeMetricsMetrics /= V.length scopeMetricsInstrumentKinds = scopeMetrics
  | otherwise =
      let pairs = zip (V.toList scopeMetricsInstrumentKinds) (V.toList scopeMetricsMetrics)
          (_, mergedPairs) =
            foldl'
              ( \(indexMap, acc) pair@(kind, metricData) ->
                  let identity = metricIdentity kind metricData
                  in case H.lookup identity indexMap of
                      Nothing ->
                        (H.insert identity (length acc) indexMap, acc <> [pair])
                      Just existingIndex ->
                        (indexMap, updateAt existingIndex (\(existingKind, existingMetric) -> (existingKind, mergeMetricData existingMetric metricData)) acc)
              )
              (H.empty, [])
              pairs
      in scopeMetrics
          { scopeMetricsMetrics = V.fromList (fmap snd mergedPairs)
          , scopeMetricsInstrumentKinds = V.fromList (fmap fst mergedPairs)
          }


metricIdentity :: InstrumentKind -> MetricData -> MetricIdentity
metricIdentity kind = \case
  SumData {sumName, sumDescription, sumUnit, sumIsMonotonic} ->
    (T.toCaseFold sumName, kind, sumDescription, sumUnit, Just sumIsMonotonic)
  GaugeData {gaugeName, gaugeDescription, gaugeUnit} ->
    (T.toCaseFold gaugeName, kind, gaugeDescription, gaugeUnit, Nothing)
  HistogramData {histogramName, histogramDescription, histogramUnit} ->
    (T.toCaseFold histogramName, kind, histogramDescription, histogramUnit, Nothing)


updateAt :: Int -> (a -> a) -> [a] -> [a]
updateAt index updateFn values =
  case splitAt index values of
    (prefix, current : suffix) -> prefix <> (updateFn current : suffix)
    _ -> values


mergeMetricData :: MetricData -> MetricData -> MetricData
mergeMetricData left right = case (left, right) of
  (leftSum@SumData {}, rightSum@SumData {}) ->
    leftSum {sumDataPoints = mergeSumPoints (sumDataPoints leftSum) (sumDataPoints rightSum)}
  (leftGauge@GaugeData {}, rightGauge@GaugeData {}) ->
    leftGauge {gaugeDataPoints = mergeGaugePoints (gaugeDataPoints leftGauge) (gaugeDataPoints rightGauge)}
  (leftHistogram@HistogramData {}, rightHistogram@HistogramData {}) ->
    leftHistogram {histogramDataPoints = mergeHistogramPoints (histogramDataPoints leftHistogram) (histogramDataPoints rightHistogram)}
  _ -> left


mergeSumPoints :: V.Vector (DataPoint Double) -> V.Vector (DataPoint Double) -> V.Vector (DataPoint Double)
mergeSumPoints left right =
  V.fromList $
    H.elems $
      foldl'
        ( \acc point@DataPoint {dataPointAttributes} ->
            H.insertWith
              combine
              dataPointAttributes
              point
              acc
        )
        H.empty
        (V.toList left <> V.toList right)
  where
    combine new old =
      old
        { dataPointStartTimestamp = combineStartTimestamp (dataPointStartTimestamp old) (dataPointStartTimestamp new)
        , dataPointTimestamp = max (dataPointTimestamp old) (dataPointTimestamp new)
        , dataPointValue = dataPointValue old + dataPointValue new
        }


mergeGaugePoints :: V.Vector (DataPoint Double) -> V.Vector (DataPoint Double) -> V.Vector (DataPoint Double)
mergeGaugePoints left right =
  V.fromList $
    H.elems $
      foldl'
        ( \acc point@DataPoint {dataPointAttributes} ->
            H.insertWith
              combine
              dataPointAttributes
              point
              acc
        )
        H.empty
        (V.toList left <> V.toList right)
  where
    combine new old
      | dataPointTimestamp new >= dataPointTimestamp old = new
      | otherwise = old


mergeHistogramPoints :: V.Vector HistogramDataPoint -> V.Vector HistogramDataPoint -> V.Vector HistogramDataPoint
mergeHistogramPoints left right =
  V.fromList $
    H.elems $
      foldl'
        ( \acc point@HistogramDataPoint {histogramDataPointAttributes, histogramDataPointExplicitBounds} ->
            H.insertWith
              combine
              (histogramDataPointAttributes, V.toList histogramDataPointExplicitBounds)
              point
              acc
        )
        H.empty
        (V.toList left <> V.toList right)
  where
    combine new old =
      old
        { histogramDataPointStartTimestamp =
            combineStartTimestamp
              (histogramDataPointStartTimestamp old)
              (histogramDataPointStartTimestamp new)
        , histogramDataPointTimestamp = max (histogramDataPointTimestamp old) (histogramDataPointTimestamp new)
        , histogramDataPointCount = histogramDataPointCount old + histogramDataPointCount new
        , histogramDataPointSum = histogramDataPointSum old + histogramDataPointSum new
        , histogramDataPointMin = combineMin (histogramDataPointMin old) (histogramDataPointMin new)
        , histogramDataPointMax = combineMax (histogramDataPointMax old) (histogramDataPointMax new)
        , histogramDataPointBucketCounts =
            V.zipWith (+) (histogramDataPointBucketCounts old) (histogramDataPointBucketCounts new)
        }


combineStartTimestamp :: Maybe Timestamp -> Maybe Timestamp -> Maybe Timestamp
combineStartTimestamp left right = case (left, right) of
  (Nothing, other) -> other
  (other, Nothing) -> other
  (Just leftTs, Just rightTs) -> Just (min leftTs rightTs)


combineMin :: Maybe Double -> Maybe Double -> Maybe Double
combineMin Nothing other = other
combineMin other Nothing = other
combineMin (Just left) (Just right) = Just (min left right)


combineMax :: Maybe Double -> Maybe Double -> Maybe Double
combineMax Nothing other = other
combineMax other Nothing = other
combineMax (Just left) (Just right) = Just (max left right)


warnMetrics :: String -> IO ()
warnMetrics = hPutStrLn stderr . ("Warning: " <>)


attributeMapToAttributes :: AttributeLimits -> AttributeMap -> Attributes
attributeMapToAttributes limits attrs = addAttributes limits emptyAttributes attrs


observation :: a -> AttributeMap -> Observation a
observation observationValue observationAttributes = Observation {observationValue, observationAttributes}


newtype CallbackRegistry a = CallbackRegistry (IORef (Int, IntMap.IntMap (IO [Observation a])))


newCallbackRegistry :: [IO [Observation a]] -> IO (CallbackRegistry a)
newCallbackRegistry callbacks = do
  let entries = IntMap.fromList (zip [0 ..] callbacks)
  CallbackRegistry <$> newIORef (length callbacks, entries)


registerInCallbackRegistry :: CallbackRegistry a -> IO [Observation a] -> IO CallbackRegistration
registerInCallbackRegistry (CallbackRegistry callbacksRef) callback = do
  callbackId <- atomicModifyIORef' callbacksRef $ \(nextId, callbacks) ->
    ((nextId + 1, IntMap.insert nextId callback callbacks), nextId)
  pure $
    CallbackRegistration
      { unregisterCallback =
          atomicModifyIORef' callbacksRef $ \(nextId, callbacks) ->
            ((nextId, IntMap.delete callbackId callbacks), ())
      }


collectCallbackObservations :: CallbackRegistry a -> IO [Observation a]
collectCallbackObservations (CallbackRegistry callbacksRef) = do
  (_, callbacks) <- readIORef callbacksRef
  concat <$> mapM id (IntMap.elems callbacks)


createCounter :: (MonadIO m) => Meter -> Text -> Text -> Text -> m (Counter Double)
createCounter meter name desc unit = liftIO $ do
  startTs <- getTimestamp
  valuesRef <- newIORef H.empty
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      addFn value attrs
        | value < 0 = pure ()
        | otherwise = atomicModifyIORef' valuesRef (\m -> (H.insertWith (+) attrs value m, ()))
      collectFn = do
        ts <- getTimestamp
        values <- readIORef valuesRef
        pure $
          SumData
            { sumName = name
            , sumDescription = desc
            , sumUnit = unit
            , sumTemporality = CumulativeTemporality
            , sumIsMonotonic = True
            , sumDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Just startTs
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit CounterKind collectFn)
  pure $
    Counter
      { counterName = name
      , counterDescription = desc
      , counterUnit = unit
      , counterMeter = meter
      , counterAdd = \value attrs -> do
          active <- not <$> isProviderShutdown provider
          when active (addFn value attrs)
      }


createUpDownCounter :: (MonadIO m) => Meter -> Text -> Text -> Text -> m (UpDownCounter Double)
createUpDownCounter meter name desc unit = liftIO $ do
  startTs <- getTimestamp
  valuesRef <- newIORef H.empty
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      addFn value attrs = atomicModifyIORef' valuesRef (\m -> (H.insertWith (+) attrs value m, ()))
      collectFn = do
        ts <- getTimestamp
        values <- readIORef valuesRef
        pure $
          SumData
            { sumName = name
            , sumDescription = desc
            , sumUnit = unit
            , sumTemporality = CumulativeTemporality
            , sumIsMonotonic = False
            , sumDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Just startTs
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit UpDownCounterKind collectFn)
  pure $
    UpDownCounter
      { upDownCounterName = name
      , upDownCounterDescription = desc
      , upDownCounterUnit = unit
      , upDownCounterMeter = meter
      , upDownCounterAdd = \value attrs -> do
          active <- not <$> isProviderShutdown provider
          when active (addFn value attrs)
      }


data HistogramState = HistogramState
  { hsCount :: !Int
  , hsSum :: !Double
  , hsMin :: !(Maybe Double)
  , hsMax :: !(Maybe Double)
  , hsBucketCounts :: !(V.Vector Int)
  }


defaultHistogramBounds :: V.Vector Double
defaultHistogramBounds = V.fromList [0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]


bucketIndex :: V.Vector Double -> Double -> Int
bucketIndex bounds value = fromMaybe (V.length bounds) $ V.findIndex (value <=) bounds


createHistogram :: (MonadIO m) => Meter -> Text -> Text -> Text -> m (Histogram Double)
createHistogram meter name desc unit = liftIO $ do
  startTs <- getTimestamp
  valuesRef <- newIORef H.empty
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      bounds = defaultHistogramBounds
      initialBucketCounts = V.replicate (V.length bounds + 1) 0
      recordFn value attrs = atomicModifyIORef' valuesRef $ \m ->
        let idx = bucketIndex bounds value
            next = case H.lookup attrs m of
              Nothing ->
                HistogramState
                  { hsCount = 1
                  , hsSum = value
                  , hsMin = Just value
                  , hsMax = Just value
                  , hsBucketCounts = initialBucketCounts V.// [(idx, 1)]
                  }
              Just old ->
                old
                  { hsCount = hsCount old + 1
                  , hsSum = hsSum old + value
                  , hsMin = Just $ maybe value (min value) (hsMin old)
                  , hsMax = Just $ maybe value (max value) (hsMax old)
                  , hsBucketCounts = hsBucketCounts old V.// [(idx, (hsBucketCounts old V.! idx) + 1)]
                  }
        in (H.insert attrs next m, ())
      collectFn = do
        ts <- getTimestamp
        values <- readIORef valuesRef
        pure $
          HistogramData
            { histogramName = name
            , histogramDescription = desc
            , histogramUnit = unit
            , histogramTemporality = CumulativeTemporality
            , histogramDataPoints =
                V.fromList
                  [ HistogramDataPoint
                    { histogramDataPointAttributes = attributeMapToAttributes limits attrs
                    , histogramDataPointStartTimestamp = Just startTs
                    , histogramDataPointTimestamp = ts
                    , histogramDataPointCount = hsCount hs
                    , histogramDataPointSum = hsSum hs
                    , histogramDataPointMin = hsMin hs
                    , histogramDataPointMax = hsMax hs
                    , histogramDataPointBucketCounts = hsBucketCounts hs
                    , histogramDataPointExplicitBounds = bounds
                    }
                  | (attrs, hs) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit HistogramKind collectFn)
  pure $
    Histogram
      { histogramName = name
      , histogramDescription = desc
      , histogramUnit = unit
      , histogramMeter = meter
      , histogramRecord = \value attrs -> do
          active <- not <$> isProviderShutdown provider
          when active (recordFn value attrs)
      }


createGauge :: (MonadIO m) => Meter -> Text -> Text -> Text -> m (Gauge Double)
createGauge meter name desc unit = liftIO $ do
  valuesRef <- newIORef H.empty
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      recordFn value attrs = atomicModifyIORef' valuesRef (\m -> (H.insert attrs value m, ()))
      collectFn = do
        ts <- getTimestamp
        values <- readIORef valuesRef
        pure $
          GaugeData
            { gaugeName = name
            , gaugeDescription = desc
            , gaugeUnit = unit
            , gaugeDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Nothing
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit GaugeKind collectFn)
  pure $
    Gauge
      { gaugeName = name
      , gaugeDescription = desc
      , gaugeUnit = unit
      , gaugeMeter = meter
      , gaugeRecord = \value attrs -> do
          active <- not <$> isProviderShutdown provider
          when active (recordFn value attrs)
      }


createObservableGauge
  :: (MonadIO m)
  => Meter
  -> Text
  -> Text
  -> Text
  -> [IO [Observation Double]]
  -> m (ObservableGauge Double)
createObservableGauge meter name desc unit callbacks = liftIO $ do
  startTs <- getTimestamp
  callbackRegistry <- newCallbackRegistry callbacks
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      collectFn = do
        ts <- getTimestamp
        observations <- collectCallbackObservations callbackRegistry
        let values =
              foldl'
                (\m Observation {observationValue, observationAttributes} -> H.insert observationAttributes observationValue m)
                H.empty
                observations
        pure $
          GaugeData
            { gaugeName = name
            , gaugeDescription = desc
            , gaugeUnit = unit
            , gaugeDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Just startTs
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit ObservableGaugeKind collectFn)
  pure $
    ObservableGauge
      { observableGaugeName = name
      , observableGaugeDescription = desc
      , observableGaugeUnit = unit
      , observableGaugeMeter = meter
      , observableGaugeRegisterCallback = \callback -> do
          active <- not <$> isProviderShutdown provider
          if active
            then registerInCallbackRegistry callbackRegistry callback
            else pure (CallbackRegistration (pure ()))
      }


createObservableCounter
  :: (MonadIO m)
  => Meter
  -> Text
  -> Text
  -> Text
  -> [IO [Observation Double]]
  -> m (ObservableCounter Double)
createObservableCounter meter name desc unit callbacks = liftIO $ do
  startTs <- getTimestamp
  callbackRegistry <- newCallbackRegistry callbacks
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      collectFn = do
        ts <- getTimestamp
        observations <- collectCallbackObservations callbackRegistry
        let values =
              foldl'
                ( \m Observation {observationValue, observationAttributes} ->
                    H.insert observationAttributes (max 0 observationValue) m
                )
                H.empty
                observations
        pure $
          SumData
            { sumName = name
            , sumDescription = desc
            , sumUnit = unit
            , sumTemporality = CumulativeTemporality
            , sumIsMonotonic = True
            , sumDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Just startTs
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit ObservableCounterKind collectFn)
  pure $
    ObservableCounter
      { observableCounterName = name
      , observableCounterDescription = desc
      , observableCounterUnit = unit
      , observableCounterMeter = meter
      , observableCounterRegisterCallback = \callback -> do
          active <- not <$> isProviderShutdown provider
          if active
            then registerInCallbackRegistry callbackRegistry callback
            else pure (CallbackRegistration (pure ()))
      }


createObservableUpDownCounter
  :: (MonadIO m)
  => Meter
  -> Text
  -> Text
  -> Text
  -> [IO [Observation Double]]
  -> m (ObservableUpDownCounter Double)
createObservableUpDownCounter meter name desc unit callbacks = liftIO $ do
  startTs <- getTimestamp
  callbackRegistry <- newCallbackRegistry callbacks
  let provider = getMeterMeterProvider meter
      limits = meterProviderAttributeLimits provider
      collectFn = do
        ts <- getTimestamp
        observations <- collectCallbackObservations callbackRegistry
        let values =
              foldl'
                (\m Observation {observationValue, observationAttributes} -> H.insert observationAttributes observationValue m)
                H.empty
                observations
        pure $
          SumData
            { sumName = name
            , sumDescription = desc
            , sumUnit = unit
            , sumTemporality = CumulativeTemporality
            , sumIsMonotonic = False
            , sumDataPoints =
                V.fromList
                  [ DataPoint
                    { dataPointAttributes = attributeMapToAttributes limits attrs
                    , dataPointStartTimestamp = Just startTs
                    , dataPointTimestamp = ts
                    , dataPointValue = value
                    }
                  | (attrs, value) <- H.toList values
                  ]
            }
  shutdown <- isProviderShutdown provider
  unless shutdown $
    registerMetricStream provider (MetricStream (meterName meter) name desc unit ObservableUpDownCounterKind collectFn)
  pure $
    ObservableUpDownCounter
      { observableUpDownCounterName = name
      , observableUpDownCounterDescription = desc
      , observableUpDownCounterUnit = unit
      , observableUpDownCounterMeter = meter
      , observableUpDownCounterRegisterCallback = \callback -> do
          active <- not <$> isProviderShutdown provider
          if active
            then registerInCallbackRegistry callbackRegistry callback
            else pure (CallbackRegistration (pure ()))
      }


getTimestamp :: IO Timestamp
getTimestamp = Timestamp <$> getTime Realtime
