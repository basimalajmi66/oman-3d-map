import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/core/image_prep.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';
import 'package:uata_app/ui/screens/crop_screen.dart';

import 'fake_engine.dart';

void main() {
  final png = im.encodePng(im.Image(width: 400, height: 200)..clear(im.ColorRgb8(30, 30, 30)));

  Future<(bool, CropFrac?)?> openCrop(WidgetTester tester, AppState state, Future<void> Function() act) async {
    (bool, CropFrac?)? got;
    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(home: Builder(builder: (ctx) {
        return TextButton(
          onPressed: () async => got = await Navigator.of(ctx).push<(bool, CropFrac?)>(
              MaterialPageRoute(builder: (_) => AppScope(state: state, child: CropScreen(bytes: png)))),
          child: const Text('open'),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    for (var k = 0; k < 50 && find.byKey(const Key('crop_area')).evaluate().isEmpty; k++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // decode the image
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    await act();
    await tester.pumpAndSettle();
    return got;
  }

  testWidgets('crop screen: drag a corner, analyze the area; "whole image" sends no crop', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(engine: FakeEngine(), window: FakeWindow(), pollInterval: null);
    await state.init();
    final r = await openCrop(tester, state, () async {
      final area = tester.getRect(find.byKey(const Key('crop_area')));
      // the image (2:1) is centred in the area: find its bottom-right corner and drag it half-way in
      final imgW = area.width - 32, imgH = imgW / 2;
      final br = Offset(area.center.dx + imgW / 2, area.center.dy + imgH / 2);
      await tester.dragFrom(br, Offset(-imgW / 2, -imgH / 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('crop_ok')));
    });
    expect(r!.$1, isTrue);
    final c = r.$2!;
    expect(c.$1, 0);
    expect(c.$2, 0);
    expect(c.$3, closeTo(0.5, 0.03));
    expect(c.$4, closeTo(0.5, 0.03));
    final full = await openCrop(tester, state, () => tester.tap(find.byKey(const Key('crop_full'))));
    expect(full, (true, null));
    final untouched = await openCrop(tester, state, () => tester.tap(find.byKey(const Key('crop_ok'))));
    expect(untouched, (true, null)); // the frame still covers everything: nothing to crop
  });

  testWidgets('analyze button: the crop screen comes first; cancelling sends nothing', (tester) async {
    tester.view.physicalSize = const Size(500, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final e = FakeEngine();
    final asked = <String>[];
    var answer = true;
    final state = AppState(
      engine: e,
      window: FakeWindow(),
      pollInterval: null,
      askCrop: (f) async {
        asked.add(f.name);
        return answer ? CropDecision(f, (0.1, 0.1, 0.9, 0.9)) : null;
      },
    );
    await state.init();
    UploadFile pick() => UploadFile(name: 'chart.png', length: png.length, openRead: () => Stream.value(png));
    await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: Scaffold(body: FloatingPanel(pickImage: () async => pick())))));
    await tester.pumpAndSettle();
    answer = false;
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(asked, ['chart.png']);
    expect(e.calls.where((c) => c.startsWith('chart:')), isEmpty); // cancelled: nothing analysed
    answer = true;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('btn_analyze_image')));
      for (var k = 0; k < 40 && !e.calls.any((c) => c.startsWith('chart:')); k++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(e.calls.where((c) => c.startsWith('chart:')), ['chart:upload:chart.png']); // the cropped PNG
  });
}
