import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'exporter.dart';
import 'ids.dart';
import 'pipeline.dart';
import 'queue/queue_store.dart';
import 'resource.dart';
import 'signal.dart';
import 'span.dart';

/// The facade. Instrument through a familiar (Sentry-shaped) API — `event`,
/// `captureError`, `addBreadcrumb`, `startSpan`, `counter` — and the pluggable
/// exporters decide where it goes. Producers never know the backend.
class Observability {
  static Observability? _instance;

  /// The initialised instance. Throws if [init] hasn't run.
  static Observability get instance =>
      _instance ?? (throw StateError('Observability.init() has not been called'));
  static bool get isInitialized => _instance != null;

  final Resource resource;
  final Pipeline pipeline;

  /// 0..1. Non-error signals are dropped at this rate. Errors are never sampled.
  final double sampleRate;

  /// Master switch (privacy opt-out). When false, nothing is recorded.
  bool enabled;

  final Random _rng = Random();

  Observability._(this.resource, this.pipeline, this.sampleRate, this.enabled);

  /// Initialise the singleton.
  ///
  /// [exporters] decide where signals go; [sampleRate] head-samples non-error
  /// signals; batching/flushing are tuned via [batchSize], [maxQueue], and
  /// [flushInterval].
  ///
  /// [queueStore] chooses how the offline buffer is persisted. Defaults to an
  /// in-memory store (nothing survives a restart). Pass a persistent
  /// [QueueStore] — e.g. a shared_preferences or sqlite adapter (see
  /// `example/shared_prefs_queue_store.dart`) — so signals buffered offline
  /// outlive an app kill. Persisted signals are restored (and flushed first) on
  /// the next `init`.
  static Future<Observability> init({
    required Resource resource,
    required List<Exporter> exporters,
    double sampleRate = 1.0,
    bool enabled = true,
    int batchSize = 50,
    int maxQueue = 1000,
    Duration flushInterval = const Duration(seconds: 10),
    void Function(String message)? onDebug,
    QueueStore? queueStore,
  }) async {
    final pipeline = Pipeline(
      exporters: exporters,
      resource: resource,
      batchSize: batchSize,
      maxQueue: maxQueue,
      flushInterval: flushInterval,
      onDebug: onDebug,
      store: queueStore,
    );
    // Restore any signals a previous run persisted (no-op for the in-memory
    // default) before we start producing new ones.
    await pipeline.restore();
    return _instance = Observability._(resource, pipeline, sampleRate.clamp(0.0, 1.0).toDouble(), enabled);
  }

  void _emit(Signal s) {
    if (!enabled) return;
    // Errors are always kept; everything else is subject to head sampling.
    if (s.kind != SignalKind.error && sampleRate < 1.0 && _rng.nextDouble() > sampleRate) {
      return;
    }
    pipeline.add(s);
  }

  /// A structured event, e.g. `event('patch.applied', attributes: {...})`.
  void event(String name, {Map<String, Object?>? attributes, Severity severity = Severity.info}) {
    _emit(Signal(kind: SignalKind.event, name: name, timestamp: DateTime.now(), severity: severity, attributes: attributes));
  }

  /// A trail entry leading up to an error.
  void addBreadcrumb(String message, {Map<String, Object?>? attributes}) {
    _emit(Signal(kind: SignalKind.breadcrumb, name: message, timestamp: DateTime.now(), severity: Severity.debug, attributes: attributes));
  }

  /// Report an error/exception (never sampled out).
  void captureError(Object error, {StackTrace? stackTrace, Map<String, Object?>? attributes, bool fatal = false}) {
    _emit(Signal(
      kind: SignalKind.error,
      name: error.runtimeType.toString(),
      timestamp: DateTime.now(),
      severity: fatal ? Severity.fatal : Severity.error,
      attributes: attributes,
      error: error,
      stackTrace: stackTrace,
    ));
  }

  /// Increment a counter metric.
  void counter(String name, {num value = 1, Map<String, Object?>? attributes}) {
    _emit(Signal(kind: SignalKind.counter, name: name, timestamp: DateTime.now(), value: value, attributes: attributes));
  }

  /// Start a span. Pass [parent] to nest under an existing trace.
  Span startSpan(String name, {Map<String, Object?>? attributes, Span? parent}) {
    return Span.internal(
      this,
      name: name,
      traceId: parent?.traceId ?? newTraceId(),
      spanId: newSpanId(),
      parentSpanId: parent?.spanId,
      attributes: attributes,
    );
  }

  /// Time an async operation as a span. Returns [body]'s result; on throw it
  /// marks the span errored and rethrows. Convenience over [startSpan] +
  /// [Span.end] — slow operations surface as span latency in your backend.
  ///
  /// ```dart
  /// final rows = await Observability.instance.trace('db.query', () => db.query(sql));
  /// ```
  Future<T> trace<T>(
    String name,
    Future<T> Function() body, {
    Map<String, Object?>? attributes,
    Span? parent,
  }) async {
    final span = startSpan(name, attributes: attributes, parent: parent);
    try {
      final result = await body();
      span.end();
      return result;
    } catch (e) {
      span.end(ok: false, attributes: {'error': e.toString()});
      rethrow;
    }
  }

  /// Called by [Span.end]; not for direct use.
  void recordSpan(Span span, {required bool ok, required DateTime end}) {
    _emit(Signal(
      kind: SignalKind.span,
      name: span.name,
      timestamp: span.start,
      endTimestamp: end,
      severity: ok ? Severity.info : Severity.error,
      attributes: span.attributes,
      traceId: span.traceId,
      spanId: span.spanId,
      parentSpanId: span.parentSpanId,
      ok: ok,
    ));
  }

  /// Wire Flutter's error channels into `captureError`. Call once, after [init].
  void installErrorHandlers() {
    final priorFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      captureError(details.exception, stackTrace: details.stack, attributes: {
        if (details.library != null) 'flutter.library': details.library,
        if (details.context != null) 'flutter.context': details.context.toString(),
      });
      (priorFlutter ?? FlutterError.presentError)(details);
    };
    final priorPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      captureError(error, stackTrace: stack, fatal: true);
      return priorPlatform?.call(error, stack) ?? false;
    };
  }

  Future<void> flush() => pipeline.flush();

  Future<void> shutdown() async {
    await pipeline.shutdown();
    if (identical(_instance, this)) _instance = null;
  }

  /// Run [body] inside a guarded zone so uncaught async errors are captured.
  /// The recommended entrypoint wrapper (see README).
  static Future<void> runGuarded(FutureOr<void> Function() body) {
    final completer = Completer<void>();
    runZonedGuarded(() async {
      try {
        await body();
        if (!completer.isCompleted) completer.complete();
      } catch (e, s) {
        if (isInitialized) instance.captureError(e, stackTrace: s, fatal: true);
        if (!completer.isCompleted) completer.complete();
      }
    }, (error, stack) {
      if (isInitialized) instance.captureError(error, stackTrace: stack, fatal: true);
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }
}
