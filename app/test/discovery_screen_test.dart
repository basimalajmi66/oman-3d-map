import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/discovery_screen.dart';
import 'package:uata_app/ui/screens/training_screen.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('search for strategies: phone engine only; without price history it points to quick start', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: TrainingScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_discovery')), findsNothing); // the computer engine has no search yet
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: DiscoveryScreen())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('disc_intro')), findsOneWidget);
    expect(find.text(tr('ar', 'disc_no_data')), findsOneWidget);
    expect(find.byKey(const Key('disc_run')), findsNothing);
  });
}
