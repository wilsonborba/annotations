/// Runtime settings of one Annotations application.
///
/// Each application declares its values in its own `lib/core/settings.dart`
/// and calls [Settings.use] in `main` before `runApp`.
class Settings {
  /// The Annotations API base URL behind the shared gateway.
  static const defaultApiBase = 'https://api.asodya.com/apps/annotations/v1';

  /// The application id in every telemetry payload. Both apps share it, so
  /// the gateway keeps one Annotations history.
  static const appId = 'annotations';

  /// The settings of the running application. Tests use the defaults.
  static Settings current = const Settings();

  /// Selects [settings] for the running application.
  static void use(Settings settings) => current = settings;

  const Settings({
    this.apiBase = defaultApiBase,
    this.version = '1.0.0',
    this.buildTime = 'development',
    this.development = true,
  });

  /// The Annotations API base URL.
  final String apiBase;

  /// The build name, such as `1.1.0`.
  final String version;

  /// The build time, or `development` for a local run.
  final String buildTime;

  /// True for a development build. Then debug logs are printed.
  final bool development;

  /// The build label in every error report.
  String get buildLabel => '$version ($buildTime)';

  /// The shared gateway route that receives usage events.
  Uri get telemetryEvents =>
      Uri.parse('${Uri.parse(apiBase).origin}/apps/api/v1/telemetry/events');

  /// The shared gateway route that receives client errors.
  Uri get telemetryErrors =>
      Uri.parse('${Uri.parse(apiBase).origin}/apps/api/v1/telemetry/errors');
}
