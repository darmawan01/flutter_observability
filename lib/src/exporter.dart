import 'resource.dart';
import 'signal.dart';

/// The seam that makes this "send anywhere". Implement it to ship signals to any
/// backend; the pipeline handles batching, sampling, retry, and the offline
/// queue for you. Return `true` on success so a failed batch can be retried.
abstract class Exporter {
  /// Export a batch. Must not throw — return `false` to signal a retryable
  /// failure (network down, 5xx). Throwing is treated as a failure too.
  Future<bool> export(List<Signal> batch, Resource resource);

  /// Flush/close any transport. Called on [Observability.shutdown].
  Future<void> shutdown() async {}
}
