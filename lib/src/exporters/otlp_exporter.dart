import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exporter.dart';
import '../resource.dart';
import '../signal.dart';

/// Exports signals as OpenTelemetry (OTLP/HTTP + JSON) to any OTel-compatible
/// backend — an OTel Collector, Grafana (Tempo/Loki/Mimir), SigNoz, Datadog,
/// Honeycomb, … Non-span signals become **logs**; spans become **traces**.
///
/// [endpoint] is the OTLP base (e.g. `http://collector:4318` or a Grafana Cloud
/// OTLP URL); logs go to `<base>/v1/logs`, traces to `<base>/v1/traces`.
class OtlpExporter extends Exporter {
  final String endpoint;
  final Map<String, String> headers;
  final Duration timeout;
  final String scopeName;
  final http.Client _client;
  final bool _ownsClient;

  OtlpExporter({
    required String endpoint,
    Map<String, String>? headers,
    this.timeout = const Duration(seconds: 10),
    this.scopeName = 'flutter_observability',
    http.Client? client,
  })  : endpoint = endpoint.replaceAll(RegExp(r'/+$'), ''),
        headers = {'content-type': 'application/json', ...?headers},
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    final logs = batch.where((s) => s.kind != SignalKind.span).toList(growable: false);
    final spans = batch.where((s) => s.kind == SignalKind.span).toList(growable: false);
    var ok = true;
    if (logs.isNotEmpty) ok = await _post('/v1/logs', buildLogsPayload(logs, resource)) && ok;
    if (spans.isNotEmpty) ok = await _post('/v1/traces', buildTracesPayload(spans, resource)) && ok;
    return ok;
  }

  Future<bool> _post(String path, Map<String, Object?> payload) async {
    try {
      final res = await _client
          .post(Uri.parse('$endpoint$path'), headers: headers, body: jsonEncode(payload))
          .timeout(timeout);
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
