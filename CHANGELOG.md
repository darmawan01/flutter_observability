## 0.2.0

- `Observability.trace(name, body)`: time an async operation as a span — slow
  operations surface as span latency in your backend, without manual
  `startSpan`/`end` bookkeeping.
- `HttpJsonExporter(headersProvider: ...)`: resolve headers fresh on every export,
  so a rotating auth token stays valid without wrapping a custom `http.Client`.
- `Span.traceparent`: the span as a W3C `traceparent` header value
  (`00-<trace>-<span>-01`) — inject it into outbound requests for end-to-end
  distributed traces that a backend continues.
- `ObservabilityRouteObserver`: a drop-in `NavigatorObserver` that records a
  screen-view event per named-route push/pop/replace.
- `Redactor`: pure, reusable PII/secret scrubbing (Bearer/Basic auth, password/
  token/api_key, email, phone) with an overridable pattern map — scrub attributes
  before they leave the device.

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
