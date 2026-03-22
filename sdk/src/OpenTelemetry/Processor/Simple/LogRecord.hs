{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module OpenTelemetry.Processor.Simple.LogRecord (
  simpleProcessor,
) where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (unless)
import qualified Data.Vector as V
import OpenTelemetry.Exporter.LogRecord
import OpenTelemetry.Internal.Logs.Types (ReadableLogRecord, mkReadableLogRecord)
import OpenTelemetry.Processor.LogRecord


-- | A simple processor that exports each log record as soon as it is emitted.
simpleProcessor :: LogRecordExporter -> IO LogRecordProcessor
simpleProcessor exporter = do
  isShuttingDown <- newTVarIO False
  pure $
    LogRecordProcessor
      { logRecordProcessorOnEmit = \lr _ -> do
          shuttingDown <- readTVarIO isShuttingDown
          unless shuttingDown $ do
            let readableLogRecord :: ReadableLogRecord
                readableLogRecord = mkReadableLogRecord lr
            _ <- logRecordExporterExport exporter (V.singleton readableLogRecord)
            pure ()
      , logRecordProcessorForceFlush = logRecordExporterForceFlush exporter
      , logRecordProcessorShutdown = async $ mask $ \restore -> do
          atomically $ writeTVar isShuttingDown True
          result <- try $ restore $ logRecordExporterShutdown exporter
          pure $
            case result of
              Left (_ :: SomeException) -> ShutdownFailure
              Right () -> ShutdownSuccess
      }
