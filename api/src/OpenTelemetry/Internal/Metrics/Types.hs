{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE StrictData #-}

module OpenTelemetry.Internal.Metrics.Types where

import Control.Concurrent.Async (Async)
import Data.HashMap.Strict (HashMap)
import Data.Hashable (Hashable)
import Data.IORef (IORef)
import Data.Text (Text)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import OpenTelemetry.Attributes
import OpenTelemetry.Common
import OpenTelemetry.Internal.Common.Types
import OpenTelemetry.Resource


data MetricExporter = MetricExporter
  { metricExporterExport :: MaterializedResources -> HashMap InstrumentationLibrary (Vector MetricData) -> IO ExportResult
  , metricExporterShutdown :: IO ()
  , metricExporterTemporality :: InstrumentKind -> AggregationTemporality
  }


data MetricReader = MetricReader
  { metricReaderSetCollect :: IO (MaterializedResources, [ScopeMetrics]) -> IO ()
  , metricReaderCollect :: IO (MaterializedResources, [ScopeMetrics])
  , metricReaderForceFlush :: IO ()
  , metricReaderShutdown :: IO (Async ShutdownResult)
  }


data MetricStream = MetricStream
  { metricStreamScope :: !InstrumentationLibrary
  , metricStreamInstrumentKind :: !InstrumentKind
  , metricStreamCollect :: IO MetricData
  }


data MeterProvider = MeterProvider
  { meterProviderMetricReaders :: !(Vector MetricReader)
  , meterProviderResources :: !MaterializedResources
  , meterProviderAttributeLimits :: !AttributeLimits
  , meterProviderMetricStreams :: !(IORef [MetricStream])
  }


data Meter = Meter
  { meterName :: {-# UNPACK #-} !InstrumentationLibrary
  , meterProvider :: !MeterProvider
  }


instance Show Meter where
  showsPrec d Meter {meterName = name} =
    showParen (d > 10) $ showString "Meter {meterName = " . shows name . showString "}"


data InstrumentKind
  = CounterKind
  | UpDownCounterKind
  | HistogramKind
  | GaugeKind
  | ObservableCounterKind
  | ObservableUpDownCounterKind
  | ObservableGaugeKind
  deriving (Show, Eq, Ord, Generic)


instance Hashable InstrumentKind


data AggregationTemporality
  = DeltaTemporality
  | CumulativeTemporality
  deriving (Show, Eq, Ord, Generic)


data Counter a = Counter
  { counterName :: !Text
  , counterDescription :: !Text
  , counterUnit :: !Text
  , counterMeter :: !Meter
  , counterAdd :: !(a -> AttributeMap -> IO ())
  }


data UpDownCounter a = UpDownCounter
  { upDownCounterName :: !Text
  , upDownCounterDescription :: !Text
  , upDownCounterUnit :: !Text
  , upDownCounterMeter :: !Meter
  , upDownCounterAdd :: !(a -> AttributeMap -> IO ())
  }


data Histogram a = Histogram
  { histogramName :: !Text
  , histogramDescription :: !Text
  , histogramUnit :: !Text
  , histogramMeter :: !Meter
  , histogramRecord :: !(a -> AttributeMap -> IO ())
  }


data Gauge a = Gauge
  { gaugeName :: !Text
  , gaugeDescription :: !Text
  , gaugeUnit :: !Text
  , gaugeMeter :: !Meter
  , gaugeRecord :: !(a -> AttributeMap -> IO ())
  }


data ObservableGauge a = ObservableGauge
  { observableGaugeName :: !Text
  , observableGaugeDescription :: !Text
  , observableGaugeUnit :: !Text
  , observableGaugeMeter :: !Meter
  , observableGaugeCallback :: !(AttributeMap -> IO a)
  }


data ObservableCounter a = ObservableCounter
  { observableCounterName :: !Text
  , observableCounterDescription :: !Text
  , observableCounterUnit :: !Text
  , observableCounterMeter :: !Meter
  , observableCounterCallback :: !(AttributeMap -> IO a)
  }


data ObservableUpDownCounter a = ObservableUpDownCounter
  { observableUpDownCounterName :: !Text
  , observableUpDownCounterDescription :: !Text
  , observableUpDownCounterUnit :: !Text
  , observableUpDownCounterMeter :: !Meter
  , observableUpDownCounterCallback :: !(AttributeMap -> IO a)
  }


data DataPoint a = DataPoint
  { dataPointAttributes :: !Attributes
  , dataPointStartTimestamp :: !(Maybe Timestamp)
  , dataPointTimestamp :: !Timestamp
  , dataPointValue :: !a
  }
  deriving (Show, Eq, Generic)


data MetricData
  = SumData
      { sumName :: !Text
      , sumDescription :: !Text
      , sumUnit :: !Text
      , sumTemporality :: !AggregationTemporality
      , sumIsMonotonic :: !Bool
      , sumDataPoints :: !(Vector (DataPoint Double))
      }
  | GaugeData
      { gaugeName :: !Text
      , gaugeDescription :: !Text
      , gaugeUnit :: !Text
      , gaugeDataPoints :: !(Vector (DataPoint Double))
      }
  | HistogramData
      { histogramName :: !Text
      , histogramDescription :: !Text
      , histogramUnit :: !Text
      , histogramTemporality :: !AggregationTemporality
      , histogramDataPoints :: !(Vector HistogramDataPoint)
      }
  deriving (Show, Eq, Generic)


data HistogramDataPoint = HistogramDataPoint
  { histogramDataPointAttributes :: !Attributes
  , histogramDataPointStartTimestamp :: !(Maybe Timestamp)
  , histogramDataPointTimestamp :: !Timestamp
  , histogramDataPointCount :: !Int
  , histogramDataPointSum :: !Double
  , histogramDataPointMin :: !(Maybe Double)
  , histogramDataPointMax :: !(Maybe Double)
  , histogramDataPointBucketCounts :: !(Vector Int)
  , histogramDataPointExplicitBounds :: !(Vector Double)
  }
  deriving (Show, Eq, Generic)


data ScopeMetrics = ScopeMetrics
  { scopeMetricsScope :: !InstrumentationLibrary
  , scopeMetricsMetrics :: !(Vector MetricData)
  , scopeMetricsInstrumentKinds :: !(Vector InstrumentKind)
  }
  deriving (Show, Eq, Generic)
