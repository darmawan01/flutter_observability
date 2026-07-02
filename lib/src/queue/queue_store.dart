import '../signal.dart';

/// Durable backing for the pipeline's offline queue.
///
/// The pipeline keeps a fast in-memory buffer and mirrors it into a [QueueStore]
/// so buffered signals survive an app restart (e.g. a crash captured just before
/// the process dies). The default is [InMemoryQueueStore], which persists nothing
/// — swap in a real one (shared_preferences, sqlite, a file) via
/// `Observability.init(queueStore: ...)`.
///
/// ## Contract
/// - [save] receives the **whole** current queue (a snapshot). Implementations
///   overwrite whatever they stored before. The queue is bounded (see
///   `Pipeline.maxQueue`), so snapshots stay small.
/// - Persistence is **best-effort**: [save]/[load] must never throw into the
///   caller. Catch your own errors and surface them (return empty from [load]).
/// - Writes are called off the hot path (debounced) — [save] may be async and
///   slow-ish without stalling signal production.
/// - Serialize with [Signal.toJson] / [Signal.fromJson].
///
/// A minimal shared_preferences adapter lives in
/// `example/shared_prefs_queue_store.dart`.
abstract class QueueStore {
  const QueueStore();

  /// Whether [save] actually persists. When false the pipeline skips scheduling
  /// writes entirely (zero overhead for the in-memory default).
  bool get persistent;

  /// Load signals persisted by a previous run, oldest first. Called once at
  /// startup. Return an empty list if there's nothing (or on any error).
  Future<List<Signal>> load();

  /// Persist the current queue snapshot. Called (debounced) after the queue
  /// changes. Best-effort — do not throw.
  Future<void> save(List<Signal> signals);

  /// Flush any buffered writes and release resources. Called on shutdown.
  Future<void> close() async {}
}
