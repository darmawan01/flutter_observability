import 'package:flutter/widgets.dart';

import 'observability.dart';
import 'signal.dart';

/// A [NavigatorObserver] that records a screen-view event on every named-route
/// push/pop/replace, giving a navigation trail in your telemetry.
///
/// Register it once — no per-screen wiring:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [ObservabilityRouteObserver()],
///   ...
/// );
/// ```
///
/// Anonymous routes (no `settings.name`, e.g. dialogs) are skipped. Safe to
/// construct before `Observability.init` — it no-ops until initialised.
class ObservabilityRouteObserver extends NavigatorObserver {
  ObservabilityRouteObserver({
    this.eventName = 'screen.view',
    this.severity = Severity.info,
  });

  /// The event name recorded for each navigation.
  final String eventName;

  /// Severity for the recorded event.
  final Severity severity;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _record('push', route, from: previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _record('replace', newRoute, from: oldRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _record('pop', previousRoute, from: route);
  }

  void _record(String action, Route<dynamic>? route, {Route<dynamic>? from}) {
    if (!Observability.isInitialized) return;
    final name = route?.settings.name;
    if (name == null || name.isEmpty) return;
    Observability.instance.event(
      eventName,
      severity: severity,
      attributes: {
        'screen': name,
        'action': action,
        'from': from?.settings.name,
      },
    );
  }
}
