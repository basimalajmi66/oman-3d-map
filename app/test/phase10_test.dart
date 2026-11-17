import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('engine recovery notice is shown prominently on the panel', (tester) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine()
      ..engineNotices = [{'code': 'database_was_corrupt', 'kept_as': 'uata.sqlite3.corrupt-20261117T120000'}];
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: FloatingPanel())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notice_database_was_corrupt')), findsOneWidget);
    expect(find.textContaining('uata.sqlite3.corrupt-20261117T120000'), findsOneWidget);
  });

  testWidgets('no notice when the engine started normally', (tester) async {
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: FloatingPanel())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notice_database_was_corrupt')), findsNothing);
  });
}
