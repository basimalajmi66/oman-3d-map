import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/data/market_data.dart';
import 'package:uata_app/data/paper_trading.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/training_screen.dart';

import 'fake_engine.dart';

class _NoData extends MarketDataClient {
  @override
  Future<List<Bar>> fetchBars(MarketAsset asset, int timeframeSec, DateTime from, DateTime to, {Progress? onProgress}) async => [];
}

void main() {
  testWidgets('paper trading: reachable from Training, needs consent and a strategy, shows sessions', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('uata_paper_ui');
    addTearDown(() => dir.deleteSync(recursive: true));
    final e = FakeEngine()
      ..strategies = [
        {'id': 3, 'name': 'Approved one', 'status': 'approved', 'definition': {'long': {'all': [{'id': 'bullish_candle'}]}, 'duration_sec': 60}},
        {'id': 4, 'name': 'Draft one', 'status': 'draft', 'definition': {'long': {'all': [{'id': 'bearish_candle'}]}, 'duration_sec': 60}},
      ];
    final paper = PaperTrader(dir.path, client: _NoData.new);
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null, paper: paper);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: TrainingScreen())));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_paper')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paper_intro')), findsOneWidget);
    expect(find.text(tr('ar', 'paper_none')), findsOneWidget);
    await tester.tap(find.byKey(const Key('paper_new')));
    await tester.pumpAndSettle();
    final start = find.byKey(const Key('paper_start'));
    expect(tester.widget<FilledButton>(start).onPressed, isNull); // no consent yet
    await tester.tap(find.byKey(const Key('paper_consent')));
    await tester.pump();
    expect(tester.widget<FilledButton>(start).onPressed, isNotNull); // approved strategy pre-selected
    await tester.tap(find.byKey(const Key('paper_pick_3'))); // untick it → nothing chosen
    await tester.pump();
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await tester.tap(find.byKey(const Key('paper_pick_4'))); // drafts can be paper-tested too (no money involved)
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(start);
      await tester.pump();
      for (var k = 0; k < 20 && paper.sessions().isEmpty; k++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(e.settings['external_data_sources_allowed'], true);
    final s = paper.sessions().single;
    expect(s.strategyIds, [4]);
    expect(find.byKey(Key('paper_session_${s.id}')), findsOneWidget);
    expect(find.text(tr('ar', 'paper_no_trades_yet')), findsOneWidget);
    await tester.tap(find.byKey(Key('paper_stop_${s.id}')));
    await tester.pumpAndSettle();
    expect(paper.sessions().single.status, 'stopped');
  });

  test('paper trading never runs during the emergency stop or without consent', () async {
    final dir = Directory.systemTemp.createTempSync('uata_paper_halt');
    final paper = PaperTrader(dir.path, client: _NoData.new);
    final e = FakeEngine();
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null, paper: paper);
    await state.init();
    final s = await paper.start(e, marketAssets.first, 30, 0.85, [1]);
    final before = paper.sessions().single.lastUpdate;
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await state.paperTick(); // no consent → nothing
    expect(paper.sessions().single.lastUpdate, before);
    await state.updateSettings({'external_data_sources_allowed': true});
    await state.emergencyStop();
    await state.paperTick(); // halted → nothing
    expect(paper.sessions().single.lastUpdate, before);
    expect(s.id, isNotEmpty);
    dir.deleteSync(recursive: true);
  });
}
