module OpenTelemetry.Exporter.OTLP
  {-# DEPRECATED "use OpenTelemetry.Exporter.OTLP.Span, OpenTelemetry.Exporter.OTLP.LogRecord, or OpenTelemetry.Exporter.OTLP.Metric instead" #-} (
  module OpenTelemetry.Exporter.OTLP.Span,
  logRecordOtlpExporter,
  metricOtlpExporter,
) where

import Control.Monad.IO.Class (MonadIO)
import OpenTelemetry.Exporter.LogRecord (LogRecordExporter)
import OpenTelemetry.Exporter.Metric (MetricExporter)
import OpenTelemetry.Exporter.OTLP.Config (OTLPExporterConfig)
import qualified OpenTelemetry.Exporter.OTLP.LogRecord as LogRecord
import qualified OpenTelemetry.Exporter.OTLP.Metric as Metric
import OpenTelemetry.Exporter.OTLP.Span


logRecordOtlpExporter :: (MonadIO m) => OTLPExporterConfig -> m LogRecordExporter
logRecordOtlpExporter = LogRecord.otlpExporter


metricOtlpExporter :: (MonadIO m) => OTLPExporterConfig -> m MetricExporter
metricOtlpExporter = Metric.otlpExporter
