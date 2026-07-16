/// Scrubs secrets and PII out of strings before they're recorded, so telemetry
/// that lands in a backend doesn't leak tokens, credentials, emails, or phone
/// numbers.
///
/// Pure and stateless. The default [Redactor] covers common cases; pass your own
/// pattern map to add app-specific ones (e.g. a custom PIN field):
///
/// ```dart
/// final redactor = Redactor({
///   ...Redactor.defaults,
///   RegExp(r'cancel_pin["\s]*[:=]["\s]*[^"\s,}]+'): 'cancel_pin=[REDACTED]',
/// });
/// obs.event('x', attributes: redactor.attributes({'note': text}));
/// ```
class Redactor {
  Redactor([Map<Pattern, String>? patterns])
      : _patterns = patterns ?? defaults;

  final Map<Pattern, String> _patterns;

  /// A shared instance using [defaults].
  static final Redactor standard = Redactor();

  /// Sensible built-in patterns: Basic/Bearer auth, password/token/api_key
  /// assignments, email addresses, and phone numbers.
  static final Map<Pattern, String> defaults = {
    RegExp(r'Authorization:\s*Basic\s+[A-Za-z0-9+/=]+'):
        'Authorization: Basic [REDACTED]',
    RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*'): 'Bearer [REDACTED]',
    RegExp(r'password["\s]*[:=]["\s]*[^"\s,}]+'): 'password=[REDACTED]',
    RegExp(r'token["\s]*[:=]["\s]*[^"\s,}]+'): 'token=[REDACTED]',
    RegExp(r'api_key["\s]*[:=]["\s]*[^"\s,}]+'): 'api_key=[REDACTED]',
    RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'):
        '[EMAIL_REDACTED]',
    RegExp(r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b'): '[PHONE_REDACTED]',
  };

  /// Redact a single string.
  String call(String input) {
    var out = input;
    _patterns.forEach((pattern, replacement) {
      out = out.replaceAll(pattern, replacement);
    });
    return out;
  }

  /// Redact the string values of an attribute map (non-strings pass through).
  Map<String, Object?>? attributes(Map<String, Object?>? attributes) {
    if (attributes == null) return null;
    return attributes.map(
      (key, value) => MapEntry(key, value is String ? call(value) : value),
    );
  }
}
