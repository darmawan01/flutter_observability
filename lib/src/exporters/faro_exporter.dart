import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exporter.dart';
import '../resource.dart';
import '../signal.dart';

/// Ships signals to a **Grafana Faro** receiver (Grafana Alloy's `faro.receiver`
/// or Grafana Cloud Frontend Observability).
///
/// Point it at the collect URL — for Grafana Cloud that's
/// `https://faro-collector-<region>.grafana.net/collect/<app-key>` (the app key
/// is in the path); for self-hosted Alloy it's your `faro.receiver` endpoint.
///
/// Mapping onto the Faro payload (`{ meta, exceptions, logs, measurements,
/// events }`): **errors → exceptions**, **counters → measurements**,
/// **events → events**, **breadcrumbs → logs**. Spans are skipped (Faro traces
/// are full OTLP `resourceSpans` — use the [OtlpExporter] for those). `meta.app`
/// is filled from the [Resource] (`service.name` → name, `service.version` →
/// version, `deployment.environment` → environment, `service.instance.id` →
/// session id); overridable.
///
/// Note: Dart stack traces are attached as raw text under an exception's
/// `context.stacktrace` rather than parsed into Faro frames.
class FaroExporter extends Exporter {
  final String url;
  final String? appName;
  final String? namespace;
  final String? environment;
  final String? release;
  final String? sessionId;
  final Duration timeout;
  final Map<String, String> headers;
  final http.Client _client;
  final bool _ownsClient;

  static const _sdk = {'name': 'flutter_observability', 'version': '0.1'};

  FaroExporter({
    required this.url,
    this.appName,
    this.namespace,
    this.environment,
    this.release,
    this.sessionId,
    String? apiKey,
    this.timeout = const Duration(seconds: 10),
    Map<String, String>? headers,
    http.Client? client,
  })  : headers = {
          'content-type': 'application/json',
          if (apiKey != null) 'x-api-key': apiKey,
          ...?headers,
        },
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    final mappable = batch.where((s) => s.kind != SignalKind.span).toList(growable: false);
    if (mappable.isEmpty) return true; // only spans — nothing for Faro
    try {
      final res = await _client
          .post(Uri.parse(url), headers: headers, body: jsonEncode(buildBody(mappable, resource)))
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Build the Faro `TransportBody` for [signals] (pure, testable). Only the
  /// non-empty signal classes are included; `meta` is always present.
  Map<String, Object?> buildBody(List<Signal> signals, Resource resource) {
    final exceptions = <Map<String, Object?>>[];
    final logs = <Map<String, Object?>>[];
    final events = <Map<String, Object?>>[];
    final measurements = <Map<String, Object?>>[];

    for (final s in signals) {
      final ts = s.timestamp.toUtc().toIso8601String();
      final trace = s.traceId == null ? null : {'trace_id': s.traceId, 'span_id': s.spanId ?? ''};
      switch (s.kind) {
        case SignalKind.error:
          final ctx = _stringMap(s.attributes);
          if (s.stackTrace != null) ctx['stacktrace'] = s.stackTrace.toString();
          exceptions.add({
            'timestamp': ts,
            'type': s.name,
            'value': s.error?.toString() ?? s.name,
            if (s.severity == Severity.fatal) 'fatal': true,
            if (ctx.isNotEmpty) 'context': ctx,
            if (trace != null) 'trace': trace,
          });
        case SignalKind.counter:
          measurements.add({
            'type': s.name,
            'values': {s.name: s.value ?? 1},
            'timestamp': ts,
            if (s.attributes.isNotEmpty) 'context': _stringMap(s.attributes),
            if (trace != null) 'trace': trace,
          });
        case SignalKind.event:
          events.add({
            'name': s.name,
            'timestamp': ts,
            if (s.attributes.isNotEmpty) 'attributes': _stringMap(s.attributes),
            if (trace != null) 'trace': trace,
          });
        case SignalKind.breadcrumb:
          logs.add({
            'message': s.name,
            'level': _level(s.severity),
            'timestamp': ts,
            if (s.attributes.isNotEmpty) 'context': _stringMap(s.attributes),
            if (trace != null) 'trace': trace,
          });
        case SignalKind.span:
          break; // skipped (see class docs)
      }
    }

    return {
      'meta': _meta(resource),
      if (exceptions.isNotEmpty) 'exceptions': exceptions,
      if (logs.isNotEmpty) 'logs': logs,
      if (events.isNotEmpty) 'events': events,
      if (measurements.isNotEmpty) 'measurements': measurements,
    };
  }

  Map<String, Object?> _meta(Resource resource) {
    final a = resource.attributes;
    final name = appName ?? a['service.name']?.toString();
    final version = release ?? a['service.version']?.toString();
    final env = environment ?? a['deployment.environment']?.toString();
    final sid = sessionId ?? a['service.instance.id']?.toString();
    final app = {
      if (name != null) 'name': name,
      if (version != null) 'version': version,
      if (env != null) 'environment': env,
      if (namespace != null) 'namespace': namespace,
    };
    return {
      if (app.isNotEmpty) 'app': app,
      'sdk': _sdk,
      if (sid != null) 'session': {'id': sid},
    };
  }

  /// Faro contexts/attributes are `Record<string, string>` — stringify values.
  static Map<String, String> _stringMap(Map<String, Object?> m) =>
      m.map((k, v) => MapEntry(k, v?.toString() ?? ''));

  /// Our [Severity] → Faro `LogLevel` (`trace|debug|info|warn|error`; no fatal).
  static String _level(Severity s) => switch (s) {
        Severity.trace => 'trace',
        Severity.debug => 'debug',
        Severity.info => 'info',
        Severity.warn => 'warn',
        Severity.error => 'error',
        Severity.fatal => 'error',
      };

  @override
  Future<void> shutdown() async {
    if (_ownsClient) _client.close();
  }
}
