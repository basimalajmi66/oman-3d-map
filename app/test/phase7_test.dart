import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/training_screen.dart';

import 'fake_engine.dart';

Json metrics({int trades = 45, double? exp = 0.12, bool sig = false}) => {
      'trades': trades, 'win_rate': 0.6, 'win_rate_ci95': [0.45, 0.73], 'breakeven_win_rate': 0.5405,
      'expectancy_per_trade': exp, 'profit_factor': 1.3, 'max_drawdown_units': 4.2, 'significant_edge': sig,
      'by_condition': {'trending': {'trades': 20, 'expectancy_per_trade': 0.2}, 'ranging': {'trades': 25, 'expectancy_per_trade': 0.05},
        'volatile': {'trades': 0, 'expectancy_per_trade': null}},
    };

Future<void> pump(WidgetTester tester, FakeEngine e, Widget home) async {
  tester.view.physicalSize = const Size(1000, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

Json strategy(int id, {String status = 'draft'}) => {
      'id': id, 'name': 'Strategy $id', 'status': status, 'version': 1, 'description': '',
      'definition': {'long': {'all': [{'id': 'bullish_candle'}]}, 'short': {'all': []}, 'veto': [],
        'duration_sec': 60, 'untestable': ['Avoid news']},
      'readable_ar': {'long': ['شمعة صاعدة'], 'short': <String>[], 'veto': <String>[]},
      'readable': {'long': ['bullish candle'], 'short': <String>[], 'veto': <String>[]},
      'latest_backtest': null,
    };

void main() {
  testWidgets('build a strategy from the condition catalog', (tester) async {
    final e = FakeEngine();
    await pump(tester, e, const TrainingScreen());
    expect(find.byKey(const Key('no_strategies')), findsOneWidget);
    await tester.tap(find.byKey(const Key('new_strategy')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('strategy_save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('strategy_name')), 'Bull');
    await tester.tap(find.byKey(const Key('add_long')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cond_bullish_candle')));
    await tester.pumpAndSettle();
    expect(find.text('• شمعة صاعدة'), findsOneWidget);
    await tester.tap(find.byKey(const Key('strategy_save')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('create_strategy:Bull'));
    expect(e.strategies.single['definition']['long']['all'], [{'id': 'bullish_candle'}]);
  });

  testWidgets('strategy page: conditions, untestable rules, backtest IS vs OOS, approval refused with reasons', (tester) async {
    final e = FakeEngine()
      ..strategies = [strategy(1)]
      ..datasets = [{'id': 9, 'name': 'SYNTHETIC', 'rows': 3000, 'timeframe_sec': 30, 'is_synthetic': 1}]
      ..backtestResult = {
        'qualifies': false, 'synthetic': true, 'gate_reasons': ['tested_on_synthetic_data_only'],
        'in_sample': metrics(), 'out_of_sample': metrics(trades: 20, exp: -0.05),
      }
      ..approveRefusal = ['tested_on_synthetic_data_only', 'too_few_out_of_sample_trades'];
    await pump(tester, e, const StrategyPage(strategyId: 1));
    expect(find.text('• شمعة صاعدة'), findsOneWidget);
    expect(find.byKey(const Key('untestable')), findsOneWidget);
    expect(find.text('• Avoid news'), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_backtest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_dataset_9')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('backtest:1:9'));
    expect(find.text(tr('ar', 'not_qualifies')), findsOneWidget);
    expect(find.byKey(const Key('m_in_sample')), findsOneWidget);
    expect(find.byKey(const Key('m_out_of_sample')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'g_tested_on_synthetic_data_only')), findsWidgets);
    expect(find.textContaining(tr('ar', 'no_significant_edge')), findsWidgets);
    await tester.tap(find.byKey(const Key('btn_approve_strategy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('approval_refused')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'g_too_few_out_of_sample_trades')), findsOneWidget);
    expect(e.strategies.single['status'], 'draft');
  });

  testWidgets('approval succeeds when the engine allows it', (tester) async {
    final e = FakeEngine()..strategies = [strategy(2, status: 'testing')];
    await pump(tester, e, const StrategyPage(strategyId: 2));
    await tester.tap(find.byKey(const Key('btn_approve_strategy')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('approval_refused')), findsNothing);
    expect(find.text(tr('ar', 'st_approved')), findsOneWidget);
  });

  testWidgets('compare needs two selected strategies and shows a separate row each', (tester) async {
    final e = FakeEngine()
      ..strategies = [strategy(1), strategy(2)]
      ..datasets = [{'id': 5, 'name': 'EURUSD', 'rows': 2000, 'timeframe_sec': 30, 'is_synthetic': 0}];
    await pump(tester, e, const TrainingScreen());
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('btn_compare'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('select_1')));
    await tester.tap(find.byKey(const Key('select_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_compare')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick_dataset_5')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('compare:1,2:5'));
    expect(find.byKey(const Key('compare_table')), findsOneWidget);
    expect(find.text('S1'), findsOneWidget);
    expect(find.text('S2'), findsOneWidget);
  });

  testWidgets('datasets: import CSV, synthetic data is labelled', (tester) async {
    final e = FakeEngine();
    await pump(tester, e, TrainingScreen(
      pickCsvFn: () async => UploadFile(name: 'eurusd.csv', length: 3, openRead: () => Stream.value([1, 2, 3])),
    ));
    await tester.tap(find.text(tr('ar', 'datasets_tab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no_datasets')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_import_csv')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('import:eurusd.csv'));
    await tester.tap(find.byKey(const Key('btn_synthetic')));
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'synthetic_label')), findsOneWidget);
  });
}
