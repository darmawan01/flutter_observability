import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exporter.dart';
import '../resource.dart';
import '../signal.dart';

/// Exports signals as OpenTelemetry (OTLP/HTTP + JSON). Non-span signals become
/// **logs**; spans become **traces**.
///
/// Point it at any OTLP receiver:
/// * an all-in-one `endpoint` (an OTel Collector / Grafana Alloy / otel-lgtm) —
///   logs go to `<endpoint>/v1/logs`, traces to `<endpoint>/v1/traces`; or
/// * **separate** receivers via [logsUrl] / [tracesUrl] (e.g. traces straight to
///   Grafana **Tempo**'s OTLP endpoint, logs to **Loki**'s `/otlp/v1/logs`).
///
/// Set [logs] or [traces] to false to disable a signal class (e.g. traces-only
/// into Tempo so it doesn't try to POST logs).
class OtlpExporter extends Exporter {
  final String? logsUrl;
  final String? tracesUrl;
  final Map<String, String> headers;
  final Duration timeout;
  final String scopeName;
  final http.Client _client;
  final bool _ownsClient;

  OtlpExporter({
    String? endpoint,
    String? logsUrl,
    String? tracesUrl,
    bool logs = true,
    bool traces = true,
    Map<String, String>? headers,
    this.timeout = const Duration(seconds: 10),
    this.scopeName = 'flutter_observability',
    http.Client? client,
  })  : logsUrl = _resolve(logs, logsUrl, endpoint, '/v1/logs'),
        tracesUrl = _resolve(traces, tracesUrl, endpoint, '/v1/traces'),
        headers = {'content-type': 'application/json', ...?headers},
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  static String? _resolve(bool enabled, String? explicit, String? base, String path) {
    if (!enabled) return null;
    if (explicit != null) return explicit;
    if (base != null) return '${base.replaceAll(RegExp(r'/+$'), '')}$path';
    return null;
  }

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    final logSignals = batch.where((s) => s.kind != SignalKind.span).toList(growable: false);
    final spanSignals = batch.where((s) => s.kind == SignalKind.span).toList(growable: false);
    var ok = true;
    if (logsUrl != null && logSignals.isNotEmpty) {
      ok = await _post(logsUrl!, buildLogsPayload(logSignals, resource)) && ok;
    }
    if (tracesUrl != null && spanSignals.isNotEmpty) {
      ok = await _post(tracesUrl!, buildTracesPayload(spanSignals, resource)) && ok;
    }
    return ok;
  }

  Future<bool> _post(String url, Map<String, Object?> payload) async {
    try {
      final res = await _client.post(Uri.parse(url), headers: headers, body: jsonEncode(payload)).timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  // ---- Pure OTLP/JSON builders (unit-testable) ----------------------------

  Map<String, Object?> buildLogsPayload(List<Signal> logs, Resource resource) => {
        'resourceLogs': [
          {
            'resource': {'attributes': _attrs(resource.attributes)},
            'scopeLogs': [
              {
                'scope': {'name': scopeName},
                'logRecords': logs.map(_logRecord).toList(),
              }
            ],
          }
        ],
      };

  Map<String, Object?> buildTracesPayload(List<Signal> spans, Resource resource) => {
        'resourceSpans': [
          {
            'resource': {'attributes': _attrs(resource.attributes)},
            'scopeSpans': [
              {
                'scope': {'name': scopeName},
                'spans': spans.map(_span).toList(),
              }
            ],
          }
        ],
      };

  Map<String, Object?> _logRecord(Signal s) {
    final attrs = <String, Object?>{...s.attributes};
    if (s.error != null) attrs['exception.message'] = s.error.toString();
    if (s.stackTrace != null) attrs['exception.stacktrace'] = s.stackTrace.toString();
    if (s.value != null) attrs['metric.value'] = s.value;
    attrs['signal.kind'] = s.kind.name;
    return {
      'timeUnixNano': _nanos(s.timestamp),
      'severityNumber': _severityNumber(s.severity),
      'severityText': s.severity.name.toUpperCase(),
      'body': {'stringValue': s.name},
      'attributes': _attrs(attrs),
      if (s.traceId != null) 'traceId': s.traceId,
      if (s.spanId != null) 'spanId': s.spanId,
    };
  }

  Map<String, Object?> _span(Signal s) => {
        'traceId': s.traceId,
        'spanId': s.spanId,
        if (s.parentSpanId != null) 'parentSpanId': s.parentSpanId,
        'name': s.name,
        'kind': 1, // SPAN_KIND_INTERNAL
        'startTimeUnixNano': _nanos(s.timestamp),
        'endTimeUnixNano': _nanos(s.endTimestamp ?? s.timestamp),
        'attributes': _attrs(s.attributes),
        'status': {'code': s.ok == false ? 2 : 1}, // ERROR : OK
      };

  static String _nanos(DateTime t) => (t.microsecondsSinceEpoch * 1000).toString();

  static int _severityNumber(Severity s) => switch (s) {
        Severity.trace => 1,
        Severity.debug => 5,
        Severity.info => 9,
        Severity.warn => 13,
        Severity.error => 17,
        Severity.fatal => 21,
      };

  static List<Map<String, Object?>> _attrs(Map<String, Object?> m) =>
      m.entries.map((e) => {'key': e.key, 'value': _anyValue(e.value)}).toList();

  static Map<String, Object?> _anyValue(Object? v) => switch (v) {
        null => {'stringValue': ''},
        bool b => {'boolValue': b},
        int i => {'intValue': i.toString()},
        double d => {'doubleValue': d},
        String s => {'stringValue': s},
        _ => {'stringValue': v.toString()},
      };

  @override
  Future<void> shutdown() async {
    if (_ownsClient) _client.close();
  }
}
