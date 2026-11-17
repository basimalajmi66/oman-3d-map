import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/engine_host.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/main.dart';
import 'package:uata_app/platform/share_intake.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/overlay/overlay_app.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';

import 'fake_engine.dart';

Future<AppState> pump(WidgetTester tester, {required Size size, FakeEngine? engine, FakeOverlay? overlay, Widget? home}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: engine ?? FakeEngine(), window: FakeWindow(), pollInterval: null, overlay: overlay);
  await state.init();
  await tester.pumpWidget(home == null
      ? UataApp(state: state)
      : AppScope(state: state, child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
  return state;
}

class ListShareSource implements ShareSource {
  ListShareSource(this.first);
  final List<SharedItem> first;
  bool resetCalled = false;
  @override
  Future<List<SharedItem>> initial() async => first;
  @override
  Stream<List<SharedItem>> stream() => const Stream.empty();
  @override
  Future<void> reset() async => resetCalled = true;
}

void main() {
  group('adaptive layout', () {
    testWidgets('phone width shows the panel only', (tester) async {
      await pump(tester, size: const Size(390, 844));
      expect(find.byKey(const Key('tablet_rail')), findsNothing);
      expect(find.byKey(const Key('btn_start')), findsOneWidget);
    });

    testWidgets('tablet portrait: rail, panel as first pane, navigation switches pane', (tester) async {
      await pump(tester, size: const Size(800, 1200));
      expect(find.byKey(const Key('tablet_rail')), findsOneWidget);
      expect(find.byKey(const Key('pinned_panel')), findsNothing);
      await tester.tap(find.text(tr('ar', 'log')).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no_signals')), findsOneWidget);
      expect(find.byKey(const Key('btn_start')), findsNothing);
    });

    testWidgets('tablet landscape: panel pinned beside the selected screen', (tester) async {
      await pump(tester, size: const Size(1280, 800));
      expect(find.byKey(const Key('pinned_panel')), findsOneWidget);
      expect(find.text(tr('ar', 'empty_library')), findsOneWidget); // library shown by default
      // panel nav buttons select the pane instead of pushing a route
      await tester.tap(find.byKey(const Key('nav_training')));
      await tester.pumpAndSettle();
      expect(find.text(tr('ar', 'training_title')), findsOneWidget);
      expect(find.byKey(const Key('btn_start')), findsOneWidget);
    });
  });

  group('chart images', () {
    testWidgets('analyze image shows honest WAIT result with image size', (tester) async {
      final e = FakeEngine();
      await pump(tester, size: const Size(390, 844), engine: e, home: FloatingPanel(
        pickImage: () async => UploadFile(name: 'chart.png', length: 3, openRead: () => Stream.value([1, 2, 3])),
      ));
      await tester.tap(find.byKey(const Key('btn_analyze_image')));
      await tester.pumpAndSettle();
      expect(e.calls, contains('chart:upload:chart.png'));
      expect(find.text(tr('ar', 'chart_result')), findsOneWidget);
      expect(find.text(tr('ar', 'reason_analysis_engine_not_installed')), findsOneWidget);
      expect(find.textContaining('800×450'), findsOneWidget);
      expect(find.textContaining(tr('ar', 'image_only')), findsOneWidget);
    });

    testWidgets('cancelled picker does nothing; engine error is shown', (tester) async {
      final e = FakeEngine();
      var name = '';
      await pump(tester, size: const Size(390, 844), engine: e, home: FloatingPanel(
        pickImage: () async => name.isEmpty ? null : UploadFile(name: name, length: 1, openRead: () => Stream.value([0])),
      ));
      await tester.tap(find.byKey(const Key('btn_analyze_image')));
      await tester.pumpAndSettle();
      expect(e.calls.where((c) => c.startsWith('chart')), isEmpty);
      name = 'doc.pdf';
      await tester.tap(find.byKey(const Key('btn_analyze_image')));
      await tester.pumpAndSettle();
      expect(find.textContaining('not an image'), findsOneWidget);
    });
  });

  group('android overlay', () {
    testWidgets('button hidden where overlay unsupported', (tester) async {
      await pump(tester, size: const Size(390, 844));
      expect(find.byKey(const Key('btn_overlay')), findsNothing);
    });

    testWidgets('asks permission, shows overlay and pushes state updates', (tester) async {
      final ov = FakeOverlay();
      final state = await pump(tester, size: const Size(390, 844), overlay: ov);
      await tester.tap(find.byKey(const Key('btn_overlay')));
      await tester.pumpAndSettle();
      expect(ov.granted, isTrue);
      expect(ov.active, isTrue);
      expect(ov.pushed.last['signal'], 'WAIT');
      expect(ov.pushed.last['state'], 'idle');
      await state.startAnalysis();
      expect(ov.pushed.last['state'], 'running_no_engine');
      expect(ov.pushed.last['timeframe_sec'], 30);
      await tester.tap(find.byKey(const Key('btn_overlay')));
      await tester.pumpAndSettle();
      expect(ov.active, isFalse);
    });

    testWidgets('permission refused: overlay not shown, user told why', (tester) async {
      final ov = FakeOverlay()..grantOnRequest = false;
      await pump(tester, size: const Size(390, 844), overlay: ov);
      await tester.tap(find.byKey(const Key('btn_overlay')));
      await tester.pumpAndSettle();
      expect(ov.active, isFalse);
      expect(find.text(tr('ar', 'overlay_permission_denied')), findsOneWidget);
    });

    testWidgets('overlay card renders pushed payload and closes', (tester) async {
      final updates = StreamController<dynamic>();
      var closed = false;
      await tester.pumpWidget(OverlayApp(updates: updates.stream, onClose: () => closed = true));
      expect(tester.widget<Text>(find.byKey(const Key('overlay_state'))).data, tr('ar', 'state_idle'));
      updates.add({'lang': 'en', 'state': 'running_no_engine', 'signal': 'WAIT', 'timeframe_sec': 30});
      await tester.pumpAndSettle();
      expect(find.text('WAIT'), findsOneWidget);
      expect(find.textContaining('30s'), findsOneWidget);
      await tester.tap(find.byKey(const Key('overlay_close')));
      expect(closed, isTrue);
      await updates.close();
    });
  });

  group('share intake', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('share'));
    tearDown(() => dir.deleteSync(recursive: true));

    String file(String name) => (File('${dir.path}/$name')..writeAsBytesSync([1, 2, 3])).path;

    test('routes images to analysis and documents to the library', () async {
      final e = FakeEngine();
      final src = ListShareSource([
        SharedItem(file('Screenshot.png')),
        SharedItem(file('book.pdf')),
        SharedItem(file('archive.zip')),
        SharedItem('${dir.path}/missing.png'),
      ]);
      final got = <ShareOutcome>[];
      await ShareIntake(engine: e, source: src, onOutcomes: got.addAll).start();
      expect(got.map((o) => o.kind), [
        ShareOutcomeKind.chartAnalysed,
        ShareOutcomeKind.addedToLibrary,
        ShareOutcomeKind.unsupported,
        ShareOutcomeKind.failed,
      ]);
      expect(e.calls, containsAll(['chart:share:Screenshot.png', 'upload:book.pdf']));
      expect(src.resetCalled, isTrue);
    });

    test('duplicate document reported as duplicate', () async {
      final e = FakeEngine();
      final intake = ShareIntake(engine: e, source: ListShareSource(const []), onOutcomes: (_) {});
      await intake.process([SharedItem(file('book.pdf'))]);
      final second = await intake.process([SharedItem(file('book.pdf'))]);
      expect(second.single.kind, ShareOutcomeKind.duplicate);
    });
  });

  group('embedded engine host', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('uata/engine');

    test('starts engine over the method channel and reads the token from its data dir', () async {
      final dir = Directory.systemTemp.createTempSync('uata_embedded');
      File('${dir.path}/api_token').writeAsStringSync('tok123\n');
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return {'port': 8799, 'data_dir': dir.path};
      });
      final host = EmbeddedEngineHost();
      final api = await host.connect();
      expect(seen!.method, 'start');
      expect((seen!.arguments as Map)['port'], 8765);
      expect(host.dataDir, dir.path);
      expect(api, isA<EngineApi>());
      dir.deleteSync(recursive: true);
    });

    test('native start failure becomes an offline EngineException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PY', message: 'python missing');
      });
      await expectLater(EmbeddedEngineHost().connect(),
          throwsA(predicate((e) => e is EngineException && e.isOffline && e.message.contains('python missing'))));
    });
  });
}
