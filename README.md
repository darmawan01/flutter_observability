# flutter_observability

Generic, backend-agnostic observability for Flutter. **Instrument once, send
anywhere.** Errors, events, spans, and metrics flow through a pluggable
`Exporter` interface — ship to your own JSON endpoint, to **OpenTelemetry**
(Grafana / SigNoz / Datadog / any OTLP backend), to the console, or to a custom
sink. Batching, sampling, retry, and a bounded offline queue are handled for you.

Producers (your app, a crash handler, an OTA SDK) never know the backend; a
backend is just an exporter.

## Quick start

```dart
import 'package:flutter/widgets.dart';
import 'package:flutter_observability/flutter_observability.dart';

Future<void> main() async {
  await Observability.runGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await Observability.init(
      resource: Resource.app(appId: 'com.acme.app', version: '1.4.0', installId: deviceId),
      exporters: [
        HttpJsonExporter(url: 'https://console.acme.dev/api/telemetry'), // your platform
        OtlpExporter(endpoint: 'https://otlp.grafana.net', headers: {'Authorization': 'Basic …'}),
      ],
      sampleRate: 0.2, // errors are always kept
    );
    Observability.instance.installErrorHandlers(); // FlutterError + PlatformDispatcher

    runApp(const MyApp());
  });
}
```

## API (Sentry-shaped, so it's familiar)

```dart
final o = Observability.instance;
o.event('checkout.completed', attributes: {'total': 42});
o.addBreadcrumb('tapped pay');
o.counter('applies', value: 1);
o.captureError(err, stackTrace: st);            // never sampled out

final span = o.startSpan('patch.apply', attributes: {'v': '1.2.0'});
// … do work …
span.end(ok: true);                              // one trace, start→end→status
```

## Exporters

| Exporter | Sends to | Notes |
|---|---|---|
| `HttpJsonExporter` | any JSON endpoint | `{ resource, signals[] }`; drop-in for a console's `/api/telemetry` |
| `OtlpExporter` | any OTLP/HTTP backend | non-span → OTLP **logs**, spans → OTLP **traces**. One `endpoint`, or split `tracesUrl`/`logsUrl` (e.g. straight to Grafana **Tempo** + **Loki**, no collector) |
| `ConsoleExporter` | `debugPrint` | local dev |
| *your own* | anywhere | implement `Exporter.export(batch, resource)` |

Pass several at once — they fan out (at-least-once delivery, with retry).

## OTA bridge (flutter_patcher)

Dependency-free — feed the OTA SDK's event map straight in:

```dart
FlutterPatcher.init(onEvent: (e) => recordPatchEvent(e.toJson()));
```

## Design

```
sources (errors · events · spans · patch bridge)
   → Signal (neutral model: kind, name, attributes, severity, trace/span ids)
   → pipeline (enrich · sample · batch · offline-queue · retry)
   → Exporter[]  (HttpJson · OTLP · Console · custom)
```

- **Neutral, OTel-shaped model** so OTLP export is natural but nobody has to learn
  OpenTelemetry to emit.
- **Errors bypass sampling.** The offline queue is bounded (oldest dropped, count
  surfaced) so it can't grow unbounded while offline.
- OTA core stays dependency-free; this package doesn't depend on it and vice versa.

## Roadmap

- Persistent offline queue (survives restarts) behind a `QueueStore` interface.
- OTLP **metrics** (counters → OTLP sums) and Grafana **Faro** / Sentry exporters.
- Per-signal exporter cursors (exactly-once instead of at-least-once).

Ship with `--split-debug-info` in CI so native stack traces symbolicate.
