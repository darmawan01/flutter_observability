import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exporter.dart';
import '../ids.dart';
import '../resource.dart';
import '../signal.dart';

/// Ships signals to **Sentry** over its envelope ingestion endpoint.
///
/// Point it at a project DSN — the same string you'd give the Sentry SDK:
///
/// ```dart
/// SentryExporter(dsn: 'https://<key>@o0.ingest.sentry.io/<project>')
/// ```
///
/// Mapping: **error** signals become Sentry *exception* events; **event** /
/// **breadcrumb** / log-ish signals become *message* events (severity-mapped).
/// Counters and spans are skipped — metrics belong on the OTLP/metrics path and
/// Sentry performance/transactions are out of scope here. `release` and
/// `environment` default from the [Resource] (`service.version` /
/// `deployment.environment`) and can be overridden.
///
/// Note: Dart stack traces are attached as raw text under `extra.stacktrace`
/// rather than parsed into Sentry frames — the exception still shows, just
/// without per-frame navigation.
class SentryExporter extends Exporter {
  /// The envelope ingestion URL derived from the DSN, e.g.
  /// `https://o0.ingest.sentry.io/api/<project>/envelope/`.
  final String envelopeUrl;

  /// The `X-Sentry-Auth` header value.
  final String authHeader;

  final String dsn;
  final String? environment;
  final String? release;
  final Duration timeout;
  final Map<String, String> extraHeaders;
  final http.Client _client;
  final bool _ownsClient;

  static const _sentryClient = 'flutter_observability/0.1';

  factory SentryExporter({
    required String dsn,
    String? environment,
    String? release,
    Duration timeout = const Duration(seconds: 10),
    Map<String, String>? headers,
    http.Client? client,
  }) {
    final uri = Uri.parse(dsn);
    final publicKey = uri.userInfo.split(':').first; // "key" or "key:secret"
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (publicKey.isEmpty || uri.host.isEmpty || segments.isEmpty) {
      throw ArgumentError.value(dsn, 'dsn', 'not a valid Sentry DSN (expected scheme://key@host/project)');
    }
    final projectId = segments.last;
    final prefix = segments.length > 1 ? '/${segments.sublist(0, segments.length - 1).join('/')}' : '';
    final port = uri.hasPort ? ':${uri.port}' : '';
    final envelopeUrl = '${uri.scheme}://${uri.host}$port$prefix/api/$projectId/envelope/';
    final authHeader = 'Sentry sentry_version=7, sentry_key=$publicKey, sentry_client=$_sentryClient';
    return SentryExporter._(
      dsn: dsn,
      envelopeUrl: envelopeUrl,
      authHeader: authHeader,
      environment: environment,
      release: release,
      timeout: timeout,
      extraHeaders: headers ?? const {},
      client: client ?? http.Client(),
      ownsClient: client == null,
    );
  }

  SentryExporter._({
    required this.dsn,
    required this.envelopeUrl,
    required this.authHeader,
    required this.environment,
    required this.release,
    required this.timeout,
    required this.extraHeaders,
    required http.Client client,
    required bool ownsClient,
  })  : _client = client,
        _ownsClient = ownsClient;

  static bool _mappable(Signal s) =>
      s.kind == SignalKind.error || s.kind == SignalKind.event || s.kind == SignalKind.breadcrumb;

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    final events = batch.where(_mappable).toList(growable: false);
    if (events.isEmpty) return true; // nothing Sentry-shaped in this batch
    try {
      final res = await _client
          .post(
            Uri.parse(envelopeUrl),
            headers: {
              'content-type': 'application/x-sentry-envelope',
              'x-sentry-auth': authHeader,
              ...extraHeaders,
            },
            body: buildEnvelope(events, resource),
          )
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  /// Build the newline-delimited Sentry envelope for [events] (pure, testable).
  /// One `event` item per signal; the DSN rides in the envelope header so the
  /// payload self-authenticates even without the `X-Sentry-Auth` header.
  String buildEnvelope(List<Signal> events, Resource resource) {
    final env = environment ?? resource.attributes['deployment.environment']?.toString();
    final rel = release ?? resource.attributes['service.version']?.toString();
    final service = resource.attributes['service.name']?.toString();

    final sb = StringBuffer()
      ..write(jsonEncode({'sent_at': DateTime.now().toUtc().toIso8601String(), 'dsn': dsn}));
    for (final s in events) {
      sb
        ..write('\n')
        ..write(jsonEncode({'type': 'event', 'content_type': 'application/json'}))
        ..write('\n')
        ..write(jsonEncode(_event(s, env, rel, service)));
    }
    return sb.toString();
  }

  Map<String, Object?> _event(Signal s, String? env, String? rel, String? service) {
    final extra = <String, Object?>{...s.attributes};
    if (s.stackTrace != null) extra['stacktrace'] = s.stackTrace.toString();

    return {
      'event_id': newTraceId(), // 32 hex, no dashes
      'timestamp': s.timestamp.toUtc().toIso8601String(),
      'platform': 'other',
      'level': _level(s.severity),
      if (rel != null) 'release': rel,
      if (env != null) 'environment': env,
      if (s.kind == SignalKind.error)
        'exception': {
          'values': [
            {'type': s.name, 'value': s.error?.toString() ?? s.name},
          ],
        }
      else
        'message': {'formatted': s.name},
      if (extra.isNotEmpty) 'extra': extra,
      if (service != null) 'tags': {'service': service},
      if (s.traceId != null)
        'contexts': {
          'trace': {'trace_id': s.traceId, if (s.spanId != null) 'span_id': s.spanId},
        },
    };
  }

  static String _level(Severity s) => switch (s) {
        Severity.trace => 'debug',
        Severity.debug => 'debug',
        Severity.info => 'info',
        Severity.warn => 'warning',
        Severity.error => 'error',
        Severity.fatal => 'fatal',
      };

  @override
  Future<void> shutdown() async {
    if (_ownsClient) _client.close();
  }
}
