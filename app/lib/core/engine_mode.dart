import 'package:shared_preferences/shared_preferences.dart';

/// Where the engine runs on a phone / tablet: inside the app ('local') or on the user's computer ('remote').
class EngineModeStore {
  static const _key = 'uata.engine_mode';
  static Future<String?> load() async => (await SharedPreferences.getInstance()).getString(_key);
  static Future<void> save(String mode) async => (await SharedPreferences.getInstance()).setString(_key, mode);
}
