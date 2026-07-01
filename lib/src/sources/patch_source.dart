import '../observability.dart';
import '../signal.dart';

/// Bridge from the `flutter_patcher` OTA SDK to observability — kept dependency
/// free by taking the event's plain map (`PatchEvent.toJson()`), so this package
/// never depends on the OTA SDK.
///
/// Wire it once:
/// ```dart
/// FlutterPatcher.init(onEvent: (e) => recordPatchEvent(e.toJson()));
/// ```
void recordPatchEvent(Map<dynamic, dynamic> event) {
  if (!Observability.isInitialized) return;
  final type = (event['type'] ?? 'unknown').toString().replaceFirst('PatchEventType.', '');
  final ok = event['ok'];
  final failed = ok == false;
  Observability.instance.event(
    'patch.$type',
    severity: failed ? Severity.error : Severity.info,
    attributes: {
      if (event['version'] != null) 'patch.version': event['version'],
      if (event['patchNumber'] != null) 'patch.number': event['patchNumber'],
      if (event['installId'] != null) 'device.id': event['installId'],
      if (event['channel'] != null) 'patch.channel': event['channel'],
      if (event['error'] != null) 'patch.error': event['error'].toString(),
      if (event['message'] != null) 'patch.message': event['message'],
    },
  );
}
