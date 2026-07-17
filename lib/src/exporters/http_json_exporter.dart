import 'dart:convert';

import 'package:http/http.dart' as http;

import '../exporter.dart';
import '../resource.dart';
import '../signal.dart';

/// Posts a batch as plain JSON: `{ "resource": {...}, "signals": [...] }`.
/// The simplest sink — point it at any endpoint (e.g. an OTA console's
/// `/api/telemetry`). Behaviour-compatible with a hand-rolled POST.
class HttpJsonExporter extends Exporter {
  final Uri endpoint;
  final Map<String, String> headers;

  /// Optional per-request headers, resolved fresh on every export. Use for
  /// values that change over time — e.g. a bearer token that rotates — so you
  /// don't have to bake a stale value into [headers] or wrap a custom [client].
  /// Resolved values are merged over [headers]. If it throws, the batch is
  /// treated as a (retryable) failure.
  final Future<Map<String, String>> Function()? headersProvider;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  HttpJsonExporter({
    required String url,
    Map<String, String>? headers,
    this.headersProvider,
    this.timeout = const Duration(seconds: 10),
    http.Client? client,
  })  : endpoint = Uri.parse(url),
        headers = {'content-type': 'application/json', ...?headers},
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    final body = jsonEncode({
      'resource': resource.attributes,
      'signals': batch.map((s) => s.toJson()).toList(),
    });
    try {
      // Time out the headers await too — a headersProvider backed by slow/flaky
      // storage can otherwise hang `export` forever and wedge the flush loop.
      final dynamicHeaders = headersProvider == null
          ? const <String, String>{}
          : await headersProvider!().timeout(timeout);
      final res = await _client
          .post(endpoint, headers: {...headers, ...dynamicHeaders}, body: body)
          .timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false; // retryable
    }
  }

  @override
  Future<void> shutdown() async {
    if (_ownsClient) _client.close();
  }
}
