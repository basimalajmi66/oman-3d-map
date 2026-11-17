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

  // chart images for analysis (upload / share / screenshot)
  /// [inputMode]: 'upload', 'share', 'screenshot' or 'screen_region'.
  Future<Json> submitChartImage(UploadFile image, {String inputMode = 'upload'});
  Future<List<Json>> listChartInputs({int limit = 50});
  /// One screenshot (screen or configured region), read immediately. Needs screen permission.
  Future<Json> captureScreen();
  /// PNG of the image with what the reader detected drawn on it.
  Future<List<int>> chartAnnotated(int inputId);

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
  /// Learning reports: what the system extracted from each source, awaiting your decision.
  Future<List<Json>> listReports({String? status});
  Future<Json> decideReport(int reportId, String decision);

  // educational videos (Phase 6)
  Future<List<Json>> listVideos();
  Future<Json> videoPage(int sourceId);
  Future<Json> uploadSubtitles(int sourceId, UploadFile subtitles);
  Future<Json> reanalyzeVideo(int sourceId);

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
