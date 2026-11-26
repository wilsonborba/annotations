import 'local_note_store.dart';

/// The store of a public reader: reading never saves (annotations#40), so
/// every write fails loudly instead of keeping anything.
final class ReadOnlyNoteStore implements LocalNoteStore {
  const ReadOnlyNoteStore();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('The public reader does not save notes.');
}
