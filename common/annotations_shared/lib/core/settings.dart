class Settings {
  static const apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.asodya.com/apps/annotations/v1',
  );
  static const version = String.fromEnvironment(
    'BUILD_NAME',
    defaultValue: '1.0.0',
  );
  static const buildTime = String.fromEnvironment(
    'BUILD_TIMESTAMP',
    defaultValue: 'development',
  );
  static const development = bool.fromEnvironment(
    'DEVELOPMENT_MODE',
    defaultValue: true,
  );
}
