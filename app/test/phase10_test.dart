import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';
import 'package:uata_app/ui/screens/settings_screen.dart';

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

  testWidgets('settings show what this installation can do', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine();
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'installation_section')), findsOneWidget);
    expect(find.text('ara, eng'), findsOneWidget);
    final stt = tester.widget<ListTile>(find.byKey(const Key('cap_speech_to_text')));
    expect((stt.leading as Icon).icon, Icons.remove_circle_outline);
    await tester.tap(find.byKey(const Key('edit_stt_path')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('stt_path_field')), 'C:/models/whisper-small');
    await tester.tap(find.text(tr('ar', 'save')).last);
    await tester.pumpAndSettle();
    expect(e.settings['stt_model_path'], 'C:/models/whisper-small');
  });
}
