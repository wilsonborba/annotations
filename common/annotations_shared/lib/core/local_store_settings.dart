/// Settings of the local note store on installed apps (D2, technical decision
/// 12: SQLite with managed attachment files in the app support folder).
final class LocalStoreSettings {
  const LocalStoreSettings({
    this.autosaveDelay = const Duration(milliseconds: 500),
    this.databaseFile = 'notes.sqlite3',
    this.attachmentFolder = 'attachments',
  });

  /// The pause after the last edit before autosave writes the note. Edits in
  /// this pause join one save. The page shows Saving during the pause (D2.3).
  final Duration autosaveDelay;

  /// The database file name in the app support folder.
  final String databaseFile;

  /// The folder name of the managed attachment copies in the app support
  /// folder.
  final String attachmentFolder;
}
