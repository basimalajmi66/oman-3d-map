import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/chart_result.dart';
import 'package:uata_app/ui/screens/quick_start_screen.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('WAIT for lack of a tested strategy offers the way to get one (quick start)', (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(home: Builder(builder: (ctx) {
        return TextButton(
          onPressed: () => showChartResult(ctx, {
            'input': {'width': 800, 'height': 450},
            'analysis': {'signal': 'WAIT', 'reason_code': 'no_approved_strategy', 'data_quality': 0.91},
          }),
          child: const Text('show'),
        );
      })),
    ));
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chart_result_get_strategy')));
    await tester.pumpAndSettle();
    expect(find.byType(QuickStartScreen), findsOneWidget);
    expect(find.byKey(const Key('chart_result_get_strategy')), findsNothing); // the result dialog closed
  });
}
