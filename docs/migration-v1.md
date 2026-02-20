# Migration Guide: v1 Breaking Cut

This guide summarizes the major API and behavior changes for the v1 signal
integration cut (traces + logs + metrics).

## Scope

- Existing trace APIs remain available, but shared SDK lifecycle behavior is
  stricter around shutdown/flush execution.
- Logs move from partial/stub support to full SDK + OTLP pipeline.
- Metrics are now first-class across API, SDK, and OTLP exporter packages.

## Trace and Log Breakpoints

1. Provider lifecycle semantics are strict.
   - `shutdown*Provider` is terminal for the provider pipeline.
   - `forceFlush*Provider` delegates through configured processors/exporters
     with deterministic completion behavior.
2. Log processing/export is now explicit and mandatory in shutdown/flush paths.
   - Simple and batch processors both participate in lifecycle hooks.
   - OTLP log exporter behavior follows retry/timeout policy used in the OTLP stack.
3. OTLP configuration is signal-aware.
   - Signal-specific values (`*_TRACES_*`, `*_LOGS_*`, `*_METRICS_*`) take
     precedence over generic `OTEL_EXPORTER_OTLP_*` values.

## Metrics Adoption Path

1. Initialize meter provider from SDK:
   - `OpenTelemetry.Metrics.initializeGlobalMeterProvider`
   - `OpenTelemetry.Metrics.initializeMeterProvider`
2. Create instruments from a meter:
   - `createCounter`
   - `createUpDownCounter`
   - `createHistogram`
   - `createGauge`
   - `createObservableCounter`
   - `createObservableUpDownCounter`
3. Use readers/exporters:
   - Periodic reader for background collection/export.
   - Manual reader for explicit `forceFlush` workflows.
4. Ensure app shutdown calls meter provider shutdown:
   - `shutdownMeterProvider`

## OTLP Env Var Behavior Changes

1. Signal-specific endpoint precedence:
   - `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
   - `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`
   - `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`
   - fallback: `OTEL_EXPORTER_OTLP_ENDPOINT`
2. Signal-specific timeout precedence:
   - `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT`
   - `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT`
   - `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT`
   - fallback: `OTEL_EXPORTER_OTLP_TIMEOUT`
3. Signal-specific headers/compression precedence follows the same pattern.
4. Metrics exporter selection:
   - `OTEL_METRICS_EXPORTER=none` disables metrics reader/exporter wiring.
   - default remains OTLP when unset.

## Practical Migration Checklist

1. Update imports to use `OpenTelemetry.Log` and `OpenTelemetry.Metrics` in
   application initialization paths.
2. Wire provider shutdown for traces, logs, and metrics on process exit.
3. Validate OTLP signal-specific env vars in deploy configuration.
4. Run app-level smoke tests against your collector endpoint with all enabled
   signals.
