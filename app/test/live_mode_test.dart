import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/platform/screen_capture.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/state/live_mode.dart';
import 'package:uata_app/ui/overlay/overlay_app.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';

import 'fake_engine.dart';

class FakeScreen implements ScreenSource {
  bool allow = true, on = false;
  Uint8List? frame = im.encodePng(im.Image(width: 400, height: 200));
  int captures = 0;
  @override
  Future<bool> start() async => on = allow;
  @override
  Future<Uint8List?> capture() async {
    captures++;
    return frame;
  }

  @override
  Future<bool> running() async => on;
  @override
  Future<void> stop() async => on = false;
}

/// Until the live analysis (crop runs in an isolate) has finished.
Future<void> settle(LiveMode live) async {
  await pumpEventQueue();
  for (var k = 0; k < 100 && live.busy; k++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await pumpEventQueue();
}

void main() {
  late FakeEngine e;
  late FakeOverlay o;
  late FakeScreen screen;
  late AppState state;
  late StreamController<dynamic> commands;
  late LiveMode live;
  var clock = DateTime(2026, 11, 21, 10, 0, 0);

  setUp(() async {
    e = FakeEngine();
    o = FakeOverlay();
    screen = FakeScreen();
    commands = StreamController<dynamic>();
    state = AppState(engine: e, window: FakeWindow(), pollInterval: null, overlay: o);
    await state.init();
    live = LiveMode(state: state, screen: screen, crop: () async => (0.1, 0.1, 0.9, 0.9), commands: commands.stream,
        now: () => clock, hideDelay: Duration.zero);
    state.live = live;
  });
  tearDown(() {
    live.dispose();
    commands.close();
  });

  test('start asks for the overlay and screen permissions, records the consent, opens the floating window', () async {
    screen.allow = false;
    expect(await live.start(), 'live_screen_denied');
    expect(state.liveActive, isFalse);
    screen.allow = true;
    o.granted = false;
    o.grantOnRequest = false;
    expect(await live.start(), 'overlay_permission_denied');
    o.grantOnRequest = true;
    expect(await live.start(), isNull);
    expect(state.liveActive && o.active, isTrue);
    expect(e.settings['screen_capture_allowed'], true);
    expect(o.pushed.last['live'], true);
  });

  test('"analyse now": the window hides for the picture, the screen is analysed, the answer comes back', () async {
    await live.start();
    o.pushed.clear();
    commands.add({'cmd': 'analyze'});
    await settle(live);
    expect(o.pushed.first['hide'], true); // never in its own picture
    expect(screen.captures, 1);
    expect(e.calls.where((c) => c.startsWith('chart:screenshot')), hasLength(1));
    final last = o.pushed.last;
    expect(last['hide'], false);
    expect(last['busy'], false);
    expect(last['signal'], isNotNull);
    expect(last['time'], '10:00:00');
    screen.frame = null;
    commands.add({'cmd': 'analyze'});
    await settle(live);
    expect(o.pushed.last['error'], tr('ar', 'live_no_frame'));
  });

  test('automatic mode analyses once per candle, a few seconds after it closed; stop ends everything', () async {
    await live.start();
    live.setAuto(true);
    expect(o.pushed.last['auto'], true);
    // 30 s candles: 10:00:00 is a close; ticks at +0 (too early), +1 (yes), +4 (same candle), +20 (too late), +31 (next)
    for (final s in [0, 1, 4, 20, 31]) {
      clock = DateTime(2026, 11, 21, 10, 0, s);
      await live.tick();
      await settle(live);
    }
    expect(screen.captures, 2);
    await live.handle({'cmd': 'stop'});
    expect(state.liveActive || o.active || screen.on, isFalse);
    live.setAuto(false);
  });

  test('fast reading by default; a pattern signal opens a trade that asks for its result once its time is up', () async {
    await live.start();
    e.analysisExtra = {'signal': 'BUY', 'signal_id': 77, 'recorded': true, 'duration_sec': 60, 'reason_code': 'pattern_signal',
      'reasons': ['setup: hammer']};
    commands.add({'cmd': 'analyze'});
    await settle(live);
    expect(e.calls.last, endsWith(':fast')); // no price-axis reading
    expect(live.pending.single['id'], 77);
    expect(o.pushed.last['pending'], isNotEmpty);
    expect(o.pushed.last['reason'], contains(tr('ar', 'c_hammer')));
    // the result, one tap: recorded on the chosen account
    await live.handle({'cmd': 'account', 'value': 'real'});
    await live.handle({'cmd': 'result', 'id': 77, 'outcome': 'win'});
    expect(e.calls, contains('result_from_signal:77:real:win'));
    expect(live.pending, isEmpty);
    expect(o.pushed.last['note'], contains(tr('ar', 'win')));
    // full reading when switched off
    await live.handle({'cmd': 'fast', 'on': false});
    e.analysisExtra = {};
    commands.add({'cmd': 'analyze'});
    await settle(live);
    expect(e.calls.where((c) => c.startsWith('chart:')).last, isNot(endsWith(':fast')));
  });

  test('quick result buttons: always there — the open trade (even before its time), else the latest signal; none → said so', () async {
    await live.start();
    await live.handle({'cmd': 'quick_result', 'outcome': 'win'});
    expect(o.pushed.last['note'], tr('ar', 'live_no_trade_to_record'));
    e.analysisExtra = {'signal': 'SELL', 'signal_id': 91, 'recorded': true, 'duration_sec': 120, 'reason_code': 'pattern_signal',
      'reasons': ['setup: bearish_engulfing']};
    commands.add({'cmd': 'analyze'});
    await settle(live);
    expect(o.pushed.last['quick_target']['id'], 91);
    await live.handle({'cmd': 'quick_result', 'outcome': 'loss'}); // the trade is still running: recorded anyway
    expect(e.calls, contains('result_from_signal:91:demo:loss'));
    expect(o.pushed.last['quick_target'], isNull); // nothing left to record
    await live.handle({'cmd': 'quick_result', 'outcome': 'win'});
    expect(e.calls.where((c) => c.startsWith('result_from_signal:')), hasLength(1));
  });

  test('candle length and trade duration chosen in the window go to the settings', () async {
    await live.start();
    await live.handle({'cmd': 'set_tf', 'value': 60});
    await live.handle({'cmd': 'set_dur', 'value': 300});
    expect(e.settings['candle_timeframe_sec'], 60);
    expect(e.settings['trade_duration_min_sec'], 300);
    expect((e.settings['trade_duration_max_sec'] as int) >= 300, isTrue);
    expect(o.pushed.last['timeframe_sec'], 60);
    expect(o.pushed.last['duration_min_sec'], 300);
  });

  testWidgets('floating window: candle countdown, "enter now", then the result buttons when the trade is over', (tester) async {
    final updates = StreamController<dynamic>();
    final sent = <Map>[];
    var now = DateTime(2026, 11, 21, 10, 0, 10);
    await tester.pumpWidget(OverlayApp(updates: updates.stream, onClose: () {}, send: sent.add, now: () => now));
    final at = now.millisecondsSinceEpoch;
    updates.add({'live': true, 'lang': 'ar', 'signal': 'BUY', 'duration_sec': 60, 'timeframe_sec': 30, 'duration_min_sec': 60,
      'signal_at': at, 'pending': [{'id': 5, 'side': 'BUY', 'expires_at': at + 60000}]});
    await tester.pumpAndSettle();
    expect(find.textContaining('0:20'), findsWidgets); // 20 s left in the candle
    expect(find.textContaining(tr('ar', 'live_enter_now')), findsOneWidget);
    expect(find.byKey(const Key('overlay_result_wait')), findsOneWidget);
    // a minute later: a new candle (entry passed) and the trade is over → won / lost / draw
    now = now.add(const Duration(seconds: 61));
    updates.add({'live': true, 'lang': 'ar', 'signal': 'BUY', 'duration_sec': 60, 'timeframe_sec': 30, 'duration_min_sec': 60,
      'signal_at': at, 'pending': [{'id': 5, 'side': 'BUY', 'expires_at': at + 60000}]});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overlay_entry')), findsOneWidget);
    expect(
        find.text(tr('ar', 'live_entry_passed')).evaluate().isNotEmpty ||
            find.text(tr('ar', 'live_entry_passed_short')).evaluate().isNotEmpty,
        isTrue);
    await tester.tap(find.byKey(const Key('overlay_result_loss')));
    // candle 30 s and trade 60 s: + / − step through the choices (no drop-down list that the small window cuts off)
    await tester.tap(find.byKey(const Key('overlay_tf_plus')));
    await tester.tap(find.byKey(const Key('overlay_dur_minus')));
    await tester.pumpAndSettle();
    expect(sent, containsAll([
      {'cmd': 'result', 'id': 5, 'outcome': 'loss'},
      {'cmd': 'set_tf', 'value': 60},
      {'cmd': 'set_dur', 'value': 30},
    ]));
    await updates.close();
  });

  for (final (name, size) in const [('the low two-row strip (tablet)', Size(1600, 250)), ('the strip as the tablet really showed it', Size(960, 135)), ('the stacked layout (narrow)', Size(560, 1100))]) {
  testWidgets('$name holds everything at once without overflowing', (tester) async {
    tester.view.physicalSize = size; // the window's pixel size
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final updates = StreamController<dynamic>();
    final now = DateTime(2026, 11, 21, 10, 0, 10);
    await tester.pumpWidget(OverlayApp(updates: updates.stream, onClose: () {}, send: (_) {}, now: () => now));
    final at = now.millisecondsSinceEpoch;
    updates.add({
      'live': true, 'lang': 'ar', 'signal': 'SELL', 'duration_sec': 60, 'timeframe_sec': 30, 'duration_min_sec': 60,
      'signal_at': at, 'time': '10:00:10', 'quality': 0.91, 'price': 2650.5, 'auto': true, 'fast': true, 'account': 'demo',
      'reason': '${tr('ar', 'pattern_signal_tag')}: ${tr('ar', 'c_bearish_engulfing')}، ${tr('ar', 'c_resistance_rejection')}',
      'read_bias': 'down', 'read_head': 'هبوط ↓ · قوية', 'read_step': tr('ar', 'read_sell'), 'read_lines': ['انتبه: دعم قريب عند 2648.7'],
      'pending': [{'id': 1, 'side': 'BUY', 'expires_at': at - 1000}, {'id': 2, 'side': 'SELL', 'expires_at': at + 50000}],
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // the strip shows the signal's reason in place of the chart reading; the stacked layout shows both
    expect(find.byKey(const Key('overlay_read')).evaluate().isNotEmpty || find.byKey(const Key('overlay_reason')).evaluate().isNotEmpty,
        isTrue);
    for (final k in ['overlay_signal', 'overlay_countdown', 'overlay_entry', 'overlay_result', 'overlay_quick',
      'overlay_tf', 'overlay_dur', 'overlay_fast', 'overlay_account_demo', 'overlay_analyze', 'overlay_frame', 'overlay_auto']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    await updates.close();
  });
  }

  test('"set frame": the trading app is captured (window hidden) and handed to the crop screen', () async {
    final frames = <int>[];
    final l2 = LiveMode(state: state, screen: screen, crop: () async => null, hideDelay: Duration.zero,
        onSetFrame: (png) async => frames.add(png.length));
    await l2.start();
    o.pushed.clear();
    await l2.handle({'cmd': 'frame'});
    expect(o.pushed.first['hide'], true);
    expect(frames, [screen.frame!.length]);
    expect(o.pushed.last['note'], tr('ar', 'live_frame_saved'));
    l2.dispose();
  });

  test('the window asks for the state when it starts ("hello") and gets the live card', () async {
    await live.start();
    o.pushed.clear();
    commands.add({'cmd': 'hello'});
    await pumpEventQueue();
    expect(o.pushed.single['live'], true);
  });

  test('the regular status updates never overwrite the live window', () async {
    await live.start();
    final n = o.pushed.length;
    await state.refresh();
    expect(o.pushed.length, n);
  });

  testWidgets('floating window: live card sends its commands; hidden while the picture is taken', (tester) async {
    final updates = StreamController<dynamic>();
    final sent = <Map>[];
    await tester.pumpWidget(OverlayApp(updates: updates.stream, onClose: () {}, send: sent.add));
    updates.add({'live': true, 'lang': 'ar', 'signal': 'BUY', 'duration_sec': 60, 'reason': 'سبب', 'quality': 0.9, 'price': 3567.95, 'auto': false});
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'buy')), findsWidgets);
    expect(find.textContaining('3567.95'), findsOneWidget);
    await tester.tap(find.byKey(const Key('overlay_analyze')));
    await tester.tap(find.byKey(const Key('overlay_auto')));
    expect(sent, [{'cmd': 'hello'}, {'cmd': 'analyze'}, {'cmd': 'auto', 'on': true}]); // hello: ask for the state on start
    // the chart reading: direction and the next step, shown under the strategy badge
    updates.add({'live': true, 'lang': 'ar', 'signal': 'WAIT', 'read_bias': 'up', 'read_head': 'صعود ↑ · قوية',
      'read_step': tr('ar', 'read_buy'), 'read_lines': ['انتبه: مقاومة قريبة عند 3570.5']});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overlay_read')), findsOneWidget);
    expect(find.textContaining('صعود ↑ · قوية'), findsOneWidget);
    expect(find.textContaining(tr('ar', 'read_buy')), findsOneWidget);
    expect(find.textContaining('3570.5'), findsOneWidget);
    updates.add({'live': true, 'hide': true});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overlay_analyze')), findsNothing);
    await updates.close();
  });

  testWidgets('panel: the "analyse over the trading app" button starts and stops live mode', (tester) async {
    tester.view.physicalSize = const Size(500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: Scaffold(body: FloatingPanel()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_live')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // the repeated state pushes to the starting window
    expect(state.liveActive, isTrue);
    expect(find.byKey(const Key('btn_overlay')), findsNothing); // the live button replaces the old window button
    expect(find.text(tr('ar', 'live_stop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_live')));
    await tester.pumpAndSettle();
    expect(state.liveActive, isFalse);
  });
}
