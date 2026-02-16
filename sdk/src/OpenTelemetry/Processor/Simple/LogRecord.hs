{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}

module OpenTelemetry.Processor.Simple.LogRecord (
  simpleProcessor,
) where

import Control.Concurrent.Async
import Control.Concurrent.Chan.Unagi
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forever, unless)
import qualified Data.Vector as V
import OpenTelemetry.Exporter.LogRecord
import OpenTelemetry.Internal.Logs.Types (ReadableLogRecord, mkReadableLogRecord)
import OpenTelemetry.Processor.LogRecord


-- | A simple processor that exports each log record as soon as it is emitted.
simpleProcessor :: LogRecordExporter -> IO LogRecordProcessor
simpleProcessor exporter = do
  (inChan :: InChan ReadableLogRecord, outChan :: OutChan ReadableLogRecord) <- newChan
  isShuttingDown <- newTVarIO False
  worker <- async $ forever $ do
    lr <- readChan outChan
    _ <- logRecordExporterExport exporter (V.singleton lr)
    pure ()

  let flushPending = do
        (Element m, _) <- tryReadChan outChan
        mLog <- m
        case mLog of
          Nothing -> pure ()
          Just lr -> do
            _ <- logRecordExporterExport exporter (V.singleton lr)
            flushPending

  pure $
    LogRecordProcessor
      { logRecordProcessorOnEmit = \lr _ -> do
          shuttingDown <- readTVarIO isShuttingDown
          unless shuttingDown $ writeChan inChan (mkReadableLogRecord lr)
      , logRecordProcessorForceFlush = do
          flushPending
          logRecordExporterForceFlush exporter
      , logRecordProcessorShutdown = async $ mask $ \restore -> do
          atomically $ writeTVar isShuttingDown True
          cancel worker
          result <- try $ restore (flushPending >> logRecordExporterShutdown exporter)
          pure $
            case result of
              Left (_ :: SomeException) -> ShutdownFailure
              Right () -> ShutdownSuccess
      }
