## 0.1.1

- OtlpExporter: separate `logsUrl` / `tracesUrl` and `logs` / `traces` toggles, so
  you can send traces straight to Grafana Tempo (traces-only) and logs to Loki,
  instead of requiring one all-in-one OTLP endpoint.

## 0.1.0

- Initial release: neutral Signal model, pluggable Exporter interface, pipeline
  (batching, head sampling, retry, bounded offline queue).
- Exporters: HttpJson, OTLP/HTTP (logs + traces), Console.
- Sentry-shaped API: event, captureError, addBreadcrumb, startSpan, counter.
- Flutter error capture (installErrorHandlers, runGuarded) + flutter_patcher bridge.
