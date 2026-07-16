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
}
