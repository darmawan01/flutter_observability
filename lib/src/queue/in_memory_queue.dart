import '../signal.dart';
import 'queue_store.dart';

/// The default [QueueStore]: keeps nothing across restarts.
///
/// The pipeline already holds signals in memory, so this store is a pure no-op —
/// it exists so the persistence seam has a zero-cost default. [persistent] is
/// false, which tells the pipeline to skip write scheduling altogether. For
/// telemetry that survives an app kill, supply a persistent store to
/// `Observability.init(queueStore: ...)`.
class InMemoryQueueStore extends QueueStore {
  const InMemoryQueueStore();

  @override
  bool get persistent => false;

  @override
  Future<List<Signal>> load() async => const [];

  @override
  Future<void> save(List<Signal> signals) async {}
}
