/// Contract between the UI and the local analysis engine.
///
/// The UI never talks to a broker or trading platform. Every call goes to the
/// local engine (loopback HTTP on desktop; embedded engine on mobile, Phase 2).
/// Note there is intentionally no method that executes a trade.
library;

typedef Json = Map<String, dynamic>;

class EngineException implements Exception {
  EngineException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  bool get isPermission => statusCode == 403;
  bool get isOffline => statusCode == 0;

  @override
  String toString() => 'EngineException($statusCode): $message';
}

/// A file chosen by the user, streamed to the engine without loading it into memory.
class UploadFile {
  UploadFile({required this.name, required this.length, required this.openRead});
  final String name;
  final int length;
  final Stream<List<int>> Function() openRead;
}

abstract class EngineApi {
  Future<bool> health();

  // settings
  Future<Json> getSettings();
  Future<Json> patchSettings(Json patch);
  Future<Json> resetSettings();

  // analysis control
  Future<Json> status();
  Future<Json> start({String inputMode = 'upload', String? asset});
  Future<Json> stop();
  Future<Json> emergencyStop();

  // knowledge library
  Future<List<Json>> listSources({String? kind, String? category});
  Future<Json> getSource(int id);
  Future<void> deleteSource(int id);
  Future<Json> addNote({
    required String title,
    required String content,
    String? category,
    List<String> tags = const [],
    String itemType = 'note',
  });
  Future<Json> addUrl({required String url, String? title, String? notes});
  Future<Json> uploadFile(UploadFile file, {String? title, String? category, List<String> tags = const []});
  Future<Json> decideItem(int itemId, String decision);
  Future<List<Json>> search(String query, {bool approvedOnly = false});

  // signals & results
  Future<List<Json>> listSignals({int limit = 100});
  Future<Json> summary();
  Future<List<Json>> listResults({String? accountType});
  Future<Json> addResult(Json result);
  Future<void> deleteResult(int id);

  // backup & privacy
  Future<List<Json>> listBackups();
  Future<Json> createBackup(String passphrase);
  Future<Json> restoreBackup(UploadFile file, String passphrase);
  Future<void> wipe({bool includeBackups = false});
}
