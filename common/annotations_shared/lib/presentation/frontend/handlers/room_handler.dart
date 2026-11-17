import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../dal/remote/api_adapter.dart';
import '../../../dal/remote/browser/transfers.dart' as browser;
import '../../../domain/models/content.dart';
import '../../../domain/models/local_file.dart';
import '../../../domain/services/annotations_service.dart';

class RoomHandler extends ChangeNotifier {
  final AnnotationsService service;
  final String code;
  Data? room;
  String? error, uploadName;
  bool opening = true, expired = false, busy = false;
  double progress = 0;
  Timer? _timer;
  bool _closed = false, _refreshing = false;
  RoomHandler(this.service, this.code);
  void emit() {
    if (!_closed) notifyListeners();
  }

  Future<void> open() async {
    try {
      room = await service.room(code, create: true);
      error = null;
      if (_closed) return;
      _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
    } catch (e) {
      error = e.toString();
    }
    opening = false;
    emit();
  }

  Future<void> refresh() async {
    if (_refreshing || expired || _closed) return;
    _refreshing = true;
    try {
      room = await service.room(code);
      error = null;
    } catch (e) {
      if (e is ApiError && (e.status == 404 || e.status == 410)) {
        expired = true;
        _timer?.cancel();
      }
      error = e.toString();
    }
    _refreshing = false;
    emit();
  }

  Future<bool> edit(String text, {String? id}) async {
    busy = true;
    error = null;
    emit();
    try {
      final uri = Uri.tryParse(text.trim());
      room = await service.edit(
        code,
        text.trim(),
        id: id,
        revision: id == null ? null : room?['revision'] as int?,
        kind: uri != null && ['https', 'http'].contains(uri.scheme)
            ? 'link'
            : 'text',
      );
      busy = false;
      emit();
      return true;
    } catch (e) {
      error = e.toString();
      busy = false;
      emit();
      final problem = error;
      await refresh();
      error = problem;
      emit();
      return false;
    }
  }

  Future<void> remove(String id) async {
    busy = true;
    error = null;
    emit();
    try {
      room = await service.remove(code, id);
    } catch (e) {
      final problem = e.toString();
      await refresh();
      error = problem;
    }
    busy = false;
    emit();
  }

  Future<void> choose() async {
    final files = await browser.chooseFiles();
    for (final file in files) {
      await upload(file);
    }
  }

  Future<void> upload(LocalFile file) async {
    if (_closed || expired) return;
    if (uploadName != null) return;
    uploadName = file.name;
    progress = 0;
    error = null;
    emit();
    try {
      room = await browser.sendFile(
        file,
        '${service.api.base}/instant/${Uri.encodeComponent(code)}/files?size=${file.size}',
        (value) {
          progress = value;
          emit();
        },
      );
    } catch (e) {
      error = e.toString();
    }
    uploadName = null;
    emit();
  }

  String fileUrl(Data item) => '${service.api.base}${item['url']}';
  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    super.dispose();
  }
}
