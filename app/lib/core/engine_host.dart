import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'engine_api.dart';
import 'engine_locator.dart';
import 'http_engine_api.dart';

/// Where the engine lives on this device and how to reach it.
///
/// * [DesktopEngineHost]  — Windows/Linux/macOS: separate `uata-engine` process.
/// * [EmbeddedEngineHost] — Android: Python engine embedded in the app through
///   Chaquopy, started over the `uata/engine` method channel.
///
/// Both expose the same [EngineApi]; the rest of the app does not care which.
abstract class EngineHost {
  String get kind;

  /// Start the engine if needed and return a client for it.
  Future<EngineApi> connect();

  void dispose() {}

  static EngineHost forPlatform() {
    if (Platform.isAndroid) return EmbeddedEngineHost();
    return DesktopEngineHost();
  }
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

class EmbeddedEngineHost implements EngineHost {
  EmbeddedEngineHost({MethodChannel? channel, this.port = 8765})
      : _channel = channel ?? const MethodChannel('uata/engine');

  final MethodChannel _channel;
  final int port;
  String? dataDir;

  @override
  String get kind => 'embedded';

  Future<String?> _readToken() async {
    if (dataDir == null) return null;
    final f = File(p.join(dataDir!, 'api_token'));
    return await f.exists() ? (await f.readAsString()).trim() : null;
  }

  @override
  Future<EngineApi> connect() async {
    var usePort = port;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('start', {'port': port});
      dataDir = info?['data_dir'] as String?;
      usePort = (info?['port'] as int?) ?? port;
    } on PlatformException catch (e) {
      // The client is still returned; the UI shows "engine offline" with the reason.
      throw EngineException(0, 'embedded engine failed to start: ${e.message}');
    }
    return HttpEngineApi(baseUrl: Uri.parse('http://127.0.0.1:$usePort'), tokenProvider: _readToken);
  }

  @override
  void dispose() {}
}
