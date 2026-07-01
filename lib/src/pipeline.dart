import 'dart:async';

import 'exporter.dart';
import 'resource.dart';
import 'signal.dart';

/// Batches signals and drives the exporters. Backend-agnostic: batching,
/// periodic flushing, retry, and a bounded in-memory queue (the offline buffer)
/// live here so every exporter gets them for free.
///
/// Delivery is at-least-once: if one of several exporters fails a batch, the
/// batch is retried against all of them on the next flush.
class Pipeline {
  final List<Exporter> exporters;
  final Resource resource;
  final int batchSize;
  final int maxQueue;
  final Duration flushInterval;
  final void Function(String message)? onDebug;

  final List<Signal> _queue = [];
  Timer? _timer;
  bool _flushing = false;

  /// Signals dropped because the queue was full (backpressure while offline).
  int dropped = 0;

  Pipeline({
    required this.exporters,
    required this.resource,
    this.batchSize = 50,
    this.maxQueue = 1000,
    this.flushInterval = const Duration(seconds: 10),
    this.onDebug,
  }) {
    if (flushInterval > Duration.zero) {
      _timer = Timer.periodic(flushInterval, (_) => flush());
    }
  }

  void add(Signal s) {
    _queue.add(s);
    if (_queue.length > maxQueue) {
      final overflow = _queue.length - maxQueue;
      _queue.removeRange(0, overflow); // drop oldest
      dropped += overflow;
    }
    if (_queue.length >= batchSize) {
      // Fire and forget; _flushing guards against re-entrancy.
      unawaited(flush());
    }
  }

  int get pending => _queue.length;

  Future<void> flush() async {
    if (_flushing || _queue.isEmpty || exporters.isEmpty) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(batchSize).toList(growable: false);
        var anyFail = false;
        for (final e in exporters) {
          bool ok;
          try {
            ok = await e.export(batch, resource);
          } catch (err) {
            ok = false;
            onDebug?.call('exporter ${e.runtimeType} threw: $err');
          }
          if (!ok) anyFail = true;
        }
        if (anyFail) {
          onDebug?.call('flush deferred ${batch.length} signals for retry');
          break; // keep the batch queued; retry on the next flush
        }
        _queue.removeRange(0, batch.length);
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    for (final e in exporters) {
      try {
        await e.shutdown();
      } catch (_) {/* shutdown must not throw */}
    }
  }
}
