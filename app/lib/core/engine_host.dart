import 'dart:io';


import 'engine_api.dart';
import 'engine_locator.dart';
import 'http_engine_api.dart';

/// Where the engine lives on this device and how to reach it.
///
/// * [DesktopEngineHost] — Windows/Linux/macOS: separate `uata-engine` process on this computer.
/// * `RemoteEngineHost` (companion.dart) — phone / tablet: the engine on the user's
///   computer, reached over the local network after pairing.
///
/// Both expose the same [EngineApi]; the rest of the app does not care which.
abstract class EngineHost {
  String get kind;

  /// Start the engine if needed and return a client for it.
  Future<EngineApi> connect();

  void dispose() {}

  static bool get isCompanionPlatform => Platform.isAndroid || Platform.isIOS;
}

class DesktopEngineHost implements EngineHost {
  DesktopEngineHost({EngineLocator? locator, String? port})
      : _locator = locator ?? EngineLocator(),
        _port = port ?? Platform.environment['UATA_PORT'] ?? '8765';

  final EngineLocator _locator;
  final String _port;

  @override
  String get kind => 'desktop';

  @override
  Future<EngineApi> connect() async {
    final api = HttpEngineApi(baseUrl: Uri.parse('http://127.0.0.1:$_port'), tokenProvider: _locator.readToken);
    await _locator.ensureRunning(api);
    return api;
  }

  @override
  void dispose() => _locator.shutdown();
}
