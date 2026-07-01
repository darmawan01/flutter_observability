import 'dart:math';

final Random _rng = Random.secure();

String _hex(int bytes) {
  final sb = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    sb.write(_rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 16-byte hex trace id (OTLP/W3C shape).
String newTraceId() => _hex(16);

/// 8-byte hex span id.
String newSpanId() => _hex(8);
