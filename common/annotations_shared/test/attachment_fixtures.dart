// Test files and an in-memory store with attachments (annotations#34).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:annotations_shared/domain/models/local_note.dart';
import 'package:annotations_shared/domain/services/local_note_store.dart';

/// A 32 x 18 PNG (16:9).
final previewPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAASCAYAAAA6yNxSAAACu0lEQVR4nBXOoQ6FBAAAQD/HZCKRSCQSiUQikUjMwAzMwAzMwAzMwAzMwAzMwAzMwJxjBmZgBmbgR/ReuH5ffPn1n/99RUBIRExCSkZOQUlFTUNLR8/AyMTMwsrGzsHJxc3DyxdffiNAQEhETEJKRk5BSUVNQ0tHz8DIxMzCysbOwcnFzcP7zSfwrQABIRExCSkZOQUlFTUNLR09AyMTMwsrGzsHJxc3D++3n8B3AgSERMQkpGTkFJRU1DS0dPQMjEzMLKxs7BycXNw8vN99At8LEBASEZOQkpFTUFJR09DS0TMwMjGzsLKxc3BycfPwfv8J/CBAQEhETEJKRk5BSUVNQ0tHz8DIxMzCysbOwcnFzcP7wyfwowABIRExCSkZOQUlFTUNLR09AyMTMwsrGzsHJxc3D++Pn8BPAgSERMQkpGTkFJRU1DS0dPQMjEzMLKxs7BycXNw8vD99Aj8LEBASEZOQkpFTUFJR09DS0TMwMjGzsLKxc3BycfPw/vwJ/CJAQEhETEJKRk5BSUVNQ0tHz8DIxMzCysbOwcnFzcP7yyfwqwABIRExCSkZOQUlFTUNLR09AyMTMwsrGzsHJxc3D++vn8BvAgSERMQkpGTkFJRU1DS0dPQMjEzMLKxs7BycXNw8vL99Ar8LEBASEZOQkpFTUFJR09DS0TMwMjGzsLKxc3BycfPw/v4J/CFAQEhETEJKRk5BSUVNQ0tHz8DIxMzCysbOwcnFzcP7xyfwlwABIRExCSkZOQUlFTUNLR09AyMTMwsrGzsHJxc3D+9fn8DfAgSERMQkpGTkFJRU1DS0dPQMjEzMLKxs7BycXNw8vH9/Av8IEBASEZOQkpFTUFJR09DS0TMwMjGzsLKxc3BycfPw/vMJ/CtAQEhETEJKRk5BSUVNQ0tHz8DIxMzCysbOwcnFzcPL/9mLrBtxAwVTAAAAAElFTkSuQmCC',
);

/// A two-page PDF header with an A4 MediaBox; enough for the page shape.
final pdfBytes = Uint8List.fromList(
  latin1.encode(
    '%PDF-1.4\n1 0 obj << /Type /Pages /Count 2 >> endobj\n'
    '2 0 obj << /Type /Page /MediaBox [0 0 595 842] >> endobj\n'
    '3 0 obj << /Type /Page /MediaBox [0 0 595 842] >> endobj\n%%EOF\n',
  ),
);

final csvBytes = Uint8List.fromList(
  utf8.encode(
    'Plant,Light,Water,Growth\n'
    '"Bean, green",High,Daily,12 cm\n'
    'Basil,Medium,Twice a week,8 cm\n'
    'Cactus,High,Monthly,1 cm\n'
    'Fern,Low,Daily,6 cm\n'
    'Mint,Medium,Daily,10 cm\n'
    'Rose,High,Twice a week,9 cm\n'
    'Tulip,Medium,Weekly,7 cm\n',
  ),
);

/// Files kept in memory. [importFile] reads the path as a real file, so a
/// test can check that the original stays. [hold] makes copies wait; [fail]
/// makes the next copy fail.
final class FileStore implements LocalNoteStore {
  final files = <String, (LocalAttachment, Uint8List)>{};
  final discarded = <String>[];
  final saved = <LocalNoteDraft>[];
  Completer<void>? hold;
  int fail = 0;
  var _next = 0;

  LocalAttachment put(
    Uint8List bytes, {
    required String name,
    required String type,
    String? id,
  }) {
    final a = LocalAttachment(
      id: id ?? 'f${_next++}',
      name: name,
      type: type,
      size: bytes.length,
      path: '/store/${id ?? _next}',
    );
    files[a.id] = (a, bytes);
    return a;
  }

  @override
  Future<LocalAttachment> importFile(
    String sourcePath, {
    required String type,
  }) async {
    if (hold case final h?) await h.future;
    if (fail > 0) {
      fail--;
      throw const LocalStoreException('disk');
    }
    final bytes = File(sourcePath).readAsBytesSync();
    return put(bytes, name: sourcePath.split('/').last, type: type);
  }

  @override
  Future<LocalAttachment> importBytes(
    Uint8List bytes, {
    required String name,
    required String type,
  }) async => put(bytes, name: name, type: type);

  @override
  Future<LocalAttachment?> attachment(String id) async => files[id]?.$1;

  @override
  Future<Uint8List?> readAttachment(String id) async => files[id]?.$2;

  @override
  Future<void> discardAttachment(String id) async {
    discarded.add(id);
    files.remove(id);
  }

  @override
  Future<LocalNote> save(LocalNoteDraft draft) async {
    saved.add(draft);
    return LocalNote(
      id: draft.id,
      schema: draft.schema,
      document: draft.document,
      title: draft.title,
      revision: saved.length,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      syncState: LocalSyncState.local,
      accountId: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
