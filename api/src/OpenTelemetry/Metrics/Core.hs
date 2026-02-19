{-# LANGUAGE DuplicateRecordFields #-}
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
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class
import qualified Data.HashMap.Strict as H
import Data.IORef
import qualified Data.IntMap.Strict as IntMap
import Data.List (foldl')
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Vector as V
import OpenTelemetry.Attributes
import OpenTelemetry.Common
import OpenTelemetry.Internal.Common.Types
import OpenTelemetry.Internal.Metrics.Types
import OpenTelemetry.Resource
import System.Clock
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
  let provider =
        MeterProvider
          { meterProviderMetricReaders = V.fromList readers
          , meterProviderResources = meterProviderOptionsResources opts
          , meterProviderAttributeLimits = meterProviderOptionsAttributeLimits opts
          , meterProviderMetricStreams
          }
      collect = collectScopeMetrics provider
  forM_ readers $ \reader -> metricReaderSetCollect reader collect
  pure provider


shutdownMeterProvider :: (MonadIO m) => MeterProvider -> m ()
shutdownMeterProvider MeterProvider {..} = liftIO $ do
  jobs <- forM meterProviderMetricReaders metricReaderShutdown
  mapM_ wait jobs


forceFlushMeterProvider :: (MonadIO m) => MeterProvider -> m ()
forceFlushMeterProvider MeterProvider {..} =
  liftIO $
    mapM_ metricReaderForceFlush meterProviderMetricReaders


makeMeter :: MeterProvider -> InstrumentationLibrary -> MeterOptions -> Meter
makeMeter provider lib _ = Meter {meterName = lib, meterProvider = provider}


getMeter :: (MonadIO m) => MeterProvider -> InstrumentationLibrary -> MeterOptions -> m Meter
getMeter provider lib opts = liftIO $ pure $ makeMeter provider lib opts


getMeterMeterProvider :: Meter -> MeterProvider
getMeterMeterProvider = meterProvider


registerMetricStream :: MeterProvider -> MetricStream -> IO ()
registerMetricStream MeterProvider {meterProviderMetricStreams} stream =
  atomicModifyIORef' meterProviderMetricStreams (\streams -> (stream : streams, ()))


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
  pure (meterProviderResources, H.elems grouped)
  where
    combineScopeMetrics left right =
      ScopeMetrics
        { scopeMetricsScope = scopeMetricsScope left
        , scopeMetricsMetrics = scopeMetricsMetrics left <> scopeMetricsMetrics right
        , scopeMetricsInstrumentKinds = scopeMetricsInstrumentKinds left <> scopeMetricsInstrumentKinds right
        }


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
  registerMetricStream provider (MetricStream (meterName meter) CounterKind collectFn)
  pure $
    Counter
      { counterName = name
      , counterDescription = desc
      , counterUnit = unit
      , counterMeter = meter
      , counterAdd = addFn
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
  registerMetricStream provider (MetricStream (meterName meter) UpDownCounterKind collectFn)
  pure $
    UpDownCounter
      { upDownCounterName = name
      , upDownCounterDescription = desc
      , upDownCounterUnit = unit
      , upDownCounterMeter = meter
      , upDownCounterAdd = addFn
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
  registerMetricStream provider (MetricStream (meterName meter) HistogramKind collectFn)
  pure $
    Histogram
      { histogramName = name
      , histogramDescription = desc
      , histogramUnit = unit
      , histogramMeter = meter
      , histogramRecord = recordFn
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
  registerMetricStream provider (MetricStream (meterName meter) GaugeKind collectFn)
  pure $
    Gauge
      { gaugeName = name
      , gaugeDescription = desc
      , gaugeUnit = unit
      , gaugeMeter = meter
      , gaugeRecord = recordFn
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
  registerMetricStream provider (MetricStream (meterName meter) ObservableGaugeKind collectFn)
  pure $
    ObservableGauge
      { observableGaugeName = name
      , observableGaugeDescription = desc
      , observableGaugeUnit = unit
      , observableGaugeMeter = meter
      , observableGaugeRegisterCallback = registerInCallbackRegistry callbackRegistry
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
  registerMetricStream provider (MetricStream (meterName meter) ObservableCounterKind collectFn)
  pure $
    ObservableCounter
      { observableCounterName = name
      , observableCounterDescription = desc
      , observableCounterUnit = unit
      , observableCounterMeter = meter
      , observableCounterRegisterCallback = registerInCallbackRegistry callbackRegistry
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
  registerMetricStream provider (MetricStream (meterName meter) ObservableUpDownCounterKind collectFn)
  pure $
    ObservableUpDownCounter
      { observableUpDownCounterName = name
      , observableUpDownCounterDescription = desc
      , observableUpDownCounterUnit = unit
      , observableUpDownCounterMeter = meter
      , observableUpDownCounterRegisterCallback = registerInCallbackRegistry callbackRegistry
      }


getTimestamp :: IO Timestamp
getTimestamp = Timestamp <$> getTime Realtime
