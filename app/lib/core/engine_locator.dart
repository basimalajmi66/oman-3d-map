import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine_api.dart';

/// Finds the engine's data directory / token and (on desktop) starts the engine
/// process if it is not running yet. Mirrors `backend/uata/config.py`.
class EngineLocator {
  EngineLocator({Map<String, String>? environment}) : env = environment ?? Platform.environment;
  final Map<String, String> env;

  String dataDir() {
    final override = env['UATA_DATA_DIR'];
    if (override != null && override.isNotEmpty) return override;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'] ?? p.join(home, 'AppData', 'Local');
      return p.join(local, 'UniversalAITradingAssistant');
    }
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'Application Support', 'UniversalAITradingAssistant');
    }
    final xdg = env['XDG_DATA_HOME'] ?? p.join(home, '.local', 'share');
    return p.join(xdg, 'universal-ai-trading-assistant');
  }

  Future<String?> readToken() async {
    final f = File(p.join(dataDir(), 'api_token'));
    if (!await f.exists()) return null;
    return (await f.readAsString()).trim();
  }

  Process? _process;

  /// Start the engine if it does not answer. Order of candidates:
  /// 1. `UATA_ENGINE_CMD` (full command line, for custom installs)
  /// 2. bundled `engine/uata-engine(.exe)` next to the app executable
  /// 3. development fallback: `python -m uata` from `UATA_BACKEND_DIR`
  Future<bool> ensureRunning(EngineApi api) async {
    if (await api.health()) return true;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return false;

    final exeDir = p.dirname(Platform.resolvedExecutable);
    final bundled = p.join(exeDir, 'engine', Platform.isWindows ? 'uata-engine.exe' : 'uata-engine');
    try {
      if (env['UATA_ENGINE_CMD'] case final cmd? when cmd.trim().isNotEmpty) {
        final parts = cmd.trim().split(RegExp(r'\s+'));
        _process = await Process.start(parts.first, parts.skip(1).toList());
      } else if (await File(bundled).exists()) {
        _process = await Process.start(bundled, const []);
      } else if (env['UATA_BACKEND_DIR'] case final dir? when dir.isNotEmpty) {
        _process = await Process.start(Platform.isWindows ? 'python' : 'python3', ['-m', 'uata'],
            workingDirectory: dir);
      } else {
        return false;
      }
    } on ProcessException {
      return false;
    }
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (await api.health()) return true;
    }
    return false;
  }

  /// Stop the engine only if this app started it.
  void shutdown() {
    _process?.kill();
    _process = null;
  }
}
