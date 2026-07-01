import 'package:flutter/foundation.dart';

import '../exporter.dart';
import '../resource.dart';
import '../signal.dart';

/// Prints signals via `debugPrint`. For local development / sanity checks.
class ConsoleExporter extends Exporter {
  final bool verbose;
  ConsoleExporter({this.verbose = false});

  @override
  Future<bool> export(List<Signal> batch, Resource resource) async {
    for (final s in batch) {
      final extra = verbose ? ' ${s.toJson()}' : (s.attributes.isEmpty ? '' : ' ${s.attributes}');
      debugPrint('[obs] ${s.severity.name.toUpperCase()} ${s.kind.name} ${s.name}$extra');
    }
    return true;
  }
}
