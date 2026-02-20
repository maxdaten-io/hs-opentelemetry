{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module OpenTelemetry.LogSpec (spec) where

import Control.Exception (bracket)
import Data.Foldable (traverse_)
import Data.Functor (void)
import Data.IORef
import Data.Text (Text)
import qualified Data.Vector as Vector
import OpenTelemetry.Attributes (Attributes, addAttribute, defaultAttributeLimits, emptyAttributes, lookupAttribute)
import qualified OpenTelemetry.Attributes as Attr
import OpenTelemetry.Common (Timestamp (..))
import OpenTelemetry.Context.ThreadLocal (getContext)
import qualified OpenTelemetry.Exporter.InMemory.LogRecord as LogExporter
import qualified OpenTelemetry.Exporter.InMemory.Span as SpanExporter
import OpenTelemetry.Exporter.LogRecord
import OpenTelemetry.Internal.Common.Types
import OpenTelemetry.Internal.Logs.Core
import OpenTelemetry.Internal.Logs.Types
import OpenTelemetry.Log
import OpenTelemetry.Processor.Simple.LogRecord (simpleProcessor)
import OpenTelemetry.Resource
import OpenTelemetry.Trace
import System.Clock (Clock (Realtime), getTime)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec


pattern HostName :: Text
pattern HostName = "host.name"


pattern TelemetrySdkLanguage :: Text
pattern TelemetrySdkLanguage = "telemetry.sdk.language"


pattern ExampleName :: Text
pattern ExampleName = "example.name"


pattern ExampleCount :: Text
pattern ExampleCount = "example.count"


withEnvVar :: String -> Maybe String -> IO a -> IO a
withEnvVar key value action = bracket (lookupEnv key) restore $ \_ -> do
  case value of
    Nothing -> unsetEnv key
    Just v -> setEnv key v
  action
  where
    restore Nothing = unsetEnv key
    restore (Just v) = setEnv key v


spec :: Spec
spec = describe "Log" $ do
  describe "LoggerProvider" $ do
    specify "Resource initialization prioritizes user override, then OTEL_RESOURCE_ATTRIBUTES env var" $ do
      let getInitialResourceAttrs :: Resource 'Nothing -> IO Attributes
          getInitialResourceAttrs resource = do
            opts <- snd <$> getLoggerProviderInitializationOptions' resource
            pure . getMaterializedResourcesAttributes $ loggerProviderOptionsResources opts
          shouldHaveAttrPair :: Attributes -> (Text, Attribute) -> Expectation
          shouldHaveAttrPair attrs (k, v) = lookupAttribute attrs k `shouldBe` Just v
      attrsFromEnv <- getInitialResourceAttrs mempty
      traverse_
        (attrsFromEnv `shouldHaveAttrPair`)
        [ (HostName, toAttribute @Text "env_host_name")
        , (TelemetrySdkLanguage, toAttribute @Text "haskell")
        , (ExampleName, toAttribute @Text "env_example_name")
        , -- OTEL_RESOURCE_ATTRIBUTES uses Baggage format, where attribute values are always text
          (ExampleCount, toAttribute @Text "42")
        ]
      attrsFromUser <-
        getInitialResourceAttrs $
          mkResource @'Nothing
            [ HostName .= toAttribute @Text "user_host_name"
            , TelemetrySdkLanguage .= toAttribute @Text "GHC2021"
            , ExampleCount .= toAttribute @Int 11
            ]
      traverse_
        (attrsFromUser `shouldHaveAttrPair`)
        [ (HostName, toAttribute @Text "user_host_name")
        , (TelemetrySdkLanguage, toAttribute @Text "GHC2021")
        , -- No user override for "example.name", so the value from OTEL_RESOURCES_ATTRIBUTES shines through
          (ExampleName, toAttribute @Text "env_example_name")
        , (ExampleCount, toAttribute @Int 11)
        ]

    specify "disables log processors when OTEL_SDK_DISABLED is true" $ do
      withEnvVar "OTEL_SDK_DISABLED" (Just "true") $
        withEnvVar "OTEL_LOGS_EXPORTER" (Just "otlp") $ do
          (processors, _) <- getLoggerProviderInitializationOptions
          length processors `shouldBe` 0
          provider <- initializeLoggerProvider
          let logger = makeLogger provider "disabled.logger"
          void $ emitLogRecord logger emptyLogRecordArguments

  describe "Logger" $ do
    specify "Emit log record outside of a span" $ do
      (processor, logsRef) <- LogExporter.inMemoryListExporter
      setGlobalLoggerProvider $ createLoggerProvider [processor] emptyLoggerProviderOptions
      provider <- getGlobalLoggerProvider
      let logger = makeLogger provider "woo"
      readIORef logsRef `shouldReturn` []
      void $ emitLogRecord logger emptyLogRecordArguments
      emittedLogs <- readIORef logsRef
      emittedLogs `shouldNotBe` []
      length emittedLogs `shouldBe` 1
      let [emittedLog] = emittedLogs
      logRecordTracingDetails emittedLog `shouldBe` Nothing

    specify "Emit log record within a span" $ do
      (logProcessor, logsRef) <- LogExporter.inMemoryListExporter
      (spanProcessor, spansRef) <- SpanExporter.inMemoryListExporter
      setGlobalLoggerProvider $ createLoggerProvider [logProcessor] emptyLoggerProviderOptions
      setGlobalTracerProvider =<< createTracerProvider [spanProcessor] emptyTracerProviderOptions
      loggerProvider <- getGlobalLoggerProvider
      tracerProvider <- getGlobalTracerProvider
      let tracer = makeTracer tracerProvider "woo" tracerOptions
          logger = makeLogger loggerProvider "woo"
      readIORef logsRef `shouldReturn` []
      void . inSpan tracer "mySpan" defaultSpanArguments $
        emitLogRecord logger emptyLogRecordArguments
      emittedLogs <- readIORef logsRef
      emittedLogs `shouldNotBe` []
      length emittedLogs `shouldBe` 1
      let [emittedLog] = emittedLogs
      emittedSpans <- readIORef spansRef
      length emittedSpans `shouldBe` 1
      let [emittedSpan] = emittedSpans
          SpanContext {..} = spanContext emittedSpan
      logRecordTracingDetails emittedLog `shouldBe` Just (traceId, spanId, traceFlags)

    specify "propagates instrumentation scope and resource to emitted records" $ do
      observedRef <- newIORef ([] :: [(InstrumentationLibrary, MaterializedResources)])
      exporter <-
        mkLogRecordExporter $
          LogRecordExporterArguments
            { logRecordExporterArgumentsExport = \records -> do
                let observed =
                      [ (readLogRecordInstrumentationScope record, readLogRecordResource record)
                      | record <- Vector.toList records
                      ]
                modifyIORef' observedRef (reverse observed <>)
                pure Success
            , logRecordExporterArgumentsForceFlush = pure ()
            , logRecordExporterArgumentsShutdown = pure ()
            }
      processor <- simpleProcessor exporter
      let resource =
            materializeResources $
              mkResource @'Nothing
                [ "service.name" .= ("logs-spec" :: Text)
                ]
          opts =
            emptyLoggerProviderOptions
              { loggerProviderOptionsResources = resource
              }
          scope =
            InstrumentationLibrary
              { libraryName = "spec.logs.scope"
              , libraryVersion = "2.4.6"
              , librarySchemaUrl = "https://opentelemetry.io/schemas/2.4.6"
              , libraryAttributes = Attr.addAttribute Attr.defaultAttributeLimits Attr.emptyAttributes "scope.attribute" ("present" :: Text)
              }
          provider = createLoggerProvider [processor] opts
          logger = makeLogger provider scope
      void $ emitLogRecord logger emptyLogRecordArguments

      observed <- readIORef observedRef
      case observed of
        ((seenScope, seenResource) : _) -> do
          seenScope `shouldBe` scope
          lookupAttribute (getMaterializedResourcesAttributes seenResource) "service.name"
            `shouldBe` Just (toAttribute ("logs-spec" :: Text))
        [] -> expectationFailure "expected one observed log record"

    specify "uses explicitly provided context when emitting log records" $ do
      (logProcessor, logsRef) <- LogExporter.inMemoryListExporter
      (spanProcessor, spansRef) <- SpanExporter.inMemoryListExporter
      let loggerProvider = createLoggerProvider [logProcessor] emptyLoggerProviderOptions
      tracerProvider <- createTracerProvider [spanProcessor] emptyTracerProviderOptions
      let tracer = makeTracer tracerProvider "spec.logs.context" tracerOptions
          logger = makeLogger loggerProvider "spec.logs.context"

      contextRef <- newIORef Nothing
      void . inSpan tracer "explicit-context-span" defaultSpanArguments $ do
        ctxt <- getContext
        writeIORef contextRef (Just ctxt)

      Just explicitContext <- readIORef contextRef
      void $ emitLogRecord logger (emptyLogRecordArguments {context = Just explicitContext})

      emittedLogs <- readIORef logsRef
      emittedSpans <- readIORef spansRef
      length emittedLogs `shouldBe` 1
      length emittedSpans `shouldBe` 1
      let [explicitSpan] = emittedSpans
          SpanContext {..} = spanContext explicitSpan
          [emittedLog] = emittedLogs
      logRecordTracingDetails emittedLog `shouldBe` Just (traceId, spanId, traceFlags)

    specify "defaults observed timestamp when not provided" $ do
      (processor, logsRef) <- LogExporter.inMemoryListExporter
      let provider = createLoggerProvider [processor] emptyLoggerProviderOptions
          logger = makeLogger provider "spec.logs.timestamp"
      before <- Timestamp <$> getTime Realtime
      void $ emitLogRecord logger emptyLogRecordArguments
      after <- Timestamp <$> getTime Realtime

      emittedLogs <- readIORef logsRef
      length emittedLogs `shouldBe` 1
      let [emittedLog] = emittedLogs
      logRecordObservedTimestamp emittedLog `shouldSatisfy` (\ts -> ts >= before && ts <= after)
