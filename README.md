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
| `OtlpExporter` | any OTLP/HTTP backend | counters → OTLP **metrics** (monotonic sums), spans → OTLP **traces**, the rest → OTLP **logs**. One `endpoint`, or split `metricsUrl`/`tracesUrl`/`logsUrl` (e.g. straight to **Prometheus** + Grafana **Tempo** + **Loki**, no collector) |
| `SentryExporter` | Sentry | give it a project **DSN**; errors → Sentry *exceptions*, events/breadcrumbs → *messages*. `release`/`environment` default from the `Resource` |
| `ConsoleExporter` | `debugPrint` | local dev |
| *your own* | anywhere | implement `Exporter.export(batch, resource)` |

Pass several at once — they fan out with retry. Delivery is exactly-once per
exporter within a session: each has its own cursor, so a batch one exporter
rejects is retried only there, not re-sent to the ones that already took it.

## OTA bridge (flutter_patcher)

Dependency-free — feed the OTA SDK's event map straight in:

```dart
FlutterPatcher.init(onEvent: (e) => recordPatchEvent(e.toJson()));
```

## Durable offline queue

Signals buffered while offline live in an in-memory queue. By default that queue
is **not** persisted — if the app is killed before the next flush, anything
queued (including a crash captured on the way down) is lost.

Make it durable by passing a `QueueStore`. The queue is then mirrored to storage
and **restored on the next launch** (restored signals flush first). Writes are
debounced and run off the hot path, so `event()` / `captureError()` never block on
disk.

```dart
await Observability.init(
  resource: Resource.app(appId: 'com.acme.app', version: '1.0.0'),
  exporters: [OtlpExporter(endpoint: '…')],
  queueStore: SharedPrefsQueueStore(), // survives restarts
);
```

The core package stays dependency-free — it ships only the `QueueStore` interface
and the no-op `InMemoryQueueStore` default. Concrete adapters live outside it so
you only pull the storage dependency you actually want:

- **shared_preferences** — ready-to-copy adapter in
  [`example/shared_prefs_queue_store.dart`](example/shared_prefs_queue_store.dart).
  Good for modest volumes.
- **sqlite / a file / your own** — implement `QueueStore` (three methods:
  `load`, `save`, `close`) and serialize with `Signal.toJson` /
  `Signal.fromJson`. Snapshots are bounded by `maxQueue`, so they stay small.

```dart
class MyQueueStore extends QueueStore {
  @override
  bool get persistent => true;
  @override
  Future<List<Signal>> load() async { /* read + Signal.fromJson */ }
  @override
  Future<void> save(List<Signal> signals) async { /* Signal.toJson + write */ }
}
```

> Persistence is best-effort: a store must never throw into the caller (return an
> empty list from `load` on a corrupt snapshot). `error` round-trips as its string
> form and `stackTrace` is dropped — only `toJson`, which is all the exporters
> read, survives a restart.

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

- ~~Persistent offline queue (survives restarts) behind a `QueueStore`
  interface.~~ ✅ done — see [Durable offline queue](#durable-offline-queue).
- ~~OTLP **metrics** (counters → OTLP sums)~~ ✅ done — counters export to
  `/v1/metrics` as monotonic delta sums.
- ~~Sentry exporter~~ ✅ done — `SentryExporter(dsn: …)`. Grafana **Faro** next.
- ~~Per-signal exporter cursors (exactly-once instead of at-least-once).~~ ✅ done
  — a batch is retried only on the exporter that failed it.

Ship with `--split-debug-info` in CI so native stack traces symbolicate.
