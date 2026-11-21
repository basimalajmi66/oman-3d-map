import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/engine/strategy/from_text.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/training_screen.dart';

import 'fake_engine.dart';

void main() {
  test('trade duration from the text', () {
    expect(durationFromText('ادخل شراء لمدة دقيقتين'), 120);
    expect(durationFromText('بيع لمدة 3 دقائق'), 180);
    expect(durationFromText('صفقة ٥ دقائق'), 300);
    expect(durationFromText('30 ثانية'), 30);
    expect(durationFromText('buy for 2 minutes'), 120);
    expect(durationFromText('expiry 90s'), 90);
    expect(durationFromText('لمدة دقيقة'), 60);
    expect(durationFromText('بدون مدة'), isNull);
  });

  test('own words (Arabic) → buy / sell / avoid conditions; what cannot be tested is listed, not guessed', () {
    final (def, used, untestable) = strategyFromText(
        'إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فادخل صفقة شراء لمدة 3 دقائق. '
        'وإذا كان في التشبع الشرائي عند المقاومة فادخل بيع. لا تدخل عند صدور الأخبار.');
    expect(((def['long'] as Map)['all'] as List).map((c) => (c as Map)['id']), containsAll(['rsi_below', 'near_support']));
    expect(((def['short'] as Map)['all'] as List).map((c) => (c as Map)['id']), containsAll(['rsi_above', 'near_resistance']));
    expect(def['duration_sec'], 180);
    expect(used, hasLength(2));
    expect(untestable.single, contains('الأخبار'));
  });

  testWidgets('new strategy: write it, convert, save → it is tested on real prices right away and its page opens',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine()
      ..datasets = [
        {'id': 7, 'name': 'synthetic', 'timeframe_sec': 30, 'is_synthetic': 1, 'rows': 100},
        {'id': 8, 'name': 'XAUUSD 30s', 'timeframe_sec': 30, 'is_synthetic': 0, 'rows': 40000},
        {'id': 9, 'name': 'BTC 60s', 'timeframe_sec': 60, 'is_synthetic': 0, 'rows': 4000},
      ];
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await state.updateSettings({'candle_timeframe_sec': 30});
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: TrainingScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new_strategy')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('strategy_text')), 'عند التشبع البيعي عند الدعم ادخل شراء لمدة دقيقتين');
    await tester.pump();
    await tester.tap(find.byKey(const Key('strategy_convert')));
    await tester.pumpAndSettle();
    expect(find.textContaining('RSI'), findsWidgets); // the condition appeared
    await tester.tap(find.byKey(const Key('strategy_save')));
    await tester.pumpAndSettle();
    expect(e.calls.where((c) => c.startsWith('create_strategy:')), hasLength(1));
    expect(e.calls, contains('backtest:${e.strategies.last['id']}:8')); // real 30 s prices, not synthetic, not 60 s
    expect(find.byType(StrategyPage), findsOneWidget);
    expect((e.strategies.last['definition'] as Map)['duration_sec'], 120);
  });

  testWidgets('nothing testable in the text: said so, nothing to save', (tester) async {
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: TrainingScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new_strategy')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('strategy_text')), 'تداول بحكمة وصبر');
    await tester.pump();
    await tester.tap(find.byKey(const Key('strategy_convert')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('strategy_nothing')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('strategy_save'))).onPressed, isNull);
  });
}
