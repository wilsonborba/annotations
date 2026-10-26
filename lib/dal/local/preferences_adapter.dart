import 'package:shared_preferences/shared_preferences.dart';

class PreferencesAdapter {
  Future<String?> read(String key) async =>
      (await SharedPreferences.getInstance()).getString('annotations.$key');
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(
      'annotations.$key',
      value,
    );
  }
}
