import '../../../domain/models/local_file.dart';

Future<List<LocalFile>> chooseFiles() async => [];
void Function() listenForPaste(void Function(LocalFile) callback) => () {};
Future<Map<String, dynamic>> sendFile(
  LocalFile file,
  String url,
  void Function(double) progress,
) async => throw UnsupportedError('File transfer requires a browser');
