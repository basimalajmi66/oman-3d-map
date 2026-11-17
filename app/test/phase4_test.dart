import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';

import 'fake_engine.dart';

Future<AppState> pump(WidgetTester tester, FakeEngine e) async {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(home: FloatingPanel(
      pickImage: () async => UploadFile(name: 'c.png', length: 1, openRead: () => Stream.value([0])),
    )),
  ));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('result shows market condition, factors with reasons, levels and the not-a-signal note', (tester) async {
    await pump(tester, FakeEngine());
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'technical')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'mc_trending')), findsOneWidget);
    expect(find.textContaining('${tr('ar', 'bullish_factors')} (2)'), findsOneWidget);
    expect(find.textContaining('${tr('ar', 'bearish_factors')} (1)'), findsOneWidget);
    expect(find.textContaining(tr('ar', 'c_macd_cross_up')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'c_rsi_overbought')), findsOneWidget);
    expect(find.textContaining('1.10120'), findsOneWidget);
    expect(find.textContaining('${tr('ar', 'factors_disabled')}: 1'), findsOneWidget);
    expect(find.text(tr('ar', 'technical_not_signal')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'w_no_volume_data')), findsOneWidget);
  });

  testWidgets('unavailable analysis explains why', (tester) async {
    final e = FakeEngine()..technical = {'available': false, 'reason': 'insufficient_candles', 'candles_used': 19};
    await pump(tester, e);
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('technical_unavailable')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'tr_insufficient_candles')), findsOneWidget);
  });

  testWidgets('relative units are labelled', (tester) async {
    final e = FakeEngine()..technical!['units'] = 'relative';
    await pump(tester, e);
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'units_relative')), findsOneWidget);
  });

  testWidgets('panel shows compact technical line during continuous reading', (tester) async {
    final e = FakeEngine()
      ..session = {'id': 1, 'timeframe_sec': 30, 'input_mode': 'continuous_screen'};
    e.screenWatch = {
      'active': true, 'frames': 2, 'error': null,
      'latest': {'usable': true, 'data_quality': 0.9, 'summary': {'candles': 50}, 'technical': e.technical},
    };
    await pump(tester, e);
    final line = tester.widget<Text>(find.byKey(const Key('watch_technical'))).data!;
    expect(line, contains(tr('ar', 'trend_dir_up')));
    expect(line, contains('↑2 ↓1'));
  });
}
