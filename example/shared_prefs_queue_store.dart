// A persistent QueueStore backed by shared_preferences.
//
// This lives in example/ (not in the package's lib/) so flutter_observability
// itself stays dependency-free. To use it, copy this file into your app and add
// the dependency:
//
//   flutter pub add shared_preferences
//
// Then wire it up:
//
//   await Observability.init(
//     resource: Resource.app(appId: 'com.acme.app', version: '1.0.0'),
//     exporters: [OtlpExporter(endpoint: '...')],
//     queueStore: SharedPrefsQueueStore(),
//   );
//
// Now signals buffered while offline survive an app restart/crash.
//
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter_observability/flutter_observability.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors the offline queue into shared_preferences as a single JSON string.
///
/// Good for modest volumes — the queue is bounded by `Pipeline.maxQueue`
/// (default 1000), and the pipeline debounces writes, so this rewrites one
/// small string every ~250ms of activity at most. For very high throughput,
/// prefer a sqlite-backed store (same [QueueStore] interface).
class SharedPrefsQueueStore extends QueueStore {
  SharedPrefsQueueStore({this.key = 'flutter_observability.queue'});

  /// The shared_preferences key the queue snapshot is stored under.
  final String key;

  SharedPreferences? _prefs;
  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  bool get persistent => true;

  @override
  Future<List<Signal>> load() async {
    final raw = (await _p).getString(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Signal.fromJson(Map<String, Object?>.from(e as Map)))
          .toList();
    } catch (_) {
      // Corrupt/partial snapshot — start clean rather than crash on boot.
      return const [];
    }
  }

  @override
  Future<void> save(List<Signal> signals) async {
    final raw = jsonEncode(signals.map((s) => s.toJson()).toList());
    await (await _p).setString(key, raw);
  }

  @override
  Future<void> close() async {
    // shared_preferences writes are already durable; nothing to flush.
  }
}
