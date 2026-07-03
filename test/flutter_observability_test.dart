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

/// A persistent [QueueStore] that keeps the snapshot in a field, so tests can
/// see what the pipeline mirrored (and preload a "previous run").
class FakeStore extends QueueStore {
  List<Signal> persisted;
  int saves = 0;
  bool closed = false;
  FakeStore([List<Signal>? initial]) : persisted = List.of(initial ?? const []);

  @override
  bool get persistent => true;
  @override
  Future<List<Signal>> load() async => List.of(persisted);
  @override
  Future<void> save(List<Signal> signals) async {
    saves++;
    persisted = List.of(signals);
  }

  @override
  Future<void> close() async => closed = true;
}

Future<Observability> _init(Exporter e, {double sampleRate = 1.0, QueueStore? queueStore}) => Observability.init(
      resource: Resource.app(appId: 'com.test.app', version: '1.0.0', installId: 'dev-1'),
      exporters: [e],
      sampleRate: sampleRate,
      batchSize: 1000, // don't auto-flush; we flush manually
      flushInterval: Duration.zero, // no timer in tests
      queueStore: queueStore,
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

    test('a failed batch is retried only on the exporter that failed (exactly-once per exporter)', () async {
      final a = FakeExporter();
      final b = FakeExporter()..succeed = false;
      final obs = await Observability.init(
        resource: Resource.app(appId: 'com.test.app', version: '1.0.0'),
        exporters: [a, b],
        batchSize: 1000,
        flushInterval: Duration.zero,
      );

      obs.event('deliver.once');
      await obs.flush(); // a accepts, b fails
      expect(a.received.length, 1);
      expect(b.received, isEmpty);
      final aCallsAfterFirst = a.calls;

      b.succeed = true;
      await obs.flush(); // only b should be retried
      expect(a.received.length, 1); // NOT re-sent to a
      expect(a.calls, aCallsAfterFirst); // a wasn't even called again
      expect(b.received.length, 1); // b caught up
      await obs.shutdown();
    });
  });

  group('persistent offline queue', () {
    test('Signal round-trips through toJson/fromJson', () {
      final s = Signal(
        kind: SignalKind.span,
        name: 'patch.apply',
        timestamp: DateTime.fromMicrosecondsSinceEpoch(1710000000123456),
        endTimestamp: DateTime.fromMicrosecondsSinceEpoch(1710000000200000),
        severity: Severity.error,
        attributes: {'v': '1.2.0', 'n': 5},
        traceId: 'a' * 32,
        spanId: 'b' * 16,
        ok: false,
        error: 'boom',
      );
      final r = Signal.fromJson(s.toJson());
      expect(r.kind, SignalKind.span);
      expect(r.name, 'patch.apply');
      expect(r.timestamp, s.timestamp);
      expect(r.endTimestamp, s.endTimestamp);
      expect(r.severity, Severity.error);
      expect(r.attributes['v'], '1.2.0');
      expect(r.traceId, 'a' * 32);
      expect(r.ok, isFalse);
      expect(r.error, 'boom');
    });

    test('the default queue store is in-memory and persists nothing', () async {
      const store = InMemoryQueueStore();
      expect(store.persistent, isFalse);
      expect(await store.load(), isEmpty);
    });

    test('a persistent store is written on add and cleared after a successful flush', () async {
      final store = FakeStore();
      final fake = FakeExporter();
      final obs = await _init(fake, queueStore: store);

      obs.event('persist.me');
      await Future<void>.delayed(const Duration(milliseconds: 400)); // past the debounce
      expect(store.persisted.map((s) => s.name), ['persist.me']);

      await obs.flush();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(store.persisted, isEmpty); // trimmed once the exporter accepted it

      await obs.shutdown();
      expect(store.closed, isTrue);
    });

    test('signals persisted by a previous run are restored and flushed first', () async {
      final store = FakeStore([
        Signal(kind: SignalKind.event, name: 'from.disk', timestamp: DateTime.now()),
      ]);
      final fake = FakeExporter();
      final obs = await _init(fake, queueStore: store);

      // No new signals added — restore() should have loaded the persisted one.
      await obs.flush();
      expect(fake.received.map((s) => s.name), contains('from.disk'));

      await obs.shutdown();
    });

    test('a failing exporter keeps persisted signals for the next run', () async {
      final store = FakeStore();
      final fake = FakeExporter()..succeed = false;
      final obs = await _init(fake, queueStore: store);

      obs.event('unsent');
      await obs.flush(); // export fails, stays queued
      await obs.shutdown(); // shutdown persists what's left

      expect(store.persisted.map((s) => s.name), ['unsent']);
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

    test('traces-only routing (Tempo) posts spans, skips logs', () async {
      final hits = <String>[];
      final client = MockClient((req) async {
        hits.add(req.url.toString());
        return http.Response('{}', 200);
      });
      final tempo = OtlpExporter(tracesUrl: 'https://tempo.example/v1/traces', logs: false, client: client);
      final now = DateTime.now();
      final ok = await tempo.export([
        Signal(kind: SignalKind.event, name: 'e', timestamp: now),
        Signal(kind: SignalKind.span, name: 'patch.apply', timestamp: now, endTimestamp: now, traceId: 'a' * 32, spanId: 'b' * 16),
      ], res);
      expect(ok, isTrue);
      expect(hits, ['https://tempo.example/v1/traces']); // no /v1/logs call
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
