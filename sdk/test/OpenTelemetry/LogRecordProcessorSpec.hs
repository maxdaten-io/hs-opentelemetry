{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module OpenTelemetry.LogRecordProcessorSpec (spec) where

import Control.Concurrent (threadDelay)
import qualified Data.HashMap.Strict as HashMap
import Data.IORef
import OpenTelemetry.Exporter.LogRecord
import OpenTelemetry.Internal.Common.Types (FlushResult (..))
import OpenTelemetry.Internal.Logs.Types (LogRecordProcessor (..), emptyLogRecordArguments)
import qualified OpenTelemetry.LogAttributes as LA
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


mkBaseProcessor :: IO LogRecordProcessor
mkBaseProcessor = do
  exporter <-
    mkLogRecordExporter $
      LogRecordExporterArguments
        { logRecordExporterArgumentsExport = \_ -> pure Success
        , logRecordExporterArgumentsForceFlush = pure ()
        , logRecordExporterArgumentsShutdown = pure ()
        }
  simpleProcessor exporter


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

  it "force flush delegates to all registered processors" $ do
    flushCountRef1 <- newIORef (0 :: Int)
    flushCountRef2 <- newIORef (0 :: Int)
    base1 <- mkBaseProcessor
    base2 <- mkBaseProcessor
    let processor1 =
          base1
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = modifyIORef' flushCountRef1 (+ 1)
            }
        processor2 =
          base2
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = modifyIORef' flushCountRef2 (+ 1)
            }
        provider = createLoggerProvider [processor1, processor2] emptyLoggerProviderOptions

    result <- forceFlushLoggerProvider provider Nothing
    result `shouldSatisfy` isFlushSuccess
    readIORef flushCountRef1 `shouldReturn` 1
    readIORef flushCountRef2 `shouldReturn` 1

  it "shutdown delegates to all registered processors" $ do
    shutdownCountRef1 <- newIORef (0 :: Int)
    shutdownCountRef2 <- newIORef (0 :: Int)
    base1 <- mkBaseProcessor
    base2 <- mkBaseProcessor
    let processor1 =
          base1
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = pure ()
            , logRecordProcessorShutdown = do
                modifyIORef' shutdownCountRef1 (+ 1)
                logRecordProcessorShutdown base1
            }
        processor2 =
          base2
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = pure ()
            , logRecordProcessorShutdown = do
                modifyIORef' shutdownCountRef2 (+ 1)
                logRecordProcessorShutdown base2
            }
        provider = createLoggerProvider [processor1, processor2] emptyLoggerProviderOptions

    shutdownLoggerProvider provider
    readIORef shutdownCountRef1 `shouldReturn` 1
    readIORef shutdownCountRef2 `shouldReturn` 1

  it "reports force flush timeout when processors do not complete in time" $ do
    base <- mkBaseProcessor
    let slowProcessor =
          base
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = threadDelay 200000
            }
        provider = createLoggerProvider [slowProcessor] emptyLoggerProviderOptions

    result <- forceFlushLoggerProvider provider (Just 10000)
    result `shouldSatisfy` isFlushTimeout

  it "reports force flush error when processor force flush throws" $ do
    base <- mkBaseProcessor
    let failingProcessor =
          base
            { logRecordProcessorOnEmit = \_ _ -> pure ()
            , logRecordProcessorForceFlush = error "boom"
            }
        provider = createLoggerProvider [failingProcessor] emptyLoggerProviderOptions

    result <- forceFlushLoggerProvider provider Nothing
    result `shouldSatisfy` isFlushError

  it "propagates log record mutations to subsequently registered processors" $ do
    sawMutationRef <- newIORef False
    base1 <- mkBaseProcessor
    base2 <- mkBaseProcessor
    let firstProcessor =
          base1
            { logRecordProcessorOnEmit = \lr _ -> addAttribute lr "processor.step" ("first" :: LA.AnyValue)
            , logRecordProcessorForceFlush = pure ()
            }
        secondProcessor =
          base2
            { logRecordProcessorOnEmit = \lr _ -> do
                (_, attrs) <- LA.getAttributeMap <$> logRecordGetAttributes lr
                writeIORef sawMutationRef (HashMap.lookup "processor.step" attrs == Just ("first" :: LA.AnyValue))
            , logRecordProcessorForceFlush = pure ()
            }
        provider = createLoggerProvider [firstProcessor, secondProcessor] emptyLoggerProviderOptions
        logger = makeLogger provider "spec.processor.chain"

    _ <- emitLogRecord logger emptyLogRecordArguments
    readIORef sawMutationRef `shouldReturn` True


isFlushSuccess :: FlushResult -> Bool
isFlushSuccess FlushSuccess = True
isFlushSuccess _ = False


isFlushTimeout :: FlushResult -> Bool
isFlushTimeout FlushTimeout = True
isFlushTimeout _ = False


isFlushError :: FlushResult -> Bool
isFlushError FlushError = True
isFlushError _ = False
