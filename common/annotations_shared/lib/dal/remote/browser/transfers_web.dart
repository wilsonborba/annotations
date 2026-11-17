import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import '../../../domain/models/local_file.dart';
import '../api_adapter.dart';

LocalFile local(web.File file) =>
    LocalFile(name: file.name, type: file.type, size: file.size, handle: file);
Future<List<LocalFile>> chooseFiles() {
  final done = Completer<List<LocalFile>>();
  final input = web.document.createElement('input') as web.HTMLInputElement;
  input.type = 'file';
  input.multiple = true;
  input.style.display = 'none';
  input.addEventListener(
    'change',
    ((web.Event event) {
      final files = input.files;
      final chosen = <LocalFile>[];
      if (files != null) {
        for (var i = 0; i < files.length; i++) {
          final file = files.item(i);
          if (file != null) chosen.add(local(file));
        }
      }
      if (!done.isCompleted) done.complete(chosen);
      input.remove();
    }).toJS,
  );
  input.addEventListener(
    'cancel',
    ((web.Event event) {
      if (!done.isCompleted) done.complete([]);
      input.remove();
    }).toJS,
  );
  web.document.body?.appendChild(input);
  input.click();
  return done.future;
}

void Function() listenForPaste(void Function(LocalFile) callback) {
  final listener = ((web.Event event) {
    final paste = event as web.ClipboardEvent;
    final files = paste.clipboardData?.files;
    if (files != null && files.length > 0) {
      event.preventDefault();
      for (var i = 0; i < files.length; i++) {
        final file = files.item(i);
        if (file != null) callback(local(file));
      }
    }
  }).toJS;
  web.document.addEventListener('paste', listener);
  return () => web.document.removeEventListener('paste', listener);
}

Future<Map<String, dynamic>> sendFile(
  LocalFile file,
  String url,
  void Function(double) progress,
) {
  final done = Completer<Map<String, dynamic>>();
  final xhr = web.XMLHttpRequest();
  xhr.open('POST', url);
  xhr.timeout = 180000;
  xhr.upload.addEventListener(
    'progress',
    ((web.Event event) {
      final e = event as web.ProgressEvent;
      if (e.lengthComputable) progress(e.loaded / e.total);
    }).toJS,
  );
  xhr.addEventListener(
    'load',
    ((web.Event event) {
      if (done.isCompleted) return;
      try {
        final result = jsonDecode(xhr.responseText) as Map<String, dynamic>;
        if (xhr.status >= 200 && xhr.status < 300) {
          done.complete(result);
        } else {
          done.completeError(
            ApiError(
              xhr.status,
              (result['error'] ?? 'Upload failed').toString(),
            ),
          );
        }
      } catch (e) {
        done.completeError(e);
      }
    }).toJS,
  );
  void fail() {
    if (!done.isCompleted) {
      done.completeError(ApiError(0, 'The upload connection failed.'));
    }
  }

  xhr.addEventListener('error', ((web.Event event) => fail()).toJS);
  xhr.addEventListener('timeout', ((web.Event event) => fail()).toJS);
  xhr.addEventListener('abort', ((web.Event event) => fail()).toJS);
  final form = web.FormData();
  form.append('file', file.handle as web.File, file.name);
  xhr.send(form);
  return done.future;
}
