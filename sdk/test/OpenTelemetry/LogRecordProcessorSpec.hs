{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module OpenTelemetry.LogRecordProcessorSpec (spec) where

import Data.IORef
import OpenTelemetry.Exporter.LogRecord
import OpenTelemetry.Internal.Logs.Types (emptyLogRecordArguments)
import OpenTelemetry.Logs.Core
import OpenTelemetry.Processor.Simple.LogRecord
import Test.Hspec


mkCountingExporter :: IO (IORef Int, LogRecordExporter)
mkCountingExporter = do
  exportedCount <- newIORef 0
  shutDown <- newIORef False
  exporter <-
    mkLogRecordExporter $
      LogRecordExporterArguments
        { logRecordExporterArgumentsExport = \logs_ -> do
            isShutdown <- readIORef shutDown
            if isShutdown
              then pure $ Failure Nothing
              else do
                modifyIORef' exportedCount (+ length logs_)
                pure Success
        , logRecordExporterArgumentsForceFlush = pure ()
        , logRecordExporterArgumentsShutdown = writeIORef shutDown True
        }
  pure (exportedCount, exporter)


spec :: Spec
spec = describe "LogRecordProcessor" $ do
  it "simple processor exports emitted records" $ do
    (countRef, exporter) <- mkCountingExporter
    processor <- simpleProcessor exporter
    let provider = createLoggerProvider [processor] emptyLoggerProviderOptions
        logger = makeLogger provider "spec"
    _ <- emitLogRecord logger emptyLogRecordArguments
    _ <- emitLogRecord logger emptyLogRecordArguments
    _ <- forceFlushLoggerProvider provider Nothing
    readIORef countRef `shouldReturn` 2

  it "simple processor shuts down and stops exporting" $ do
    (countRef, exporter) <- mkCountingExporter
    processor <- simpleProcessor exporter
    let provider = createLoggerProvider [processor] emptyLoggerProviderOptions
        logger = makeLogger provider "spec"
    _ <- emitLogRecord logger emptyLogRecordArguments
    shutdownLoggerProvider provider
    _ <- emitLogRecord logger emptyLogRecordArguments
    _ <- forceFlushLoggerProvider provider Nothing
    readIORef countRef `shouldReturn` 1
