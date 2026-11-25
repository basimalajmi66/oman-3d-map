import 'dart:async';

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/companion.dart';
import '../core/engine_api.dart';
import '../core/image_prep.dart';
import '../data/paper_trading.dart';
import '../core/window_controller.dart';
import '../l10n/strings.dart';
import 'live_mode.dart';
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
    this.paper,
    this.background,
    this.askCrop,
  }) : overlay = overlay ?? NoOverlay();

  /// Set on a phone / tablet: the engine is on this paired computer.
  final CompanionPairing? companion;
  final Future<void> Function()? onUnpair;
  bool get isCompanion => companion != null;

  /// A capability the engine did not declare counts as available (older engines); the phone
  /// engine declares what it lacks (`knowledge: false`, …) so those screens are hidden.
  bool has(String capability) => capabilities[capability] != false;
  bool get isOnDevice => capabilities['engine'] == 'phone';

  /// Longest side chart images are shrunk to before analysis (0 = original); engines without the setting: 1280.
  int get chartMaxSide => settings['chart_max_side'] as int? ?? 1280;
  final Future<void> Function()? onSwitchMode;

  /// Shows the crop screen for a chart image (null in tests: images are analysed whole).
  final Future<CropDecision?> Function(UploadFile image)? askCrop;

  /// Background mode (Android, phone-only engine); null where it does not exist (desktop, remote, tests).
  final BackgroundControl? background;

  /// Stops background mode before the database is replaced or wiped, and on the emergency stop.
  Future<void> stopBackground() async => background?.stop();

  /// Automatic paper trading (virtual trades on real prices, simulation results only). Null in tests.
  final PaperTrader? paper;

  /// Catch up running paper sessions — not while the emergency stop is active, and only with the user's consent to
  /// download public prices.
  Future<void> paperTick() async {
    final p = paper;
    if (p == null || status['halted'] == true || settings['external_data_sources_allowed'] != true) return;
    if (await background?.isRunning() ?? false) return; // the background service is doing it (never both at once)
    await p.updateAll(engine);
  }

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

  /// True while the floating window shows live analysis over the trading app ([LiveMode] feeds it then).
  bool liveActive = false;

  /// Live analysis over the trading app (Android); set by main, null elsewhere and in tests.
  LiveMode? live;

  /// For helpers that change state (e.g. [LiveMode]).
  void changed() => notifyListeners();

  Future<void> _pushOverlay() async {
    if (!overlayActive || liveActive) return;
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
  Future<Json> analyzeChart(UploadFile image, {String inputMode = 'upload', CropFrac? crop, bool fast = false}) async {
    // fast (live over the trading app): a smaller picture and no price-axis reading — patterns need neither
    final side = fast ? math.min(chartMaxSide, 1000) : chartMaxSide;
    final r = (await _guard(() async => engine.submitChartImage(await prepareChartImage(image, side, crop: crop),
        inputMode: inputMode, readPrices: !fast)))!;
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
    await stopBackground();
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

/// What the user chose on the crop screen: the image (read once) and the crop (null = the whole image).
class CropDecision {
  CropDecision(this.image, this.crop);
  final UploadFile image;
  final CropFrac? crop;
}

/// Background mode as the UI sees it (implemented by the Android service; faked in tests).
class BackgroundControl {
  BackgroundControl({required this.isRunning, required this.start, required this.stop});
  final Future<bool> Function() isRunning;
  final Future<String?> Function(String lang) start; // error key or null
  final Future<void> Function() stop;
}

/// Exposes [AppState] to the widget tree and rebuilds dependents on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      (context.getElementForInheritedWidgetOfExactType<AppScope>()!.widget as AppScope).notifier!;
}
