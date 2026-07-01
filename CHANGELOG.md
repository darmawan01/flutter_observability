## 0.1.0

- Initial release: neutral Signal model, pluggable Exporter interface, pipeline
  (batching, head sampling, retry, bounded offline queue).
- Exporters: HttpJson, OTLP/HTTP (logs + traces), Console.
- Sentry-shaped API: event, captureError, addBreadcrumb, startSpan, counter.
- Flutter error capture (installErrorHandlers, runGuarded) + flutter_patcher bridge.
