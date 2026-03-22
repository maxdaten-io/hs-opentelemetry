{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module OpenTelemetry.Exporter.OTLP.Metric where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeAsyncException (..), SomeException (..), fromException, throwIO, try)
import Control.Monad.IO.Class
import Data.Bits (shiftL)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.HashMap.Strict as HashMap
import Data.ProtoLens.Encoding
import Data.ProtoLens.Message
import qualified Data.Text as Text
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import qualified Data.Vector.Unboxed as UVector
import Lens.Micro
import Network.HTTP.Client
import qualified Network.HTTP.Client as HTTPClient
import Network.HTTP.Simple (httpBS)
import Network.HTTP.Types.Header
import Network.HTTP.Types.Status
import OpenTelemetry.Attributes
import OpenTelemetry.Exporter.Metric
import OpenTelemetry.Exporter.OTLP.Config
import qualified OpenTelemetry.Metrics.Core as OT
import OpenTelemetry.Resource hiding (Resource)
import OpenTelemetry.Trace.Core (timestampNanoseconds)
import Proto.Opentelemetry.Proto.Collector.Metrics.V1.MetricsService (ExportMetricsServiceRequest)
import qualified Proto.Opentelemetry.Proto.Collector.Metrics.V1.MetricsService_Fields as MetricsService_Fields
import Proto.Opentelemetry.Proto.Common.V1.Common
import qualified Proto.Opentelemetry.Proto.Common.V1.Common_Fields as Common_Fields
import Proto.Opentelemetry.Proto.Metrics.V1.Metrics
import qualified Proto.Opentelemetry.Proto.Metrics.V1.Metrics as ProtoMetrics
import qualified Proto.Opentelemetry.Proto.Metrics.V1.Metrics_Fields as Metrics_Fields
import Proto.Opentelemetry.Proto.Resource.V1.Resource
import qualified Proto.Opentelemetry.Proto.Resource.V1.Resource_Fields as Resource_Fields
import Text.Read (readMaybe)


otlpExporter :: (MonadIO m) => OTLPExporterConfig -> m MetricExporter
otlpExporter conf = liftIO $ do
  req <- parseRequest (otlpSignalEndpoint conf MetricsSignal)
  let (encodingHeaders, encoder) = httpCompressionForSignal conf MetricsSignal
  let baseReq =
        req
          { method = "POST"
          , requestHeaders = encodingHeaders <> httpBaseHeadersForSignal conf MetricsSignal req
          , responseTimeout = httpMetricsResponseTimeout conf
          }
  pure $
    MetricExporter
      { metricExporterExport = \resources metrics_ ->
          if HashMap.null metrics_
            then pure Success
            else do
              result <- try $ exporterExportCall encoder baseReq resources metrics_
              case result of
                Left err ->
                  case fromException err of
                    Just (SomeAsyncException _) -> throwIO err
                    Nothing -> pure $ Failure $ Just err
                Right ok -> pure ok
      , metricExporterShutdown = pure ()
      , metricExporterTemporality = \case
          OT.CounterKind -> OT.CumulativeTemporality
          OT.UpDownCounterKind -> OT.CumulativeTemporality
          OT.HistogramKind -> OT.CumulativeTemporality
          OT.GaugeKind -> OT.CumulativeTemporality
          OT.ObservableCounterKind -> OT.CumulativeTemporality
          OT.ObservableUpDownCounterKind -> OT.CumulativeTemporality
          OT.ObservableGaugeKind -> OT.CumulativeTemporality
      }
  where
    retryDelay = 100_000
    maxRetryCount = 5
    isRetryableStatusCode status_ =
      status_ == status408 || status_ == status429 || (statusCode status_ >= 500 && statusCode status_ < 600)
    isRetryableException = \case
      ResponseTimeout -> True
      ConnectionTimeout -> True
      ConnectionFailure _ -> True
      ConnectionClosed -> True
      _ -> False

    exporterExportCall encoder baseReq resources metrics_ = do
      msg <- encodeMessage <$> metricsToProtobuf resources metrics_
      let req =
            baseReq
              { requestBody =
                  RequestBodyLBS $ encoder $ LazyByteString.fromStrict msg
              }
      sendReq req 0

    sendReq req backoffCount = do
      eResp <- try $ httpBS req
      let exponentialBackoff =
            if backoffCount == maxRetryCount
              then pure $ Failure Nothing
              else do
                threadDelay (retryDelay `shiftL` backoffCount)
                sendReq req (backoffCount + 1)
      case eResp of
        Left err@(HttpExceptionRequest req' e)
          | HTTPClient.host req' == "localhost"
          , HTTPClient.port req' == 4317 || HTTPClient.port req' == 4318
          , ConnectionFailure _ <- e ->
              pure $ Failure Nothing
          | otherwise ->
              if isRetryableException e
                then exponentialBackoff
                else pure $ Failure $ Just $ SomeException err
        Left err -> pure $ Failure $ Just $ SomeException err
        Right resp ->
          if isRetryableStatusCode (responseStatus resp)
            then case lookup hRetryAfter (responseHeaders resp) of
              Nothing -> exponentialBackoff
              Just retryAfter ->
                case readMaybe $ ByteString.unpack retryAfter of
                  Nothing -> exponentialBackoff
                  Just seconds -> do
                    threadDelay (seconds * 1_000_000)
                    sendReq req (backoffCount + 1)
            else
              if statusCode (responseStatus resp) >= 300
                then pure $ Failure Nothing
                else pure Success


httpMetricsResponseTimeout :: OTLPExporterConfig -> ResponseTimeout
httpMetricsResponseTimeout conf = case otlpSignalTimeout conf MetricsSignal of
  Just timeoutMilli
    | timeoutMilli == 0 -> responseTimeoutNone
    | timeoutMilli >= 1 -> responseTimeoutMilli timeoutMilli
  _otherwise -> responseTimeoutMilli defaultExporterTimeout
  where
    responseTimeoutMilli :: Int -> ResponseTimeout
    responseTimeoutMilli = responseTimeoutMicro . (* 1_000)


metricsToProtobuf
  :: (MonadIO m)
  => MaterializedResources
  -> HashMap.HashMap OT.InstrumentationLibrary (Vector OT.MetricData)
  -> m ExportMetricsServiceRequest
metricsToProtobuf resources metricsByScope = do
  let scopeMetrics = fmap (uncurry makeScopeMetrics) (HashMap.toList metricsByScope)
      resourceMetrics =
        defMessage
          & Metrics_Fields.resource .~ makeResourceProto resources
          & maybe id ((Metrics_Fields.schemaUrl .~) . Text.pack) (getMaterializedResourcesSchema resources)
          & Metrics_Fields.vec'scopeMetrics .~ Vector.fromList scopeMetrics
  pure $
    defMessage
      & MetricsService_Fields.vec'resourceMetrics
        .~ Vector.singleton resourceMetrics


makeResourceProto :: MaterializedResources -> Resource
makeResourceProto r =
  defMessage
    & Resource_Fields.vec'attributes .~ attributesToProto (getMaterializedResourcesAttributes r)
    & Resource_Fields.droppedAttributesCount .~ 0


makeScopeMetrics :: OT.InstrumentationLibrary -> Vector OT.MetricData -> ScopeMetrics
makeScopeMetrics scope metrics_ =
  defMessage
    & Metrics_Fields.scope
      .~ ( defMessage
            & Common_Fields.name .~ OT.libraryName scope
            & Common_Fields.version .~ OT.libraryVersion scope
         )
    & Metrics_Fields.schemaUrl .~ OT.librarySchemaUrl scope
    & Metrics_Fields.vec'metrics .~ fmap metricDataToProto metrics_


metricDataToProto :: OT.MetricData -> Metric
metricDataToProto = \case
  OT.SumData {..} ->
    defMessage
      & Metrics_Fields.name .~ sumName
      & Metrics_Fields.description .~ sumDescription
      & Metrics_Fields.unit .~ sumUnit
      & Metrics_Fields.sum
        .~ ( defMessage
              & Metrics_Fields.vec'dataPoints .~ fmap numberDataPointToProto sumDataPoints
              & Metrics_Fields.aggregationTemporality .~ toProtoTemporality sumTemporality
              & Metrics_Fields.isMonotonic .~ sumIsMonotonic
           )
  OT.GaugeData {..} ->
    defMessage
      & Metrics_Fields.name .~ gaugeName
      & Metrics_Fields.description .~ gaugeDescription
      & Metrics_Fields.unit .~ gaugeUnit
      & Metrics_Fields.gauge
        .~ ( defMessage
              & Metrics_Fields.vec'dataPoints .~ fmap numberDataPointToProto gaugeDataPoints
           )
  OT.HistogramData {..} ->
    defMessage
      & Metrics_Fields.name .~ histogramName
      & Metrics_Fields.description .~ histogramDescription
      & Metrics_Fields.unit .~ histogramUnit
      & Metrics_Fields.histogram
        .~ ( defMessage
              & Metrics_Fields.vec'dataPoints .~ fmap histogramDataPointToProto histogramDataPoints
              & Metrics_Fields.aggregationTemporality .~ toProtoTemporality histogramTemporality
           )


numberDataPointToProto :: OT.DataPoint Double -> NumberDataPoint
numberDataPointToProto OT.DataPoint {..} =
  defMessage
    & Metrics_Fields.vec'attributes .~ attributesToProto dataPointAttributes
    & Metrics_Fields.timeUnixNano .~ timestampNanoseconds dataPointTimestamp
    & Metrics_Fields.asDouble .~ dataPointValue


histogramDataPointToProto :: OT.HistogramDataPoint -> HistogramDataPoint
histogramDataPointToProto OT.HistogramDataPoint {..} =
  defMessage
    & Metrics_Fields.vec'attributes .~ attributesToProto histogramDataPointAttributes
    & Metrics_Fields.timeUnixNano .~ timestampNanoseconds histogramDataPointTimestamp
    & Metrics_Fields.count .~ fromIntegral histogramDataPointCount
    & Metrics_Fields.sum .~ histogramDataPointSum
    & maybe id (Metrics_Fields.min .~) histogramDataPointMin
    & maybe id (Metrics_Fields.max .~) histogramDataPointMax
    & Metrics_Fields.vec'bucketCounts
      .~ UVector.fromList (fmap fromIntegral (Vector.toList histogramDataPointBucketCounts))
    & Metrics_Fields.vec'explicitBounds
      .~ UVector.fromList (Vector.toList histogramDataPointExplicitBounds)


toProtoTemporality :: OT.AggregationTemporality -> ProtoMetrics.AggregationTemporality
toProtoTemporality = \case
  OT.DeltaTemporality -> AGGREGATION_TEMPORALITY_DELTA
  OT.CumulativeTemporality -> AGGREGATION_TEMPORALITY_CUMULATIVE


attributesToProto :: Attributes -> Vector KeyValue
attributesToProto =
  Vector.fromList
    . fmap attributeToKeyValue
    . HashMap.toList
    . getAttributeMap
  where
    primAttributeToAnyValue = \case
      TextAttribute t -> defMessage & Common_Fields.stringValue .~ t
      BoolAttribute b -> defMessage & Common_Fields.boolValue .~ b
      DoubleAttribute d -> defMessage & Common_Fields.doubleValue .~ d
      IntAttribute i -> defMessage & Common_Fields.intValue .~ i
    attributeToKeyValue (k, v) =
      defMessage
        & Common_Fields.key .~ k
        & Common_Fields.value
          .~ ( case v of
                AttributeValue a -> primAttributeToAnyValue a
                AttributeArray a ->
                  defMessage
                    & Common_Fields.arrayValue
                      .~ (defMessage & Common_Fields.values .~ fmap primAttributeToAnyValue a)
             )
