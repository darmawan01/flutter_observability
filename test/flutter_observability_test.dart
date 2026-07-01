import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_observability/flutter_observability.dart';

class FakeExporter extends Exporter {
  final List<Signal> received = [];
  int calls = 0;
  bool succeed = true;

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    calls++;
    if (!succeed) return false;
    received.addAll(batch);
    return true;
  }
}

Future<Observability> _init(Exporter e, {double sampleRate = 1.0}) => Observability.init(
      resource: Resource.app(appId: 'com.test.app', version: '1.0.0', installId: 'dev-1'),
      exporters: [e],
      sampleRate: sampleRate,
      batchSize: 1000, // don't auto-flush; we flush manually
      flushInterval: Duration.zero, // no timer in tests
    );

void main() {
  group('pipeline + API', () {
    test('event / error / span / counter all flow to the exporter', () async {
      final fake = FakeExporter();
      final obs = await _init(fake);

      obs.event('checkout.completed', attributes: {'total': 42});
      obs.addBreadcrumb('tapped pay');
      obs.counter('applies', value: 1);
      final span = obs.startSpan('patch.apply', attributes: {'v': '1.2.0'});
      span.end(ok: true);
      obs.captureError(StateError('boom'), stackTrace: StackTrace.current);

      await obs.flush();

      expect(fake.received.map((s) => s.kind), containsAll([
        SignalKind.event,
        SignalKind.breadcrumb,
        SignalKind.counter,
        SignalKind.span,
        SignalKind.error,
      ]));
      final spanSig = fake.received.firstWhere((s) => s.kind == SignalKind.span);
      expect(spanSig.traceId, isNotNull);
      expect(spanSig.endTimestamp, isNotNull);
      await obs.shutdown();
    });

    test('errors are never sampled out, other signals are', () async {
      final fake = FakeExporter();
      final obs = await _init(fake, sampleRate: 0.0);

      for (var i = 0; i < 20; i++) {
        obs.event('noise');
      }
      obs.captureError(Exception('kept'));
      await obs.flush();

      expect(fake.received.where((s) => s.kind == SignalKind.event), isEmpty);
      expect(fake.received.where((s) => s.kind == SignalKind.error).length, 1);
      await obs.shutdown();
    });

    test('a failed export is retried on the next flush (offline queue)', () async {
      final fake = FakeExporter()..succeed = false;
      final obs = await _init(fake);

      obs.event('will.retry');
      await obs.flush();
      expect(fake.received, isEmpty); // failed, still queued

      fake.succeed = true;
      await obs.flush();
      expect(fake.received.length, 1); // delivered on retry
      await obs.shutdown();
    });
  });

  test('patch bridge maps a PatchEvent map to a signal', () async {
    final fake = FakeExporter();
    final obs = await _init(fake);

    recordPatchEvent({
      'type': 'applyFinished',
      'version': '1.2.0+5',
      'patchNumber': 5,
      'installId': 'dev-abc',
      'ok': false,
      'error': 'SIGNATURE_INVALID',
    });
    await obs.flush();

    final s = fake.received.single;
    expect(s.name, 'patch.applyFinished');
    expect(s.severity, Severity.error);
    expect(s.attributes['patch.version'], '1.2.0+5');
    expect(s.attributes['patch.error'], 'SIGNATURE_INVALID');
    expect(s.attributes['device.id'], 'dev-abc');
    await obs.shutdown();
  });

  group('HttpJsonExporter', () {
    test('posts resource + signals; 2xx ok, 5xx retryable', () async {
      String? captured;
      final client = MockClient((req) async {
        captured = req.body;
        return http.Response('{}', 200);
      });
      final exp = HttpJsonExporter(url: 'https://sink.test/api/telemetry', client: client);
      final res = Resource.app(appId: 'a');
      final ok = await exp.export([
        Signal(kind: SignalKind.event, name: 'e', timestamp: DateTime.now(), attributes: {'x': 1}),
      ], res);

      expect(ok, isTrue);
      final body = jsonDecode(captured!) as Map<String, Object?>;
      expect(body['resource'], containsPair('service.name', 'a'));
      expect((body['signals'] as List).single, containsPair('name', 'e'));

      final fail = HttpJsonExporter(url: 'https://sink.test/x', client: MockClient((_) async => http.Response('nope', 503)));
      expect(await fail.export([Signal(kind: SignalKind.event, name: 'e', timestamp: DateTime.now())], res), isFalse);
    });
  });

  group('OtlpExporter payloads', () {
    final exp = OtlpExporter(endpoint: 'http://collector:4318/');
    final res = Resource.app(appId: 'com.acme', version: '2.0.0');

    test('non-span signals map to OTLP logs', () {
      final p = exp.buildLogsPayload([
        Signal(kind: SignalKind.error, name: 'StateError', timestamp: DateTime.now(), severity: Severity.error, error: 'boom'),
      ], res);
      final rl = (p['resourceLogs'] as List).single as Map;
      expect((rl['resource'] as Map)['attributes'], isA<List>());
      final rec = (((rl['scopeLogs'] as List).single as Map)['logRecords'] as List).single as Map;
      expect((rec['body'] as Map)['stringValue'], 'StateError');
      expect(rec['severityNumber'], 17);
      expect((rec['attributes'] as List).any((a) => (a as Map)['key'] == 'exception.message'), isTrue);
    });

    test('span signals map to OTLP traces with status', () {
      final now = DateTime.now();
      final p = exp.buildTracesPayload([
        Signal(
          kind: SignalKind.span,
          name: 'patch.apply',
          timestamp: now,
          endTimestamp: now.add(const Duration(milliseconds: 5)),
          traceId: 'a' * 32,
          spanId: 'b' * 16,
          ok: false,
        ),
      ], res);
      final span = (((((p['resourceSpans'] as List).single as Map)['scopeSpans'] as List).single as Map)['spans'] as List).single as Map;
      expect(span['name'], 'patch.apply');
      expect(span['traceId'], 'a' * 32);
      expect((span['status'] as Map)['code'], 2); // ERROR
      expect(span['startTimeUnixNano'], isA<String>());
    });
  });
}
