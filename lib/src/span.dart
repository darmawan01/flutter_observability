import 'observability.dart';

/// A timed operation. Start one, do work, `end()` it — the SDK records a single
/// span signal (start + end + status + attributes), correlated by trace id.
class Span {
  final Observability _obs;
  final String name;
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final DateTime start;
  final Map<String, Object?> attributes;
  bool _ended = false;

  Span.internal(
    this._obs, {
    required this.name,
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    Map<String, Object?>? attributes,
  })  : start = DateTime.now(),
        attributes = {...?attributes};

  void setAttribute(String key, Object? value) => attributes[key] = value;

  /// This span as a W3C `traceparent` header value: `00-<traceId>-<spanId>-01`.
  /// Inject it into an outbound request so the backend continues this trace,
  /// stitching client and server spans into one distributed trace.
  String get traceparent => '00-$traceId-$spanId-01';

  /// Complete the span. [ok] false marks it errored. Idempotent.
  void end({bool ok = true, Map<String, Object?>? attributes}) {
    if (_ended) return;
    _ended = true;
    if (attributes != null) this.attributes.addAll(attributes);
    _obs.recordSpan(this, ok: ok, end: DateTime.now());
  }
}
