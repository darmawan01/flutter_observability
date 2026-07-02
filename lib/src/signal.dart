/// Severity level, aligned with OpenTelemetry's log severity buckets.
enum Severity { trace, debug, info, warn, error, fatal }

/// The kind of thing being reported.
enum SignalKind {
  /// A structured event ("patch.applied", "checkout.completed").
  event,

  /// An error/exception, optionally with a stack trace.
  error,

  /// A lightweight trail entry leading up to an error (Sentry-style).
  breadcrumb,

  /// A numeric measurement to aggregate (a counter increment).
  counter,

  /// A completed span (a timed operation with start + end).
  span,
}

/// A single backend-agnostic observability signal. Producers create these; the
/// pipeline batches them; exporters translate them to a wire format. This is the
/// neutral currency between "instrument once" and "send anywhere".
class Signal {
  final SignalKind kind;
  final String name;
  final Severity severity;

  /// Event/error time, or the span's start time.
  final DateTime timestamp;

  /// Span end time (span signals only).
  final DateTime? endTimestamp;

  /// Structured key/value context. Prefer flat, low-cardinality-ish keys.
  final Map<String, Object?> attributes;

  /// Trace correlation (hex). Set for spans and for signals emitted inside one.
  final String? traceId;
  final String? spanId;
  final String? parentSpanId;

  /// Span outcome (span signals): true = ok, false = error.
  final bool? ok;

  /// Counter increment (counter signals).
  final num? value;

  /// Error payload (error signals).
  final Object? error;
  final StackTrace? stackTrace;

  Signal({
    required this.kind,
    required this.name,
    required this.timestamp,
    this.severity = Severity.info,
    this.endTimestamp,
    Map<String, Object?>? attributes,
    this.traceId,
    this.spanId,
    this.parentSpanId,
    this.ok,
    this.value,
    this.error,
    this.stackTrace,
  }) : attributes = attributes ?? const {};

  /// Rebuild a signal from [toJson] output. Used by a persistent [QueueStore] to
  /// restore the offline buffer after an app restart.
  ///
  /// Note: [error] comes back as its string form and [stackTrace] is dropped —
  /// only [toJson] survives a round-trip, which is all the exporters read. The
  /// error's text is preserved in the [error] string.
  factory Signal.fromJson(Map<String, Object?> json) {
    final attrs = json['attributes'];
    return Signal(
      kind: SignalKind.values.byName(json['kind'] as String),
      name: (json['name'] as String?) ?? '',
      severity: Severity.values.byName((json['severity'] as String?) ?? 'info'),
      timestamp: _timeFromNano(json['timeUnixNano']),
      endTimestamp: json['endTimeUnixNano'] == null ? null : _timeFromNano(json['endTimeUnixNano']),
      attributes: attrs is Map ? Map<String, Object?>.from(attrs) : null,
      traceId: json['traceId'] as String?,
      spanId: json['spanId'] as String?,
      parentSpanId: json['parentSpanId'] as String?,
      ok: json['ok'] as bool?,
      value: json['value'] as num?,
      error: json['error'],
    );
  }

  static DateTime _timeFromNano(Object? nano) =>
      DateTime.fromMicrosecondsSinceEpoch(((nano as num?)?.toInt() ?? 0) ~/ 1000);

  /// Neutral JSON — used by the HTTP-JSON exporter, the persistent queue, and
  /// easy to eyeball in logs. Round-trips through [Signal.fromJson].
  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'name': name,
        'severity': severity.name,
        'timeUnixNano': timestamp.microsecondsSinceEpoch * 1000,
        if (endTimestamp != null) 'endTimeUnixNano': endTimestamp!.microsecondsSinceEpoch * 1000,
        if (attributes.isNotEmpty) 'attributes': attributes,
        if (traceId != null) 'traceId': traceId,
        if (spanId != null) 'spanId': spanId,
        if (parentSpanId != null) 'parentSpanId': parentSpanId,
        if (ok != null) 'ok': ok,
        if (value != null) 'value': value,
        if (error != null) 'error': error.toString(),
        if (stackTrace != null) 'stackTrace': stackTrace.toString(),
      };
}
