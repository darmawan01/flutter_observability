/// Generic, backend-agnostic observability for Flutter.
///
/// Instrument once through a familiar API (`event`, `captureError`,
/// `addBreadcrumb`, `startSpan`, `counter`); send anywhere through pluggable
/// [Exporter]s. Ships an [HttpJsonExporter] (any JSON endpoint), an
/// [OtlpExporter] (OpenTelemetry → Grafana / SigNoz / any OTel backend), and a
/// [ConsoleExporter]. Batching, sampling, retry, and a bounded offline queue are
/// handled for you.
library;

export 'src/observability.dart';
export 'src/span.dart';
export 'src/signal.dart' show Signal, SignalKind, Severity;
export 'src/resource.dart';
export 'src/exporter.dart';
export 'src/exporters/console_exporter.dart';
export 'src/exporters/http_json_exporter.dart';
export 'src/exporters/otlp_exporter.dart';
export 'src/sources/patch_source.dart';
