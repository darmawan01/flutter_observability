import 'dart:async';

import 'package:flutter_observability/flutter_observability.dart';
import 'package:flutter_test/flutter_test.dart';

class _CapturingExporter extends Exporter {
  final List<Signal> signals = [];
  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    signals.addAll(batch);
    return true;
  }

  @override
  Future<void> shutdown() async {}
}

void main() {
  group('Redactor', () {
    test('scrubs common secrets and PII', () {
      final r = Redactor();
      expect(r('Bearer abc.def-123'), 'Bearer [REDACTED]');
      expect(r('password=hunter2'), 'password=[REDACTED]');
      expect(r('reach me@x.io'), contains('[EMAIL_REDACTED]'));
      expect(r('555-123-4567'), contains('[PHONE_REDACTED]'));
      expect(r('nothing secret here'), 'nothing secret here');
    });

    test('attributes() redacts string values only', () {
      final out = Redactor().attributes({'a': 'token=x', 'b': 7});
      expect(out!['a'], 'token=[REDACTED]');
      expect(out['b'], 7);
    });

    test('accepts custom patterns', () {
      final r = Redactor({RegExp(r'pin=\d+'): 'pin=[REDACTED]'});
      expect(r('pin=1234'), 'pin=[REDACTED]');
    });
  });

  group('Span.traceparent', () {
    test('formats as W3C traceparent', () async {
      final obs = await Observability.init(
        resource: const Resource({'service.name': 't'}),
        exporters: [_CapturingExporter()],
        flushInterval: Duration.zero,
      );
      final span = obs.startSpan('op');
      expect(
        span.traceparent,
        matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')),
      );
      await obs.shutdown();
    });
  });

  group('Observability.trace', () {
    test('records a span and returns the body result', () async {
      final exporter = _CapturingExporter();
      final obs = await Observability.init(
        resource: const Resource({'service.name': 't'}),
        exporters: [exporter],
        flushInterval: Duration.zero,
      );

      final result = await obs.trace('work', () async => 42);
      expect(result, 42);
      await obs.flush();

      final span = exporter.signals.firstWhere((s) => s.kind == SignalKind.span);
      expect(span.name, 'work');
      expect(span.ok, isTrue);
      await obs.shutdown();
    });

    test('marks the span errored and rethrows', () async {
      final exporter = _CapturingExporter();
      final obs = await Observability.init(
        resource: const Resource({'service.name': 't'}),
        exporters: [exporter],
        flushInterval: Duration.zero,
      );

      await expectLater(
        obs.trace('boom', () async => throw StateError('x')),
        throwsStateError,
      );
      await obs.flush();

      final span = exporter.signals.firstWhere((s) => s.kind == SignalKind.span);
      expect(span.ok, isFalse);
      await obs.shutdown();
    });
  });

  group('HttpJsonExporter.headersProvider', () {
    test('is exposed and defaults to null', () {
      final exporter = HttpJsonExporter(url: 'https://example.test/t');
      expect(exporter.headersProvider, isNull);
      expect(exporter.headers['content-type'], 'application/json');
    });
  });

  group('OtlpExporter', () {
    test('headersProvider is exposed; endpoint resolves the /v1 paths', () {
      final exporter = OtlpExporter(
        endpoint: 'https://gw.test/aware3/otlp',
        headersProvider: () async => {'authorization': 'Bearer x'},
      );
      expect(exporter.headersProvider, isNotNull);
      expect(exporter.tracesUrl, 'https://gw.test/aware3/otlp/v1/traces');
      expect(exporter.metricsUrl, 'https://gw.test/aware3/otlp/v1/metrics');
      expect(exporter.logsUrl, 'https://gw.test/aware3/otlp/v1/logs');
    });

    test('preserves trace/span ids verbatim in the OTLP payload', () {
      final exporter = OtlpExporter(endpoint: 'https://x.test');
      final payload = exporter.buildTracesPayload([
        Signal.fromJson({
          'kind': 'span',
          'name': 'op',
          'severity': 'info',
          'timeUnixNano': 1700000000000000000,
          'endTimeUnixNano': 1700000001000000000,
          'traceId': '0af7651916cd43dd8448eb211c80319c',
          'spanId': 'b7ad6b7169203331',
          'ok': true,
        }),
      ], const Resource({'service.name': 't'}));
      final span = (((payload['resourceSpans'] as List).first
          as Map)['scopeSpans'] as List).first as Map;
      final s = (span['spans'] as List).first as Map;
      expect(s['traceId'], '0af7651916cd43dd8448eb211c80319c');
      expect(s['spanId'], 'b7ad6b7169203331'); // verbatim — no regeneration
    });
  });

  group('OtlpExporter headersProvider timeout (regression)', () {
    // A headersProvider backed by slow/flaky storage (e.g. secure storage for an
    // auth token) must not be able to hang `export` forever — that used to wedge
    // the pipeline's `_flushing` guard and silently stop ALL telemetry.
    test('export returns false (not hang) when headersProvider never completes',
        () async {
      final exporter = OtlpExporter(
        endpoint: 'http://127.0.0.1:9/aware3/otlp', // unreachable; never posts
        headersProvider: () => Completer<Map<String, String>>().future, // hangs
        timeout: const Duration(milliseconds: 100),
      );
      final span = Signal(
        kind: SignalKind.span,
        name: 'op',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        endTimestamp: DateTime.fromMillisecondsSinceEpoch(1700000001000),
        traceId: '0af7651916cd43dd8448eb211c80319c',
        spanId: 'b7ad6b7169203331',
        ok: true,
      );

      // Guard: if the fix regresses, the headers await hangs and this whole call
      // never completes — the outer timeout turns that into a clear failure.
      final ok = await exporter
          .export([span], const Resource({'service.name': 't'}))
          .timeout(const Duration(seconds: 2),
              onTimeout: () => throw StateError('export() hung on headersProvider'));

      expect(ok, isFalse); // deferred for retry, pipeline stays unwedged
    });
  });
}
