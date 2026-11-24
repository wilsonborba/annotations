import 'package:annotations_shared/core/settings.dart';

/// Settings of this app. Build scripts set the values with --dart-define.
const settings = Settings(
  apiBase: String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: Settings.defaultApiBase,
  ),
  version: String.fromEnvironment('BUILD_NAME', defaultValue: '1.0.0'),
  buildTime: String.fromEnvironment(
    'BUILD_TIMESTAMP',
    defaultValue: 'development',
  ),
  development: bool.fromEnvironment('DEVELOPMENT_MODE', defaultValue: true),
  authBase: String.fromEnvironment(
    'AUTH_BASE_URL',
    defaultValue: 'https://auth.asodya.com',
  ),
  appContextKey: String.fromEnvironment('APP_CONTEXT_KEY'),
);
