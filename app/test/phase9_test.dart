import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/signal_log_screen.dart';

import 'fake_engine.dart';

Future<FakeEngine> pump(WidgetTester tester, FakeEngine e) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SignalLogScreen())));
  await tester.pumpAndSettle();
  return e;
}

void main() {
  testWidgets('record a result straight from a BUY signal; WAIT has no button', (tester) async {
    final e = FakeEngine()
      ..signals.addAll([
        {'id': 7, 'signal': 'BUY', 'asset': 'EURUSD', 'timeframe_sec': 30, 'created_at': '2026-11-17T10:00:00Z'},
        {'id': 8, 'signal': 'WAIT', 'asset': null, 'timeframe_sec': 30, 'created_at': '2026-11-17T10:01:00Z',
          'reasons': ['no_approved_strategy']},
      ]);
    await pump(tester, e);
    expect(find.byKey(const Key('record_8')), findsNothing);
    // why it waited, right in the list
    expect(tester.widget<Text>(find.byKey(const Key('signal_sub_8'))).data, contains(tr('ar', 'reason_no_approved_strategy')));
    await tester.tap(find.byKey(const Key('record_7')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('rr_account')), matching: find.text(tr('ar', 'real'))));
    await tester.tap(find.descendant(of: find.byKey(const Key('rr_outcome')), matching: find.text(tr('ar', 'loss'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rr_save')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('result_from_signal:7:real:loss'));
  });

  testWidgets('statistics per account with CI, insufficient-sample labels and insights', (tester) async {
    final e = FakeEngine()
      ..dashboards = {
        'demo': {
          'account_type': 'demo',
          'signals': {'total': 40, 'BUY': 10, 'SELL': 5, 'WAIT': 25},
          'results': {'trades': 15, 'wins': 9, 'losses': 6, 'decided': 15, 'win_rate': 0.6,
            'win_rate_ci95': [0.357, 0.802], 'sufficient_sample': true},
          'by_condition': [
            {'key': 'trending', 'wins': 8, 'decided': 10, 'win_rate': 0.8, 'win_rate_ci95': [0.49, 0.94], 'sufficient_sample': true},
            {'key': 'ranging', 'wins': 1, 'decided': 5, 'win_rate': 0.2, 'win_rate_ci95': [0.04, 0.62], 'sufficient_sample': false},
          ],
          'training_log': [{'strategy_name': 'Trend buyer', 'version': 1, 'dataset': 'EURUSD', 'oos_trades': 140,
            'oos_expectancy': 0.5, 'qualifies': true}],
        },
        'real': {'account_type': 'real', 'signals': {'total': 40}, 'results': {'trades': 2, 'wins': 1, 'losses': 1,
          'decided': 2, 'win_rate': 0.5, 'sufficient_sample': false}},
      }
      ..insightsByAccount = {
        'demo': [
          {'code': 'condition_better', 'key': 'trending', 'win_rate': 0.8, 'sample': 10, 'overall': 0.6},
          {'code': 'strategy_review_suggested', 'name': 'Trend buyer', 'live_win_rate': 0.3, 'sample': 30,
            'backtest_win_rate': 0.81},
          // two insights with the same code and key (losses concentrated on one value in two fields) used to crash the page
          {'code': 'losses_concentrated', 'field': 'asset', 'key': 'UNKNOWN', 'share': 0.9, 'losses': 9},
          {'code': 'losses_concentrated', 'field': 'timeframe', 'key': 'UNKNOWN', 'share': 0.9, 'losses': 9},
        ],
        'real': [{'code': 'insufficient_sample', 'sample': 2, 'needed': 10}],
      };
    await pump(tester, e);
    await tester.tap(find.text(tr('ar', 'stats_tab')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('dashboard:demo'));
    expect(tester.widget<Text>(find.descendant(of: find.byKey(const Key('kpi_win_rate')), matching: find.byType(Text)).last).data,
        '60.0%');
    expect(find.textContaining('35.7%–80.2%'), findsOneWidget);
    expect(find.textContaining(tr('ar', 'insufficient_sample_label')), findsOneWidget); // ranging group
    expect(find.byKey(const Key('insight_condition_better_trending')), findsOneWidget);
    expect(find.textContaining('80.0%'), findsWidgets);
    expect(find.byKey(const Key('insight_strategy_review_suggested')), findsOneWidget);
    expect(find.text(tr('ar', 'insights_note')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('insight_losses_concentrated_UNKNOWN')), findsOneWidget);
    expect(find.textContaining('Trend buyer v1'), findsOneWidget);
    // switch account: real results are shown on their own
    await tester.tap(find.descendant(of: find.byKey(const Key('stats_account')), matching: find.text(tr('ar', 'real'))));
    await tester.pumpAndSettle();
    expect(e.calls, contains('dashboard:real'));
    expect(find.textContaining('2 نتيجة من أصل 10'), findsOneWidget);
    expect(find.text(tr('ar', 'small_sample')), findsOneWidget);
  });
}
