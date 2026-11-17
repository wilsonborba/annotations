import 'package:flutter/foundation.dart';
import '../../../dal/local/preferences_adapter.dart';
import '../../../domain/services/annotations_service.dart';

class WaitlistHandler extends ChangeNotifier {
  final AnnotationsService service;
  final PreferencesAdapter storage;
  bool busy = false, registered = false;
  String? status, error;
  bool _closed = false;
  WaitlistHandler(this.service, {PreferencesAdapter? storage})
    : storage = storage ?? PreferencesAdapter();
  Future<void> load() async {
    registered = await storage.read('waitlist') == 'registered';
    if (!_closed) notifyListeners();
  }

  Future<void> submit(String email, String message) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final value = await service.waitlist(email, message);
      status = value['status'] as String?;
      registered = true;
      await storage.write('waitlist', 'registered');
    } catch (e) {
      error = e.toString();
    }
    if (!_closed) {
      busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}
