/// Analyse over the trading app: the floating window has "Analyse now" and "Auto"; a press captures the screen
/// (the floating window hides itself for that moment), crops it with the frame the user chose, analyses it with the
/// engine and shows the answer in the floating window. Automatic mode does the same a few seconds after each
/// candle closes. It never trades and never touches the trading app.
library;

import 'dart:async';
import 'dart:typed_data';

import '../core/engine_api.dart';
import '../core/image_prep.dart';
import '../l10n/strings.dart';
import '../platform/screen_capture.dart';
import 'app_state.dart';

class LiveMode {
  LiveMode({
    required this.state,
    required this.screen,
    required this.crop,
    Stream<dynamic>? commands,
    DateTime Function()? now,
    this.onSetFrame,
    this.hideDelay = const Duration(milliseconds: 350),
  }) : _now = now ?? DateTime.now {
    _sub = commands?.listen(handle);
  }

  final AppState state;
  final ScreenSource screen;
  final Future<CropFrac?> Function() crop;
  final DateTime Function() _now;
  final Duration hideDelay;

  /// "Set frame" from the floating window: the screen picture is handed over for the crop screen (main app).
  final Future<void> Function(Uint8List png)? onSetFrame;
  StreamSubscription<dynamic>? _sub;
  Timer? _auto;
  bool auto = false;
  bool busy = false;
  int? _lastCandle;
  Json _last = const {};

  /// Fast reading (default): a smaller picture and no price-axis OCR — patterns need neither.
  bool fast = true;

  /// The account the one-tap results go to (the user trades on demo first).
  String account = 'demo';

  /// Trades from signals waiting for their result: {id, side, label, expires_at (ms)}; the floating window asks
  /// "won / lost / draw?" once a trade's time is up.
  final List<Json> pending = [];

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
    // the floating window's engine needs a moment to start; repeat until it has surely received the live state
    for (final ms in const [400, 1200, 2500]) {
      unawaited(Future<void>.delayed(Duration(milliseconds: ms), () => active ? _push() : null));
    }
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
      case 'frame':
        await setFrame();
      case 'hello':
        await _push(); // the floating window just started: give it the live state
      case 'fast':
        fast = msg['on'] == true;
        await _push();
      case 'account':
        if (const ['demo', 'real'].contains(msg['value'])) account = msg['value'] as String;
        await _push();
      case 'set_tf':
        await _setting({'candle_timeframe_sec': msg['value']});
      case 'set_dur':
        final d = msg['value'] as int;
        final max = state.settings['trade_duration_max_sec'] as int? ?? d;
        await _setting({'trade_duration_min_sec': d, if (max < d) 'trade_duration_max_sec': d});
      case 'result':
        await recordResult(msg['id'] as int?, msg['outcome'] as String?);
      case 'skip_result':
        pending.removeWhere((p) => p['id'] == msg['id']);
        await _push();
    }
  }

  Future<void> _setting(Json patch) async {
    try {
      await state.updateSettings(patch);
      _last = {..._last, 'error': null};
    } on EngineException catch (e) {
      _last = {..._last, 'error': e.message};
    }
    await _push();
  }

  /// One tap in the floating window: the result of a trade taken from a signal (demo / real as chosen there).
  Future<void> recordResult(int? id, String? outcome) async {
    if (id == null || !const ['win', 'loss', 'draw'].contains(outcome)) return;
    final p = pending.where((x) => x['id'] == id).firstOrNull;
    try {
      await state.engine.resultFromSignal(id, accountType: account, outcome: outcome!, notes: p?['label'] as String?);
      pending.removeWhere((x) => x['id'] == id);
      _last = {..._last, 'error': null, 'note': '${state.t('live_result_saved')}: ${state.t(outcome)}'};
    } on EngineException catch (e) {
      pending.removeWhere((x) => x['id'] == id);
      _last = {..._last, 'error': e.message};
    }
    await _push();
  }

  void setAuto(bool on) {
    auto = on;
    _auto?.cancel();
    _auto = on ? Timer.periodic(const Duration(seconds: 1), (_) => tick()) : null;
    unawaited(_push());
  }

  /// Automatic mode: once per candle, 1 s after it closed (the platform has drawn the closed candle by then).
  Future<void> tick() async {
    final tf = state.settings['candle_timeframe_sec'] as int? ?? 30;
    final t = _now().millisecondsSinceEpoch ~/ 1000;
    final candle = t ~/ tf;
    if (t % tf >= 1 && t % tf <= 6 && candle != _lastCandle && !busy) {
      _lastCandle = candle;
      await analyzeNow();
    }
  }

  /// Capture the trading app as it is now and let the user draw the crop frame on that very picture.
  Future<void> setFrame() async {
    if (busy || !active || onSetFrame == null) return;
    busy = true;
    Uint8List? png;
    try {
      await _push(hide: true);
      await Future<void>.delayed(hideDelay);
      png = await screen.capture();
    } finally {
      busy = false;
      await _push();
    }
    if (png == null) {
      _last = {'error': state.t('live_no_frame')};
      await _push();
      return;
    }
    await onSetFrame!(png);
    _last = {..._last, 'error': null, 'note': state.t('live_frame_saved')};
    await _push();
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
      final r = await state.analyzeChart(image, inputMode: 'screenshot', crop: await crop(), fast: fast);
      _last = summarise(r);
      final a = (r['analysis'] as Map?)?.cast<String, dynamic>() ?? const {};
      final dur = a['duration_sec'] as int?;
      if (a['signal'] != 'WAIT' && a['signal'] != null && a['signal_id'] != null && a['recorded'] == true && dur != null) {
        pending.add({
          'id': a['signal_id'], 'side': a['signal'], 'label': _last['reason'],
          'expires_at': _now().millisecondsSinceEpoch + dur * 1000,
        });
        if (pending.length > 5) pending.removeAt(0);
      }
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
    final read = (a['read'] as Map?)?.cast<String, dynamic>();
    final (head, step, lines) = readText(state.lang, read);
    return {
      'read_bias': read?['bias'],
      'read_head': head,
      'read_step': step,
      'read_lines': lines,
      'signal': a['signal'] ?? 'WAIT',
      'reason': code == 'pattern_signal'
          ? '${state.t('pattern_signal_tag')}: ${[for (final r in (a['reasons'] as List? ?? const [])) factorText(state.lang, '$r').replaceFirst('${state.t('ind_setup')} — ', '')].join('، ')}'
          : code == null
              ? null
              : state.t('reason_$code'),
      'quality': a['data_quality'],
      'duration_sec': a['duration_sec'],
      'confidence': a['confidence'],
      'confidence_calibrated': a['confidence_calibrated'] == true,
      'price': summary?['last_closed_close'],
      'signal_at': t.millisecondsSinceEpoch,
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
      'duration_min_sec': state.settings['trade_duration_min_sec'],
      'fast': fast,
      'account': account,
      'pending': pending,
      'signal': 'WAIT',
      ..._last,
    });
  }

  void dispose() {
    _auto?.cancel();
    _sub?.cancel();
  }
}
