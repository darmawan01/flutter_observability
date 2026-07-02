import 'dart:async';

import 'exporter.dart';
import 'queue/in_memory_queue.dart';
import 'queue/queue_store.dart';
import 'resource.dart';
import 'signal.dart';

/// Batches signals and drives the exporters. Backend-agnostic: batching,
/// periodic flushing, retry, and a bounded offline queue live here so every
/// exporter gets them for free.
///
/// The queue is held in memory (fast, non-blocking [add]) and mirrored into a
/// [QueueStore] so it survives an app restart. The default [InMemoryQueueStore]
/// persists nothing; pass a persistent store to keep buffered signals across a
/// crash/kill. Writes are debounced and run off the hot path.
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

  /// Durable backing for the offline queue. Defaults to a no-op in-memory store.
  final QueueStore store;

  /// How long to coalesce queue changes before writing a snapshot to [store].
  /// Keeps rapid [add]s from causing a write per signal.
  final Duration persistDebounce;

  final List<Signal> _queue = [];
  Timer? _timer;
  bool _flushing = false;

  // Debounced persistence state.
  Timer? _persistTimer;
  bool _persisting = false;
  bool _persistDirty = false;

  /// Signals dropped because the queue was full (backpressure while offline).
  int dropped = 0;

  Pipeline({
    required this.exporters,
    required this.resource,
    this.batchSize = 50,
    this.maxQueue = 1000,
    this.flushInterval = const Duration(seconds: 10),
    this.onDebug,
    QueueStore? store,
    this.persistDebounce = const Duration(milliseconds: 250),
  }) : store = store ?? const InMemoryQueueStore() {
    if (flushInterval > Duration.zero) {
      _timer = Timer.periodic(flushInterval, (_) => flush());
    }
  }

  /// Load any signals persisted by a previous run into the front of the queue
  /// (oldest first, so they flush before new ones). Call once, after construction
  /// and before producing signals — `Observability.init` does this for you. No-op
  /// for a non-persistent store.
  Future<void> restore() async {
    if (!store.persistent) return;
    try {
      final persisted = await store.load();
      if (persisted.isEmpty) return;
      _queue.insertAll(0, persisted);
      _trimOverflow();
      onDebug?.call('restored ${persisted.length} signals from ${store.runtimeType}');
    } catch (err) {
      onDebug?.call('queue restore failed: $err');
    }
  }

  void add(Signal s) {
    _queue.add(s);
    _trimOverflow();
    if (_queue.length >= batchSize) {
      // Fire and forget; _flushing guards against re-entrancy.
      unawaited(flush());
    }
    _markDirty();
  }

  /// Drop oldest signals when the queue is over [maxQueue] (backpressure).
  void _trimOverflow() {
    if (_queue.length > maxQueue) {
      final overflow = _queue.length - maxQueue;
      _queue.removeRange(0, overflow);
      dropped += overflow;
    }
  }

  int get pending => _queue.length;

  Future<void> flush() async {
    if (_flushing || _queue.isEmpty || exporters.isEmpty) return;
    _flushing = true;
    var removedAny = false;
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
        removedAny = true;
      }
    } finally {
      _flushing = false;
      if (removedAny) _markDirty();
    }
  }

  // ---- Persistence (debounced, best-effort, off the hot path) ---------------

  /// Note the queue changed and schedule a snapshot write. Cheap no-op when the
  /// store doesn't persist.
  void _markDirty() {
    if (!store.persistent) return;
    _persistDirty = true;
    _persistTimer ??= Timer(persistDebounce, () {
      _persistTimer = null;
      unawaited(_persistNow());
    });
  }

  /// Write the current snapshot. Re-entrancy-safe: a change arriving mid-write
  /// leaves the queue dirty and triggers one more pass.
  Future<void> _persistNow() async {
    if (_persisting) return;
    _persisting = true;
    try {
      while (_persistDirty) {
        _persistDirty = false;
        final snapshot = List<Signal>.of(_queue);
        try {
          await store.save(snapshot);
        } catch (err) {
          onDebug?.call('queue persist failed: $err');
        }
      }
    } finally {
      _persisting = false;
    }
  }

  Future<void> shutdown() async {
    _timer?.cancel();
    _timer = null;
    _persistTimer?.cancel();
    _persistTimer = null;
    await flush();
    // Persist whatever's left (e.g. signals deferred by a failing exporter) so
    // the next run picks them up, then release the store.
    if (store.persistent) {
      _persistDirty = true;
      await _persistNow();
      try {
        await store.close();
      } catch (_) {/* close must not throw */}
    }
    for (final e in exporters) {
      try {
        await e.shutdown();
      } catch (_) {/* shutdown must not throw */}
    }
  }
}
