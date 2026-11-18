import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/home/adaptive_home.dart';
import 'package:uata_app/ui/screens/quick_start_screen.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('tablet landscape (like the user\'s screenshot): quick start is visible in Training, top and centre',
      (tester) async {
    tester.view.physicalSize = const Size(2000, 1250);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine()..engineCapabilities = {'engine': 'phone', 'knowledge': false, 'backups': false, 'companion': false};
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!), home: const AdaptiveHome())));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('tablet_rail')), matching: find.text(state.t('training'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open_quick_start')), findsOneWidget);
    expect(find.byKey(const Key('quick_start_big')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick_start_big')));
    await tester.pumpAndSettle();
    expect(find.byType(QuickStartScreen), findsOneWidget);
  });
}
