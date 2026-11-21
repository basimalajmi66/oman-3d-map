/// Analyse over the trading app: the floating window has "Analyse now" and "Auto"; a press captures the screen
/// (the floating window hides itself for that moment), crops it with the frame the user chose, analyses it with the
/// engine and shows the answer in the floating window. Automatic mode does the same a few seconds after each
/// candle closes. It never trades and never touches the trading app.
library;

import 'dart:async';

import '../core/engine_api.dart';
import '../core/image_prep.dart';
import '../platform/screen_capture.dart';
import 'app_state.dart';

class LiveMode {
  LiveMode({
    required this.state,
    required this.screen,
    required this.crop,
    Stream<dynamic>? commands,
    DateTime Function()? now,
    this.hideDelay = const Duration(milliseconds: 350),
  }) : _now = now ?? DateTime.now {
    _sub = commands?.listen(handle);
  }

  final AppState state;
  final ScreenSource screen;
  final Future<CropFrac?> Function() crop;
  final DateTime Function() _now;
  final Duration hideDelay;
  StreamSubscription<dynamic>? _sub;
  Timer? _auto;
  bool auto = false;
  bool busy = false;
  int? _lastCandle;
  Json _last = const {};

  bool get active => state.liveActive;

  /// Starts live analysis: overlay permission, Android's screen-sharing prompt, then the floating window.
  /// Returns an error key, or null when running.
  Future<String?> start() async {
    final o = state.overlay;
    if (!o.supported) return 'live_unsupported';
    if (!await o.hasPermission() && !await o.requestPermission()) return 'overlay_permission_denied';
    if (!await screen.start()) return 'live_screen_denied';
    if (state.settings['screen_capture_allowed'] != true) {
      await state.updateSettings({'screen_capture_allowed': true}); // the user just allowed screen reading
    }
    state.liveActive = true;
    if (!state.overlayActive) {
      await o.show();
      state.overlayActive = true;
    }
    state.changed();
    await _push();
    return null;
  }

  Future<void> stop() async {
    _auto?.cancel();
    _auto = null;
    auto = false;
    state.liveActive = false;
    await screen.stop();
    if (state.overlayActive) {
      await state.overlay.hide();
      state.overlayActive = false;
    }
    state.changed();
  }

  /// A command from the floating window: {'cmd': 'analyze' | 'auto' (with 'on') | 'stop'}.
  Future<void> handle(dynamic msg) async {
    if (msg is! Map) return;
    switch (msg['cmd']) {
      case 'analyze':
        await analyzeNow();
      case 'auto':
        setAuto(msg['on'] == true);
      case 'stop':
        await stop();
    }
  }

  void setAuto(bool on) {
    auto = on;
    _auto?.cancel();
    _auto = on ? Timer.periodic(const Duration(seconds: 1), (_) => tick()) : null;
    unawaited(_push());
  }

  /// Automatic mode: once per candle, 2 s after it closed (the platform has drawn the closed candle by then).
  Future<void> tick() async {
    final tf = state.settings['candle_timeframe_sec'] as int? ?? 30;
    final t = _now().millisecondsSinceEpoch ~/ 1000;
    final candle = t ~/ tf;
    if (t % tf >= 2 && t % tf <= 6 && candle != _lastCandle && !busy) {
      _lastCandle = candle;
      await analyzeNow();
    }
  }

  Future<void> analyzeNow() async {
    if (busy || !active) return;
    busy = true;
    try {
      await _push(hide: true); // the floating window must not be in the picture
      await Future<void>.delayed(hideDelay);
      final png = await screen.capture();
      await _push(working: true);
      if (png == null) {
        _last = {'error': state.t('live_no_frame')};
        return;
      }
      final image = UploadFile(name: 'screen.png', length: png.length, openRead: () => Stream.value(png));
      final r = await state.analyzeChart(image, inputMode: 'screenshot', crop: await crop());
      _last = summarise(r);
    } on EngineException catch (e) {
      _last = {'error': e.message};
    } finally {
      busy = false;
      await _push();
    }
  }

  /// What the floating window shows from one analysis result.
  Json summarise(Json r) {
    final a = (r['analysis'] as Map?)?.cast<String, dynamic>() ?? const {};
    final reading = (a['reading'] as Map?)?.cast<String, dynamic>();
    final summary = (reading?['summary'] as Map?)?.cast<String, dynamic>();
    final code = a['reason_code'] as String?;
    final t = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    return {
      'signal': a['signal'] ?? 'WAIT',
      'reason': code == null ? null : state.t('reason_$code'),
      'quality': a['data_quality'],
      'duration_sec': a['duration_sec'],
      'confidence': a['confidence'],
      'confidence_calibrated': a['confidence_calibrated'] == true,
      'price': summary?['last_closed_close'],
      'time': '${two(t.hour)}:${two(t.minute)}:${two(t.second)}',
    };
  }

  Future<void> _push({bool hide = false, bool working = false}) async {
    if (!state.overlayActive) return;
    await state.overlay.push({
      'live': true,
      'lang': state.lang,
      'state': 'live',
      'hide': hide,
      'busy': working || busy,
      'auto': auto,
      'timeframe_sec': state.settings['candle_timeframe_sec'],
      'signal': 'WAIT',
      ..._last,
    });
  }

  void dispose() {
    _auto?.cancel();
    _sub?.cancel();
  }
}
