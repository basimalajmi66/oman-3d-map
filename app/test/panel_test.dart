import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/main.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/knowledge_screen.dart';
import 'package:uata_app/ui/screens/settings_screen.dart';

import 'fake_engine.dart';

Future<(FakeEngine, FakeWindow, AppState)> pumpApp(WidgetTester tester, {FakeEngine? engine, Size size = const Size(400, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final e = engine ?? FakeEngine();
  final w = FakeWindow();
  final state = AppState(engine: e, window: w, pollInterval: null);
  await state.init();
  await tester.pumpWidget(UataApp(state: state));
  await tester.pumpAndSettle();
  return (e, w, state);
}

void main() {
  testWidgets('panel shows all controls and WAIT by default (Arabic, RTL)', (tester) async {
    await pumpApp(tester);
    for (final k in ['tile_BUY', 'tile_SELL', 'tile_WAIT', 'btn_start', 'btn_stop', 'btn_emergency', 'nav_library',
      'nav_training', 'nav_log', 'nav_settings']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.text(tr('ar', 'state_idle')), findsOneWidget);
    expect(find.text('30ث'), findsOneWidget); // default 30-second candle
    expect(Directionality.of(tester.element(find.byKey(const Key('btn_start')))), TextDirection.rtl);
    // WAIT tile is the highlighted one
    final wait = tester.widget<Material>(find.byKey(const Key('tile_WAIT')));
    final buy = tester.widget<Material>(find.byKey(const Key('tile_BUY')));
    expect(wait.color!.a, 1.0);
    expect(buy.color!.a, lessThan(0.5));
  });

  testWidgets('start shows honest no-engine state, stop returns to idle', (tester) async {
    final (e, _, _) = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('btn_start')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('start:upload'));
    expect(find.text(tr('ar', 'state_running_no_engine')), findsOneWidget);
    expect(find.text(tr('ar', 'reason_analysis_engine_not_installed')), findsOneWidget);
    expect(find.byKey(const Key('confidence_value')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('confidence_value'))).data, '—'); // no fake number
    await tester.tap(find.byKey(const Key('btn_stop')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'state_idle')), findsOneWidget);
  });

  testWidgets('emergency stop halts and revokes screen permission', (tester) async {
    final e = FakeEngine()..settings['screen_capture_allowed'] = true;
    final (_, _, state) = await pumpApp(tester, engine: e);
    await tester.tap(find.byKey(const Key('btn_start')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_emergency')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'state_halted')), findsOneWidget);
    expect(state.settings['screen_capture_allowed'], false);
  });

  testWidgets('signal tiles open details, never trade', (tester) async {
    final (e, _, _) = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('tile_BUY')));
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'signal_details')), findsOneWidget);
    expect(find.text(tr('ar', 'confidence_note')), findsOneWidget);
    expect(e.calls.where((c) => !c.startsWith('patch')), isEmpty); // no engine action from a tile
  });

  testWidgets('offline engine: controls disabled, retry shown', (tester) async {
    final e = FakeEngine()..online = false;
    await pumpApp(tester, engine: e);
    expect(find.text(tr('ar', 'state_offline')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('btn_start'))).onPressed, isNull);
    e.online = true;
    await tester.tap(find.text(tr('ar', 'retry')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'state_idle')), findsOneWidget);
  });

  testWidgets('switching language to English flips direction', (tester) async {
    final (_, _, state) = await pumpApp(tester);
    await state.updateSettings({'language': 'en'});
    await tester.pumpAndSettle();
    expect(find.text('Analysis stopped'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byKey(const Key('btn_start')))), TextDirection.ltr);
  });

  testWidgets('dark theme setting applies', (tester) async {
    final (_, _, state) = await pumpApp(tester);
    await state.updateSettings({'theme': 'dark'});
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
  });

  testWidgets('navigation expands window and restores it on return', (tester) async {
    final (_, w, _) = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('nav_training')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'training_title')), findsOneWidget);
    expect(find.text(tr('ar', 'strategies_tab')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(w.calls, ['expanded:true', 'expanded:false']);
  });

  testWidgets('library: add note, approve item, search', (tester) async {
    // wide tablet: panel pinned + library in split (list + detail) mode
    final (e, _, _) = await pumpApp(tester, size: const Size(1500, 900));
    await tester.tap(find.byKey(const Key('nav_library')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'empty_library')), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_note')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('note_save'))).onPressed, isNull); // empty form
    await tester.enterText(find.byKey(const Key('note_title')), 'شمعة المطرقة');
    await tester.enterText(find.byKey(const Key('note_content')), 'المطرقة عند الدعم إشارة انعكاس محتملة');
    await tester.pump();
    await tester.tap(find.byKey(const Key('note_save')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('note:شمعة المطرقة'));
    expect(find.text(tr('ar', 'pending_review')), findsOneWidget);

    final itemId = (e.sources.first['items'] as List).first['id'];
    await tester.tap(find.byKey(Key('approve_$itemId')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('approve:$itemId'));
    expect(find.text(tr('ar', 'approved')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search_field')), 'الدعم');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('المطرقة عند الدعم'), findsWidgets);
  });

  testWidgets('library: upload file, duplicate rejected, delete source', (tester) async {
    final e = FakeEngine();
    late AppState state;
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    Future<UploadFile?> pick() async => UploadFile(name: 'lesson.pdf', length: 3, openRead: () => Stream.value([1, 2, 3]));
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(home: KnowledgeScreen(pickFile: pick)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add_file')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('upload:lesson.pdf'));
    expect(find.text(tr('ar', 'extraction_unsupported_yet'), findRichText: true), findsNothing);
    expect(find.textContaining(tr('ar', 'extraction_unsupported_yet')), findsOneWidget);

    await tester.tap(find.byKey(const Key('add_file')));
    await tester.pumpAndSettle();
    expect(find.textContaining(tr('ar', 'duplicate_file')), findsOneWidget);

    // the full text read from a source (e.g. a video's transcript) can be shown and copied
    final sid = e.sources.first['id'] as int;
    e.sources.first['extracted_chars'] = 22;
    e.sourceTexts[sid] = 'buy when RSI is below 30';
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text(e.sources.first['title'] as String).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show_full_text')));
    await tester.pumpAndSettle();
    expect(find.text('buy when RSI is below 30'), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy_full_text')));
    await tester.pumpAndSettle();
    expect(copied, ['buy when RSI is below 30']);
    await tester.tap(find.text(tr('ar', 'close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_source')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete')));
    await tester.pumpAndSettle();
    expect(e.sources, isEmpty);
    expect(find.text(tr('ar', 'empty_library')), findsOneWidget);
  });

  testWidgets('signal log: record a demo result', (tester) async {
    final (e, _, _) = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('nav_log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('no_signals')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_result')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('result_asset')), 'EURUSD');
    await tester.pump();
    await tester.tap(find.byKey(const Key('result_save')));
    await tester.pumpAndSettle();
    expect(e.results.single['asset'], 'EURUSD');
    expect(e.results.single['account_type'], 'demo');
    expect(e.results.single['timeframe_sec'], 30);
  });

  testWidgets('settings: toggle indicator, permission needs confirmation, backup, wipe', (tester) async {
    final e = FakeEngine();
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
    await state.init();
    await tester.pumpWidget(AppScope(state: state, child: const MaterialApp(home: SettingsScreen())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ind_rsi')));
    await tester.pumpAndSettle();
    expect((e.settings['indicators'] as Map)['rsi'], false);

    final screenSwitch = find.byKey(const Key('sw_screen'));
    await tester.scrollUntilVisible(screenSwitch, 300);
    await tester.tap(screenSwitch);
    await tester.pumpAndSettle();
    expect(e.settings['screen_capture_allowed'], false); // not yet: confirmation dialog open
    await tester.tap(find.byKey(const Key('grant_screen')));
    await tester.pumpAndSettle();
    expect(e.settings['screen_capture_allowed'], true);

    await tester.scrollUntilVisible(find.byKey(const Key('btn_backup')), 300);
    await tester.tap(find.byKey(const Key('btn_backup')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pass1')), 'long-passphrase');
    await tester.enterText(find.byKey(const Key('pass2')), 'different-pass');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('pass_ok'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pass2')), 'long-passphrase');
    await tester.pump();
    await tester.tap(find.byKey(const Key('pass_ok')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('backup'));
    expect(find.text('uata-backup-0.uatabak'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.byType(SettingsScreen))).removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('btn_wipe')), 300);
    await tester.ensureVisible(find.byKey(const Key('btn_wipe'))); // the backup list is taller now (hint + copy button)
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_wipe')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('wipe_text')), 'delete');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('wipe_ok'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('wipe_text')), 'DELETE ALL MY DATA');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wipe_ok')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('wipe:false'));
  });

  test('every UI string has Arabic and English', () {
    for (final key in ['buy', 'sell', 'wait', 'state_idle', 'state_running_no_engine', 'state_halted', 'state_offline']) {
      expect(tr('ar', key), isNot(key));
      expect(tr('en', key), isNot(key));
    }
  });
}
