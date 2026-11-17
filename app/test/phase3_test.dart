import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/window_controller.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';
import 'package:uata_app/ui/screens/settings_screen.dart';

import 'fake_engine.dart';

class DesktopFakeWindow extends FakeWindow {
  @override
  bool get isDesktop => true;
}

Future<AppState> pump(WidgetTester tester, FakeEngine e, {Widget? home, bool desktop = true}) async {
  tester.view.physicalSize = const Size(420, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final WindowController w = desktop ? DesktopFakeWindow() : FakeWindow();
  final state = AppState(engine: e, window: w, pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(home: home ?? FloatingPanel(
      pickImage: () async => UploadFile(name: 'c.png', length: 1, openRead: () => Stream.value([0])),
    )),
  ));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('capture button only on desktop with screen permission', (tester) async {
    final e = FakeEngine();
    await pump(tester, e);
    expect(find.byKey(const Key('btn_capture')), findsNothing);
    final e2 = FakeEngine()..settings['screen_capture_allowed'] = true;
    await pump(tester, e2);
    expect(find.byKey(const Key('btn_capture')), findsOneWidget);
    await pump(tester, FakeEngine()..settings['screen_capture_allowed'] = true, desktop: false);
    expect(find.byKey(const Key('btn_capture')), findsNothing); // mobile: share sheet instead
  });

  testWidgets('capture shows the full reading and the detection preview', (tester) async {
    final e = FakeEngine()..settings['screen_capture_allowed'] = true;
    await pump(tester, e);
    await tester.tap(find.byKey(const Key('btn_capture')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('capture'));
    expect(find.text(tr('ar', 'reason_signal_engine_not_installed')), findsOneWidget);
    expect(find.textContaining('${tr('ar', 'candles_detected')}: 50'), findsOneWidget);
    expect(find.textContaining('1.10234'), findsOneWidget);
    expect(find.textContaining(tr('ar', 'prices_read')), findsOneWidget);
    expect(find.text(tr('ar', 'forming_note')), findsOneWidget);
    expect(find.byKey(const Key('tf_mismatch')), findsNothing);
    await tester.tap(find.byKey(const Key('show_detection')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('annotated_image')), findsOneWidget);
  });

  testWidgets('abstained reading lists reasons; relative-only prices; timeframe mismatch warned', (tester) async {
    final e = FakeEngine()
      ..reading = {
        'usable': false, 'abstain_reasons': ['image_quality_below_threshold'], 'data_quality': 0.41,
        'candles': 12, 'closed_candles': 11, 'bullish': 5, 'bearish': 6, 'last_closed_direction': 'down',
        'last_closed_close': null, 'prices_read': false, 'timeframe_sec': 60, 'timeframe_label': 'M1',
        'warnings': ['blurry'],
      };
    await pump(tester, e);
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'reason_image_quality_insufficient')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'a_image_quality_below_threshold')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'prices_not_read')), findsOneWidget);
    expect(find.byKey(const Key('tf_mismatch')), findsOneWidget); // image says 1m, settings 30s
    expect(find.textContaining(tr('ar', 'w_blurry')), findsOneWidget);
    expect(find.text('41%', findRichText: true), findsNothing);
    expect(find.textContaining('41%'), findsOneWidget);
  });

  testWidgets('start uses continuous screen mode only when enabled and permitted', (tester) async {
    final e = FakeEngine();
    final state = await pump(tester, e);
    expect(state.defaultInputMode, 'upload');
    await state.updateSettings({'continuous_analysis': true});
    expect(state.defaultInputMode, 'upload'); // no permission yet
    await state.updateSettings({'screen_capture_allowed': true});
    expect(state.defaultInputMode, 'continuous_screen');
    await tester.tap(find.byKey(const Key('btn_start')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('start:continuous_screen'));
  });

  testWidgets('panel shows latest continuous reading and capture errors', (tester) async {
    final e = FakeEngine()
      ..session = {'id': 1, 'timeframe_sec': 30, 'input_mode': 'continuous_screen'}
      ..screenWatch = {
        'active': true, 'frames': 3, 'error': null,
        'latest': {'usable': true, 'data_quality': 0.88, 'summary': {'candles': 64}},
      };
    final state = await pump(tester, e);
    expect(find.byKey(const Key('watch_line')), findsOneWidget);
    expect(find.textContaining('64'), findsWidgets);
    expect(find.textContaining('88%'), findsOneWidget);
    e.screenWatch = {'active': false, 'frames': 0, 'error': 'screen capture failed: no display', 'latest': null};
    await state.refresh();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('watch_error')), findsOneWidget);
  });

  testWidgets('settings: capture section appears with permission; region editor saves', (tester) async {
    final e = FakeEngine()..settings['screen_capture_allowed'] = true;
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'capture_section')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('seg_region')), 300);
    await tester.tap(find.text(tr('ar', 'custom_region')));
    await tester.pumpAndSettle();
    expect(e.settings['capture_region'], {'left': 0, 'top': 0, 'width': 1000, 'height': 600});
    await tester.enterText(find.byKey(const Key('region_width')), '1280');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((e.settings['capture_region'] as Map)['width'], 1280);
    await tester.tap(find.text(tr('ar', 'full_screen')));
    await tester.pumpAndSettle();
    expect(e.settings['capture_region'], isNull);
  });
}
