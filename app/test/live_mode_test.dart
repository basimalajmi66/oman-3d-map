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
    // 30 s candles: 10:00:00 is a close; ticks at +1 (too early), +3 (yes), +4 (same candle), +33 (next candle)
    for (final s in [1, 3, 4, 20, 33]) {
      clock = DateTime(2026, 11, 21, 10, 0, s);
      await live.tick();
      await settle(live);
    }
    expect(screen.captures, 2);
    await live.handle({'cmd': 'stop'});
    expect(state.liveActive || o.active || screen.on, isFalse);
    live.setAuto(false);
  });

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
    expect(find.text(tr('ar', 'buy')), findsOneWidget);
    expect(find.textContaining('3567.95'), findsOneWidget);
    await tester.tap(find.byKey(const Key('overlay_analyze')));
    await tester.tap(find.byKey(const Key('overlay_auto')));
    expect(sent, [{'cmd': 'analyze'}, {'cmd': 'auto', 'on': true}]);
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
    expect(state.liveActive, isTrue);
    expect(find.text(tr('ar', 'live_stop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_live')));
    await tester.pumpAndSettle();
    expect(state.liveActive, isFalse);
  });
}
