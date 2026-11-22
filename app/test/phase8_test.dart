import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';

import 'fake_engine.dart';

final steps = [
  for (var i = 1; i <= 14; i++)
    {'n': i, 'name': ['data_validity', 'trend', 'trend_strength', 'previous_candles', 'forming_candle', 'indicators',
      'support_resistance', 'supply_demand', 'strategy_lookup', 'strategy_conditions', 'opposing_factors',
      'opportunity_quality', 'duration', 'reasons'][i - 1], 'status': i < 9 ? 'info' : 'ok', 'detail': 'd$i'},
];

Json buy() => {
      'signal': 'BUY', 'reason_code': 'strategy_signal', 'reasons': ["approved strategy 'Trend buyer' conditions met"],
      'supporting': ['trend: trend_up', 'moving_averages: ma_bull_alignment', 'momentum: mom_bullish'],
      'opposing': ['rsi: rsi_overbought'], 'steps': steps, 'confidence': 0.74, 'confidence_calibrated': false,
      'duration_sec': 60, 'data_quality': 0.9, 'data_basis': 'image_only',
      'strategy': {'id': 3, 'name': 'Trend buyer', 'version': 1, 'oos_trades': 140, 'oos_win_rate': 0.81,
        'oos_win_rate_ci95': [0.74, 0.87], 'oos_expectancy': 0.5, 'significant_edge': true, 'conditions': ['bullish candle']},
    };

Future<AppState> pump(WidgetTester tester, FakeEngine e) async {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: FloatingPanel())));
  await tester.pumpAndSettle();
  return state;
}

void main() {
  testWidgets('BUY lights the green tile and shows duration + uncalibrated confidence', (tester) async {
    final e = FakeEngine()
      ..session = {'id': 1, 'timeframe_sec': 30, 'input_mode': 'upload'}
      ..recommendationOverride = buy();
    await pump(tester, e);
    final buyTile = tester.widget<Material>(find.byKey(const Key('tile_BUY')));
    final waitTile = tester.widget<Material>(find.byKey(const Key('tile_WAIT')));
    expect(buyTile.color!.a, 1.0);
    expect(waitTile.color!.a, lessThan(0.5));
    expect(tester.widget<Text>(find.byKey(const Key('confidence_value'))).data, '74%');
    expect(find.text(tr('ar', 'uncalibrated')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('duration_value'))).data, '60ث');
  });

  testWidgets('signal details: reasons, factors, strategy evidence and all 14 steps', (tester) async {
    final e = FakeEngine()
      ..session = {'id': 1, 'timeframe_sec': 30, 'input_mode': 'upload'}
      ..recommendationOverride = buy();
    await pump(tester, e);
    await tester.tap(find.byKey(const Key('tile_BUY')));
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'reason_strategy_signal')), findsNWidgets(2)); // panel status + details
    expect(find.textContaining(tr('ar', 'c_ma_bull_alignment')), findsOneWidget); // factors shown in the user's language
    expect(find.textContaining(tr('ar', 'c_rsi_overbought')), findsOneWidget);
    expect(find.byKey(const Key('strategy_evidence')), findsOneWidget);
    expect(find.textContaining('74%–87%'), findsOneWidget);
    for (var i = 1; i <= 14; i++) {
      expect(find.byKey(Key('step_$i')), findsOneWidget);
    }
    expect(find.textContaining(tr('ar', 'step_forming_candle')), findsOneWidget);
    expect(find.text(tr('ar', 'manual_only')), findsWidgets);
  });

  testWidgets('WAIT without approved strategy explains how to get signals', (tester) async {
    final e = FakeEngine()
      ..session = {'id': 1, 'timeframe_sec': 30, 'input_mode': 'upload'}
      ..recommendationOverride = {'signal': 'WAIT', 'reason_code': 'no_approved_strategy', 'reasons': <String>[],
        'steps': steps.take(9).map((s) => s['n'] == 9 ? {...s, 'status': 'fail'} : s).toList(), 'confidence': null};
    await pump(tester, e);
    expect(find.text(tr('ar', 'reason_no_approved_strategy')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tile_WAIT')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('step_9')), findsOneWidget);
    expect(find.byKey(const Key('step_10')), findsNothing);
  });
}
