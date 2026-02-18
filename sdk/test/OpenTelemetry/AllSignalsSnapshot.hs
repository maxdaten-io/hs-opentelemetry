{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module OpenTelemetry.AllSignalsSnapshot (allSignalsSnapshotGolden) where

import Data.Foldable (toList)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import Data.List (intercalate, nub, sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import OpenTelemetry.Attributes (
  Attribute (..),
  Attributes,
  PrimitiveAttribute (..),
  ToAttribute (..),
  getAttributeMap,
 )
import qualified OpenTelemetry.Context as Context
import qualified OpenTelemetry.Exporter.InMemory.LogRecord as InMemoryLog
import qualified OpenTelemetry.Exporter.InMemory.Span as InMemorySpan
import OpenTelemetry.Exporter.Metric (AggregationTemporality (..), ExportResult (..), MetricExporter (..))
import OpenTelemetry.Internal.Logs.Types (ImmutableLogRecord (..), emptyLogRecordArguments)
import qualified OpenTelemetry.LogAttributes as LogAttributes
import qualified OpenTelemetry.Logs.Core as Logs
import qualified OpenTelemetry.Metrics as Metrics
import qualified OpenTelemetry.Metrics.Core as MetricsCore
import OpenTelemetry.Metrics.MetricReader (manualReader)
import OpenTelemetry.Resource (MaterializedResources, Resource, getMaterializedResourcesAttributes, materializeResources, mkResource)
import qualified OpenTelemetry.Trace as Trace
import OpenTelemetry.Trace.Id (Base (..), SpanId, TraceId, spanIdBaseEncodedText, traceIdBaseEncodedText)
import OpenTelemetry.Trace.Id.Generator.Default (defaultIdGenerator)
import Test.Hspec.Golden (Golden, defaultGolden)


type MetricBatch = (MaterializedResources, [(MetricsCore.InstrumentationLibrary, [MetricsCore.MetricData])])


allSignalsSnapshotGolden :: IO (Golden String)
allSignalsSnapshotGolden = defaultGolden "all-signals-snapshot" <$> produceSnapshot


produceSnapshot :: IO String
produceSnapshot = do
  let fixedResource = buildFixedResource

  (spanProcessor, spansRef) <- InMemorySpan.inMemoryListExporter
  tracerProvider <-
    Trace.createTracerProvider
      [spanProcessor]
      ( Trace.emptyTracerProviderOptions
          { Trace.tracerProviderOptionsIdGenerator = defaultIdGenerator
          , Trace.tracerProviderOptionsResources = fixedResource
          }
      )
  let tracer = Trace.makeTracer tracerProvider "snapshot-tracer" Trace.tracerOptions

  (logProcessor, logsRef) <- InMemoryLog.inMemoryListExporter
  let loggerProvider =
        Logs.createLoggerProvider
          [logProcessor]
          ( Logs.emptyLoggerProviderOptions
              { Logs.loggerProviderOptionsResources = fixedResource
              }
          )
      logger = Logs.makeLogger loggerProvider "snapshot-logger"

  (metricBatchesRef, metricExporter) <- mkCaptureMetricExporter
  metricReader <- manualReader metricExporter
  meterProvider <-
    Metrics.createMeterProvider
      [metricReader]
      ( Metrics.emptyMeterProviderOptions
          { Metrics.meterProviderOptionsResources = fixedResource
          }
      )
  meter <- Metrics.getMeter meterProvider "snapshot-meter" Metrics.meterOptions

  emitTracesAndLogs tracer logger
  emitMetrics meter
  MetricsCore.forceFlushMeterProvider meterProvider

  spans <- readIORef spansRef
  logs <- readIORef logsRef
  metricBatches <- reverse <$> readIORef metricBatchesRef

  pure $ renderSnapshot fixedResource spans logs metricBatches


buildFixedResource :: MaterializedResources
buildFixedResource =
  materializeResources $
    ( mkResource
        [ Just ("service.name", toAttribute ("hs-opentelemetry-sdk-all-signals" :: Text))
        , Just ("service.version", toAttribute ("1.0.0-test" :: Text))
        , Just ("deployment.environment.name", toAttribute ("snapshot" :: Text))
        ]
        :: Resource 'Nothing
    )


emitTracesAndLogs :: Trace.Tracer -> Logs.Logger -> IO ()
emitTracesAndLogs tracer logger = do
  rootSpan <- Trace.createSpan tracer Context.empty "snapshot.root" Trace.defaultSpanArguments
  Trace.addAttribute rootSpan "span.level" ("root" :: Text)
  Trace.setStatus rootSpan Trace.Ok

  childSpan <- Trace.createSpan tracer (Context.insertSpan rootSpan Context.empty) "snapshot.child" Trace.defaultSpanArguments
  Trace.addAttribute childSpan "span.level" ("child" :: Text)
  Trace.setStatus childSpan (Trace.Error "child-failure")

  _ <-
    Logs.emitLogRecord
      logger
      ( emptyLogRecordArguments
          { Logs.context = Just Context.empty
          , Logs.eventName = Just "standalone.event"
          , Logs.severityNumber = Just Logs.Info
          , Logs.body = Logs.toValue ("standalone log" :: Text)
          , Logs.attributes = [("log.kind", Logs.toValue ("standalone" :: Text))]
          }
      )
  _ <-
    Logs.emitLogRecord
      logger
      ( emptyLogRecordArguments
          { Logs.context = Just (Context.insertSpan childSpan Context.empty)
          , Logs.eventName = Just "contextual.event"
          , Logs.severityNumber = Just Logs.Warn
          , Logs.body = Logs.toValue ("contextual log" :: Text)
          , Logs.attributes = [("log.kind", Logs.toValue ("contextual" :: Text))]
          }
      )
  Trace.endSpan childSpan Nothing
  Trace.endSpan rootSpan Nothing


emitMetrics :: Metrics.Meter -> IO ()
emitMetrics meter = do
  counter <- Metrics.createCounter meter "requests_total" "Total requests" "1"
  Metrics.counterAdd counter 3 [("route", toAttribute ("/" :: Text))]

  upDown <- Metrics.createUpDownCounter meter "queue_depth" "Queue depth" "1"
  Metrics.upDownCounterAdd upDown (-2) [("queue", toAttribute ("jobs" :: Text))]

  histogram <- Metrics.createHistogram meter "request_latency_ms" "Request latency" "ms"
  Metrics.histogramRecord histogram 42 [("endpoint", toAttribute ("/api" :: Text))]

  _ <- Metrics.createGauge meter "temperature_gauge" "Temperature" "c" (\_ -> pure 21.5)
  _ <- Metrics.createObservableCounter meter "workers_total" "Workers" "1" (\_ -> pure 7.0)
  _ <- Metrics.createObservableUpDownCounter meter "pressure_level" "Pressure" "1" (\_ -> pure (-1.5))
  pure ()


mkCaptureMetricExporter :: IO (IORef [MetricBatch], MetricExporter)
mkCaptureMetricExporter = do
  batchesRef <- newIORef []
  let exporter =
        MetricExporter
          { metricExporterExport = \resources byScope -> do
              let capturedScopes =
                    sortOn
                      (scopeSortKey . fst)
                      [ (scope, sortOn metricSortKey (toList scopeMetrics))
                      | (scope, scopeMetrics) <- HashMap.toList byScope
                      ]
              modifyIORef' batchesRef ((resources, capturedScopes) :)
              pure Success
          , metricExporterShutdown = pure ()
          , metricExporterTemporality = const CumulativeTemporality
          }
  pure (batchesRef, exporter)


renderSnapshot :: MaterializedResources -> [Trace.ImmutableSpan] -> [ImmutableLogRecord] -> [MetricBatch] -> String
renderSnapshot fixedResource spans logs metricBatches =
  unlines $
    [ "# all-signals snapshot"
    , "signals=traces,logs,metrics"
    , "resource=[" ++ renderAttributesInline (getMaterializedResourcesAttributes fixedResource) ++ "]"
    , ""
    , "[traces]"
    ]
      ++ traceLines
      ++ [""]
      ++ ["[logs]"]
      ++ logLines
      ++ [""]
      ++ ["[metrics]"]
      ++ metricLines
  where
    orderedSpans = sortOn (Text.unpack . Trace.spanName) spans
    orderedLogs = sortOn (maybe "" Text.unpack . logRecordEventName) logs

    traceIds =
      nub
        ( [ traceIdKey (Trace.traceId (Trace.spanContext emittedSpan))
          | emittedSpan <- orderedSpans
          ]
            ++ [ traceIdKey traceId
               | ImmutableLogRecord {logRecordTracingDetails = Just (traceId, _, _)} <- orderedLogs
               ]
        )
    spanIds =
      nub
        ( [ spanIdKey (Trace.spanId (Trace.spanContext emittedSpan))
          | emittedSpan <- orderedSpans
          ]
            ++ [ spanIdKey spanId
               | ImmutableLogRecord {logRecordTracingDetails = Just (_, spanId, _)} <- orderedLogs
               ]
        )
    normalizedTraceIds = zip traceIds [(1 :: Int) ..]
    normalizedSpanIds = zip spanIds [(1 :: Int) ..]

    normalizeTraceId traceId = lookupNormalizedId "t" normalizedTraceIds (traceIdKey traceId)
    normalizeSpanId spanId = lookupNormalizedId "s" normalizedSpanIds (spanIdKey spanId)

    traceLines =
      if null spans
        then ["(no spans)"]
        else sort (map (renderSpanLine normalizeTraceId normalizeSpanId) spans)

    logLines =
      if null logs
        then ["(no logs)"]
        else sort (map (renderLogLine normalizeTraceId normalizeSpanId) logs)

    metricLines =
      if null metricBatches
        then ["(no metric exports)"]
        else concatMap renderMetricBatch (zip [(1 :: Int) ..] metricBatches)


renderSpanLine
  :: (TraceId -> String)
  -> (SpanId -> String)
  -> Trace.ImmutableSpan
  -> String
renderSpanLine normalizeTraceId normalizeSpanId span_ =
  intercalate
    " | "
    [ "span=" ++ showText (Trace.spanName span_)
    , "parent=" ++ if maybe False (const True) (Trace.spanParent span_) then "present" else "none"
    , "kind=" ++ show (Trace.spanKind span_)
    , "status=" ++ renderSpanStatus (Trace.spanStatus span_)
    , "trace=" ++ normalizeTraceId (Trace.traceId ctx)
    , "span_id=" ++ normalizeSpanId (Trace.spanId ctx)
    , "flags=" ++ show (Trace.traceFlags ctx)
    , "start=<ts>"
    , "end=" ++ if maybe False (const True) (Trace.spanEnd span_) then "<ts>" else "<none>"
    , "attrs=[" ++ renderAttributesInline (Trace.spanAttributes span_) ++ "]"
    ]
  where
    ctx = Trace.spanContext span_


renderSpanStatus :: Trace.SpanStatus -> String
renderSpanStatus status = case status of
  Trace.Unset -> "Unset"
  Trace.Ok -> "Ok"
  Trace.Error message -> "Error(" ++ showText message ++ ")"


renderLogLine
  :: (TraceId -> String)
  -> (SpanId -> String)
  -> ImmutableLogRecord
  -> String
renderLogLine normalizeTraceId normalizeSpanId ImmutableLogRecord {..} =
  intercalate
    " | "
    [ "event=" ++ maybe "<none>" showText logRecordEventName
    , "severity_number=" ++ maybe "<none>" show logRecordSeverityNumber
    , "severity_text=" ++ maybe "<none>" showText logRecordSeverityText
    , "timestamp=" ++ maybe "<none>" (const "<ts>") logRecordTimestamp
    , "observed=<ts>"
    , "trace=" ++ traceInfo
    , "span_id=" ++ spanInfo
    , "flags=" ++ flagsInfo
    , "body=" ++ renderAnyValue logRecordBody
    , "attrs=[" ++ renderLogAttributesInline logRecordAttributes ++ "]"
    ]
  where
    (traceInfo, spanInfo, flagsInfo) = case logRecordTracingDetails of
      Nothing -> ("<none>", "<none>", "<none>")
      Just (traceId, spanId, traceFlags) ->
        ( normalizeTraceId traceId
        , normalizeSpanId spanId
        , show traceFlags
        )


renderMetricBatch :: (Int, MetricBatch) -> [String]
renderMetricBatch (batchIndex, (resource, scopes)) =
  ["batch=" ++ show batchIndex ++ " resource=[" ++ renderAttributesInline (getMaterializedResourcesAttributes resource) ++ "]"]
    ++ concatMap renderScope scopesSorted
  where
    scopesSorted = sortOn (scopeSortKey . fst) scopes

    renderScope :: (MetricsCore.InstrumentationLibrary, [MetricsCore.MetricData]) -> [String]
    renderScope (scope, metrics_) =
      [ "scope="
          ++ showText (MetricsCore.libraryName scope)
          ++ " version="
          ++ showText (MetricsCore.libraryVersion scope)
          ++ " schema="
          ++ showText (MetricsCore.librarySchemaUrl scope)
          ++ " attrs=["
          ++ renderAttributesInline (MetricsCore.libraryAttributes scope)
          ++ "]"
      ]
        ++ concatMap renderMetricData (sortOn metricSortKey metrics_)


renderMetricData :: MetricsCore.MetricData -> [String]
renderMetricData metricData = case metricData of
  MetricsCore.SumData {..} ->
    [ "metric=sum name="
        ++ showText sumName
        ++ " unit="
        ++ showText sumUnit
        ++ " monotonic="
        ++ show sumIsMonotonic
        ++ " temporality="
        ++ show sumTemporality
    ]
      ++ map renderNumberDataPoint points
    where
      points = sortOn metricPointSortKey (toList sumDataPoints)
  MetricsCore.GaugeData {..} ->
    ["metric=gauge name=" ++ showText gaugeName ++ " unit=" ++ showText gaugeUnit]
      ++ map renderNumberDataPoint points
    where
      points = sortOn metricPointSortKey (toList gaugeDataPoints)
  MetricsCore.HistogramData {..} ->
    [ "metric=histogram name="
        ++ showText histogramName
        ++ " unit="
        ++ showText histogramUnit
        ++ " temporality="
        ++ show histogramTemporality
    ]
      ++ map renderHistogramDataPoint points
    where
      points = sortOn histogramPointSortKey (toList histogramDataPoints)


renderNumberDataPoint :: MetricsCore.DataPoint Double -> String
renderNumberDataPoint point =
  "  point attrs=["
    ++ renderAttributesInline (MetricsCore.dataPointAttributes point)
    ++ "] ts=<ts> value="
    ++ show (MetricsCore.dataPointValue point)


renderHistogramDataPoint :: MetricsCore.HistogramDataPoint -> String
renderHistogramDataPoint point =
  "  point attrs=["
    ++ renderAttributesInline (MetricsCore.histogramDataPointAttributes point)
    ++ "] ts=<ts> count="
    ++ show (MetricsCore.histogramDataPointCount point)
    ++ " sum="
    ++ show (MetricsCore.histogramDataPointSum point)
    ++ " min="
    ++ show (MetricsCore.histogramDataPointMin point)
    ++ " max="
    ++ show (MetricsCore.histogramDataPointMax point)
    ++ " buckets="
    ++ show (toList (MetricsCore.histogramDataPointBucketCounts point))
    ++ " bounds="
    ++ show (toList (MetricsCore.histogramDataPointExplicitBounds point))


metricSortKey :: MetricsCore.MetricData -> (String, String)
metricSortKey metricData = case metricData of
  MetricsCore.SumData {sumName} -> ("sum", Text.unpack sumName)
  MetricsCore.GaugeData {gaugeName} -> ("gauge", Text.unpack gaugeName)
  MetricsCore.HistogramData {histogramName} -> ("histogram", Text.unpack histogramName)


metricPointSortKey :: MetricsCore.DataPoint Double -> (String, Double)
metricPointSortKey point = (renderAttributesInline (MetricsCore.dataPointAttributes point), MetricsCore.dataPointValue point)


histogramPointSortKey :: MetricsCore.HistogramDataPoint -> (String, Int, Double)
histogramPointSortKey point =
  ( renderAttributesInline (MetricsCore.histogramDataPointAttributes point)
  , MetricsCore.histogramDataPointCount point
  , MetricsCore.histogramDataPointSum point
  )


scopeSortKey :: MetricsCore.InstrumentationLibrary -> (String, String, String)
scopeSortKey lib =
  ( Text.unpack (MetricsCore.libraryName lib)
  , Text.unpack (MetricsCore.libraryVersion lib)
  , Text.unpack (MetricsCore.librarySchemaUrl lib)
  )


renderAttributesInline :: Attributes -> String
renderAttributesInline attrs =
  intercalate
    ","
    [ Text.unpack key ++ "=" ++ renderAttribute value
    | (key, value) <- sortOn fst (HashMap.toList (getAttributeMap attrs))
    , not (isVolatileAttributeKey key)
    ]


renderAttribute :: Attribute -> String
renderAttribute attribute = case attribute of
  AttributeValue value -> renderPrimitiveAttribute value
  AttributeArray values -> "[" ++ intercalate "," (map renderPrimitiveAttribute values) ++ "]"


renderPrimitiveAttribute :: PrimitiveAttribute -> String
renderPrimitiveAttribute primitive = case primitive of
  TextAttribute value -> showText value
  BoolAttribute value -> show value
  DoubleAttribute value -> show value
  IntAttribute value -> show value


renderLogAttributesInline :: LogAttributes.LogAttributes -> String
renderLogAttributesInline attrs =
  "count="
    ++ show attrCount
    ++ ",dropped="
    ++ show (LogAttributes.attributesDropped attrs)
    ++ ",values={"
    ++ intercalate
      ","
      [ Text.unpack key ++ "=" ++ renderAnyValue value
      | (key, value) <- sortOn fst (HashMap.toList attrMap)
      ]
    ++ "}"
  where
    (attrCount, attrMap) = LogAttributes.getAttributeMap attrs


renderAnyValue :: LogAttributes.AnyValue -> String
renderAnyValue value = case value of
  LogAttributes.TextValue textValue -> showText textValue
  LogAttributes.BoolValue boolValue -> show boolValue
  LogAttributes.DoubleValue doubleValue -> show doubleValue
  LogAttributes.IntValue intValue -> show intValue
  LogAttributes.ByteStringValue bytesValue -> show bytesValue
  LogAttributes.ArrayValue arrayValue -> "[" ++ intercalate "," (map renderAnyValue arrayValue) ++ "]"
  LogAttributes.HashMapValue mapValue ->
    "{"
      ++ intercalate
        ","
        [ Text.unpack key ++ "=" ++ renderAnyValue subValue
        | (key, subValue) <- sortOn fst (HashMap.toList mapValue)
        ]
      ++ "}"
  LogAttributes.NullValue -> "null"


traceIdKey :: TraceId -> String
traceIdKey = Text.unpack . traceIdBaseEncodedText Base16


spanIdKey :: SpanId -> String
spanIdKey = Text.unpack . spanIdBaseEncodedText Base16


lookupNormalizedId :: String -> [(String, Int)] -> String -> String
lookupNormalizedId prefix knownIds rawValue = case lookup rawValue knownIds of
  Just index -> prefix ++ show index
  Nothing -> prefix ++ "?"


showText :: Text -> String
showText = show . Text.unpack


isVolatileAttributeKey :: Text -> Bool
isVolatileAttributeKey key =
  key == "thread.id" || "code." `Text.isPrefixOf` key
