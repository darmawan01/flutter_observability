/// Identity of the thing being observed — attached to every exported batch.
/// Mirrors OpenTelemetry resource attributes (service.name, service.version, …)
/// so it maps cleanly onto OTLP and onto a device/app fleet.
class Resource {
  final Map<String, Object?> attributes;

  const Resource(this.attributes);

  /// Convenience constructor for the common fields.
  factory Resource.app({
    required String appId,
    String? version,
    String? installId,
    String? environment,
    Map<String, Object?> extra = const {},
  }) =>
      Resource({
        'service.name': appId,
        if (version != null) 'service.version': version,
        if (installId != null) 'service.instance.id': installId,
        if (environment != null) 'deployment.environment': environment,
        ...extra,
      });

  Resource merge(Map<String, Object?> more) => Resource({...attributes, ...more});
}
