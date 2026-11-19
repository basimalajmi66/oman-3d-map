import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/platform/share_intake.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';
import 'package:uata_app/ui/screens/mode_choice_screen.dart';
import 'package:uata_app/ui/screens/settings_screen.dart';

import 'fake_engine.dart';
import 'phase2_test.dart' show ListShareSource;

/// What the phone engine declares (see LocalEngineApi.capabilities).
const phoneCaps = {
  'engine': 'phone', 'ocr': false, 'ocr_languages': <String>[], 'speech_to_text': false, 'ffmpeg': false,
  'screen_capture': false, 'knowledge': false, 'videos': false, 'backups': true, 'companion': false,
};

Future<AppState> phoneState(FakeEngine e, {Future<void> Function()? onSwitch}) async {
  e.engineCapabilities = {...phoneCaps};
  final s = AppState(engine: e, window: FakeWindow(), pollInterval: null, onSwitchMode: onSwitch);
  await s.init();
  return s;
}

void main() {
  testWidgets('first launch asks where analysis runs; "on this phone" is recommended', (tester) async {
    String? chosen;
    await tester.pumpWidget(MaterialApp(home: ModeChoiceScreen(onChosen: (m) => chosen = m)));
    expect(find.textContaining(tr('ar', 'mode_recommended')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mode_local')));
    expect(chosen, 'local');
    await tester.tap(find.byKey(const Key('mode_remote')));
    expect(chosen, 'remote');
  });

  testWidgets('phone engine: the library button is hidden, the rest stays', (tester) async {
    final state = await phoneState(FakeEngine());
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: FloatingPanel())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nav_library')), findsNothing);
    expect(find.byKey(const Key('nav_training')), findsOneWidget);
    expect(find.byKey(const Key('nav_log')), findsOneWidget);
    expect(find.byKey(const Key('nav_settings')), findsOneWidget);
  });

  testWidgets('computer engine: the library button is shown', (tester) async {
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: FloatingPanel())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nav_library')), findsOneWidget);
  });

  testWidgets('phone settings: backups yes, companion no, mode can be switched', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var switched = false;
    final e = FakeEngine();
    final state = await phoneState(e, onSwitch: () async => switched = true);
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'mode_local')), findsOneWidget);
    expect(find.byKey(const Key('btn_backup')), findsOneWidget); // encrypted backups work on the phone
    expect(find.byKey(const Key('companion_toggle')), findsNothing);
    expect(find.byKey(const Key('btn_wipe')), findsOneWidget); // delete-all always available
    await tester.tap(find.byKey(const Key('btn_switch_to_computer')));
    await tester.pumpAndSettle();
    expect(switched, true);
  });

  test('phone engine: shared documents are reported unsupported, chart images are analysed', () async {
    final dir = Directory.systemTemp.createTempSync('uata_share');
    final pdf = File('${dir.path}/book.pdf')..writeAsBytesSync([1, 2, 3]);
    final e = FakeEngine();
    final intake = ShareIntake(engine: e, source: ListShareSource(const []), onOutcomes: (_) {}, libraryAvailable: false);
    final out = await intake.process([SharedItem(pdf.path)]);
    expect(out.single.kind, ShareOutcomeKind.unsupported);
    dir.deleteSync(recursive: true);
  });

  testWidgets('a backup can be saved as a copy outside the app; cancelling says nothing', (tester) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine();
    e.backups.add({'name': 'uata-backup-20261119T100000.uatabak', 'size_bytes': 1234});
    final state = await phoneState(e);
    final saved = <String>[];
    var answer = true;
    await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(home: SettingsScreen(saveFile: (name, bytes) async {
          saved.add('$name:${bytes.length}');
          return answer;
        }))));
    await tester.pumpAndSettle();
    final name = (await e.listBackups()).first['name'] as String;
    await tester.tap(find.byKey(Key('save_backup_$name')));
    await tester.pumpAndSettle();
    expect(saved, ['$name:4']);
    expect(find.text(tr('ar', 'saved')), findsOneWidget);
    answer = false;
    await tester.tap(find.byKey(Key('save_backup_$name')));
    await tester.pump();
    expect(find.textContaining(tr('ar', 'error')), findsNothing);
  });
}
