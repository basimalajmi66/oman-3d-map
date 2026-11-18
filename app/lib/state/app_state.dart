import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/companion.dart';
import '../core/engine_api.dart';
import '../core/window_controller.dart';
import '../l10n/strings.dart';
import '../platform/android_overlay.dart';

/// Single source of UI state. Settings live in the engine's SQLite database so
/// they survive restarts and travel inside backups.
class AppState extends ChangeNotifier {
  AppState({
    required this.engine,
    required this.window,
    this.pollInterval = const Duration(seconds: 2),
    OverlayController? overlay,
    this.companion,
    this.onUnpair,
    this.onSwitchMode,
  }) : overlay = overlay ?? NoOverlay();

  /// Set on a phone / tablet: the engine is on this paired computer.
  final CompanionPairing? companion;
  final Future<void> Function()? onUnpair;
  bool get isCompanion => companion != null;

  /// A capability the engine did not declare counts as available (older engines); the phone
  /// engine declares what it lacks (`knowledge: false`, …) so those screens are hidden.
  bool has(String capability) => capabilities[capability] != false;
  bool get isOnDevice => capabilities['engine'] == 'phone';
  final Future<void> Function()? onSwitchMode;

  final EngineApi engine;
  final WindowController window;
  final Duration? pollInterval; // null disables polling (tests)
  final OverlayController overlay;
  bool overlayActive = false;
  Json? lastChartResult;
  List<Json> notices = const [];
  Json capabilities = const {};

  bool connected = false;
  bool busy = false;
  String? lastError;
  Json settings = {};
  Json status = {};
  Timer? _timer;

  String get lang => (settings['language'] as String?) ?? 'ar';
  String t(String key) => tr(lang, key);
  bool get isRtl => lang == 'ar';

  ThemeMode get themeMode => switch (settings['theme']) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };

  String get state => connected ? (status['state'] as String? ?? 'idle') : 'offline';
  bool get running => status['session'] != null;
  Json get recommendation => (status['recommendation'] as Map?)?.cast<String, dynamic>() ?? const {};
  String get signal => recommendation['signal'] as String? ?? 'WAIT';

  Future<void> init() async {
    await refresh();
    if (pollInterval != null) {
      _timer = Timer.periodic(pollInterval!, (_) => _poll());
    }
  }

  Future<void> refresh() async {
    try {
      settings = await engine.getSettings();
      status = await engine.status();
      notices = await engine.notices();
      capabilities = await engine.capabilities();
      connected = true;
      lastError = null;
      await _applyWindowPrefs();
      overlayActive = await overlay.isActive();
      await _pushOverlay();
    } on EngineException catch (e) {
      connected = !e.isOffline;
      lastError = e.message;
    }
    notifyListeners();
  }

  Future<void> _poll() async {
    try {
      final s = await engine.status();
      final wasOffline = !connected;
      status = s;
      connected = true;
      if (wasOffline) settings = await engine.getSettings();
      await _pushOverlay();
      notifyListeners();
    } on EngineException catch (e) {
      if (e.isOffline && connected) {
        connected = false;
        notifyListeners();
      }
    }
  }

  Future<void> _pushOverlay() async {
    if (!overlayActive) return;
    await overlay.push(overlayPayload(
      lang: lang,
      state: state,
      recommendation: recommendation,
      timeframe: (status['session'] as Map?)?['timeframe_sec'] ?? settings['candle_timeframe_sec'],
    ));
  }

  /// Show / hide the Android floating window. Asks for the overlay permission
  /// first; returns false when the user did not grant it.
  Future<bool> toggleOverlay() async {
    if (!overlay.supported) return false;
    if (overlayActive) {
      await overlay.hide();
      overlayActive = false;
      notifyListeners();
      return true;
    }
    if (!await overlay.hasPermission() && !await overlay.requestPermission()) return false;
    await overlay.show();
    overlayActive = true;
    await _pushOverlay();
    notifyListeners();
    return true;
  }

  /// Submit a chart image for analysis (upload, share or screenshot).
  Future<Json> analyzeChart(UploadFile image, {String inputMode = 'upload'}) async {
    final r = (await _guard(() => engine.submitChartImage(image, inputMode: inputMode)))!;
    lastChartResult = r;
    notifyListeners();
    return r;
  }

  Future<void> _applyWindowPrefs() async {
    await window.setAlwaysOnTop(settings['panel_always_on_top'] as bool? ?? true);
    await window.setOpacity((settings['panel_opacity'] as num?)?.toDouble() ?? 1.0);
  }

  Future<T?> _guard<T>(Future<T> Function() action) async {
    busy = true;
    notifyListeners();
    try {
      final r = await action();
      lastError = null;
      return r;
    } on EngineException catch (e) {
      lastError = e.message;
      if (e.isOffline) connected = false;
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Continuous screen reading when the user enabled it *and* granted screen access.
  String get defaultInputMode =>
      settings['continuous_analysis'] == true && settings['screen_capture_allowed'] == true
          ? 'continuous_screen'
          : 'upload';

  bool get canCaptureScreen => window.isDesktop && settings['screen_capture_allowed'] == true;

  Json? get screenWatch => (status['screen_watch'] as Map?)?.cast<String, dynamic>();

  Future<Json> captureScreen() async {
    final r = (await _guard(engine.captureScreen))!;
    lastChartResult = r;
    notifyListeners();
    return r;
  }

  Future<void> startAnalysis({String? inputMode}) async {
    final mode = inputMode ?? defaultInputMode;
    status = (await _guard(() => engine.start(inputMode: mode)))!;
    await _pushOverlay();
  }

  Future<void> stopAnalysis() async {
    status = (await _guard(engine.stop))!;
    await _pushOverlay();
  }

  Future<void> emergencyStop() async {
    status = (await _guard(engine.emergencyStop))!;
    settings = await engine.getSettings();
    await _pushOverlay();
    notifyListeners();
  }

  Future<void> updateSettings(Json patch) async {
    settings = (await _guard(() => engine.patchSettings(patch)))!;
    await _applyWindowPrefs();
    notifyListeners();
  }

  Future<void> resetSettings() async {
    settings = (await _guard(engine.resetSettings))!;
    await _applyWindowPrefs();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Exposes [AppState] to the widget tree and rebuilds dependents on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}
