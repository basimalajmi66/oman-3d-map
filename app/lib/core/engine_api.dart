/// Contract between the UI and the local analysis engine.
///
/// The UI never talks to a broker or trading platform. Every call goes to the
/// local engine (loopback HTTP on desktop; embedded engine on mobile, Phase 2).
/// Note there is intentionally no method that executes a trade.
library;

typedef Json = Map<String, dynamic>;

class EngineException implements Exception {
  EngineException(this.statusCode, this.message, {this.reasons = const []});
  final int statusCode;
  final String message;
  /// Machine-readable reasons (e.g. why a strategy does not qualify for approval).
  final List<String> reasons;

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
  /// Engine notices from /health (e.g. it started after setting a corrupt database aside).
  Future<List<Json>> notices();
  /// What this installation can do: OCR (+languages), speech-to-text, ffmpeg, screen capture.
  Future<Json> capabilities();

  // companion devices (desktop UI only; refused from a phone)
  Future<Json> companionStatus();
  /// One-time pairing code + `uata://pair?...` link for the QR code (valid 5 minutes).
  Future<Json> companionPairing();
  Future<void> cancelCompanionPairing();
  Future<Json> revokeCompanionDevice(int id);

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
  /// The full text read from a source (a video's transcript, a PDF's pages, OCR of its images).
  Future<String> sourceText(int id);
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

  // strategies & training (Phase 7)
  Future<List<Json>> strategyCatalog();
  Future<List<Json>> listStrategies();
  Future<Json> getStrategy(int id);
  Future<Json> createStrategy(String name, Json definition, {String description = ''});
  Future<Json> updateStrategy(int id, Json patch);
  Future<void> deleteStrategy(int id);
  Future<Json> backtest(int strategyId, int datasetId, {double payout = 0.85, double inSample = 0.7});
  /// Throws EngineException(409, reasons: [...]) when the strategy does not qualify.
  Future<Json> approveStrategy(int id);
  Future<Json> retireStrategy(int id);
  Future<List<Json>> compareStrategies(List<int> ids, int datasetId, {double payout = 0.85});
  Future<List<Json>> listDatasets();
  Future<Json> importDataset(UploadFile csv, {String? name, String? asset});
  Future<Json> syntheticDataset({int rows = 3000, int timeframeSec = 30, int seed = 0});
  Future<void> deleteDataset(int id);

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
  /// Record the outcome of a BUY/SELL signal; the engine copies its context.
  Future<Json> resultFromSignal(int signalId, {required String accountType, required String outcome, String? asset, String? notes});
  /// Statistics for one account type (simulation / demo / real) — never mixed.
  Future<Json> dashboard(String accountType);
  Future<List<Json>> insights(String accountType);

  // backup & privacy
  Future<List<Json>> listBackups();
  Future<Json> createBackup(String passphrase);
  /// The encrypted backup file itself, to save a copy outside the app (another device, cloud drive…).
  Future<List<int>> backupBytes(String name);
  Future<Json> restoreBackup(UploadFile file, String passphrase);
  Future<void> wipe({bool includeBackups = false});
}
