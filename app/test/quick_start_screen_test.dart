import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/quick_start.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/quick_start_screen.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('needs consent, downloads, shows honest results, approval is a tap per strategy', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine()..strategies = [{'id': 11, 'name': 'Good one', 'status': 'testing'}, {'id': 13, 'name': 'Long one', 'status': 'testing'}];
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    MarketAsset? asked;
    Future<QuickStartResult> runner(api, MarketAsset asset, int tf, double payout, void Function(QuickStartStage, double) on) async {
      asked = asset;
      on(QuickStartStage.downloading, 0.5);
      return QuickStartResult({'id': 1, 'name': 'EURUSD 30s — Dukascopy, 14 days', 'rows': 20000}, [
        StrategyOutcome(13, 'Long one', 'idea', {
          'qualifies': true, 'gate_reasons': [],
          'out_of_sample': {'trades': 31, 'win_rate': 0.6, 'win_rate_ci95': [0.42, 0.76], 'breakeven_win_rate': 0.54, 'expectancy_per_trade': 0.1},
        }, durationSec: 300),
        StrategyOutcome(11, 'Good one', 'idea', {
          'qualifies': true, 'gate_reasons': [],
          'out_of_sample': {'trades': 40, 'win_rate': 0.6, 'win_rate_ci95': [0.45, 0.74], 'breakeven_win_rate': 0.54, 'expectancy_per_trade': 0.11},
        }),
        StrategyOutcome(12, 'Weak one', 'idea', {
          'qualifies': false, 'gate_reasons': ['non_positive_out_of_sample_expectancy'],
          'out_of_sample': {'trades': 35, 'win_rate': 0.5, 'win_rate_ci95': [0.34, 0.66], 'breakeven_win_rate': 0.54, 'expectancy_per_trade': -0.07},
        }),
      ]);
    }

    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: QuickStartScreen(runner: runner))));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('qs_start'))).onPressed, isNull); // no consent yet
    await tester.tap(find.byKey(const Key('qs_consent')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('qs_start')));
    await tester.pumpAndSettle();
    expect(asked!.symbol, 'EURUSD');
    expect(e.settings['external_data_sources_allowed'], true); // consent stored as the user's setting
    expect(find.textContaining('Good one'), findsOneWidget);
    expect(find.text(tr('ar', 'g_non_positive_out_of_sample_expectancy')), findsOneWidget);
    expect(find.byKey(const Key('qs_approve_12')), findsNothing); // a failing strategy cannot be approved here
    await tester.tap(find.byKey(const Key('qs_approve_11')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('approve_strategy:11'));
    expect(find.text(tr('ar', 'approved')), findsWidgets);
    expect(e.settings['trade_duration_max_sec'], 180); // a normal approval leaves your duration range alone
    // a 5-minute strategy says up front that approving also raises your maximum duration
    expect(find.text(tr('ar', 'qs_approve_raise').replaceAll('{s}', '300')), findsOneWidget);
    await tester.tap(find.byKey(const Key('qs_approve_13')));
    await tester.pumpAndSettle();
    expect(e.settings['trade_duration_max_sec'], 300);
    expect(e.calls, contains('approve_strategy:13'));
  });
}
