import 'package:flutter_observability/flutter_observability.dart';

/// Minimal usage — see README for the full app-entrypoint wrapper.
Future<void> main() async {
  await Observability.init(
    resource: Resource.app(appId: 'com.acme.app', version: '1.0.0'),
    exporters: [ConsoleExporter(verbose: true)],
  );

  final o = Observability.instance;
  o.event('app.started', attributes: {'cold': true});

  final span = o.startSpan('load.home');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  span.end(ok: true);

  try {
    throw StateError('example failure');
  } catch (e, s) {
    o.captureError(e, stackTrace: s);
  }

  await o.flush();
  await o.shutdown();
}
