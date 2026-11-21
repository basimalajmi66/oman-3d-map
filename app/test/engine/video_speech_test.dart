@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

void main() {
  late Directory dir;
  late LocalEngine engine;
  late LocalEngineApi api;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('uata_video');
    engine = await LocalEngine.open(dir.path, (v) => File('assets/schema/schema_v$v.sql').readAsString());
    api = LocalEngineApi(engine);
  });
  tearDown(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  UploadFile video(String name) {
    final b = [...name.codeUnits, ...List<int>.generate(4000, (i) => i % 251)];
    return UploadFile(name: name, length: b.length, openRead: () => Stream.value(b));
  }

  test('a video uploaded on the phone: speech → timed pieces → rules awaiting approval, searchable', () async {
    String? seenPath;
    engine.speech = (path) async {
      seenPath = path;
      expect(File(path).existsSync(), isTrue); // the video is on disk for the recogniser
      return [
        (startMs: 1000, endMs: 4000, text: 'مرحباً بكم في درس اليوم.'),
        (startMs: 65000, endMs: 70000, text: 'إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فادخل صفقة شراء لمدة دقيقتين.'),
        (startMs: 130000, endMs: 136000, text: 'When RSI is overbought near resistance, sell for 3 minutes.'),
      ];
    };
    final src = await api.uploadFile(video('lesson.mp4'));
    expect(src['kind'], 'video');
    expect(src['extraction_status'], 'done');
    expect(File(seenPath!).existsSync(), isFalse); // the temporary copy is removed
    final report = src['report'] as Map;
    final rules = ((report['extracted'] as Map)['rules'] as List).cast<Map>();
    expect(rules, hasLength(2));
    expect(rules.map((r) => r['location']), containsAll(['01:05', '02:10'])); // where in the video
    await api.decideReport(report['id'] as int, 'approve');
    expect((await api.search('RSI oversold support', approvedOnly: true)).first['source_title'], 'lesson.mp4');
  });

  test('no recogniser in this build, or no speech: the video is kept and the reason is shown', () async {
    final kept = await api.uploadFile(video('a.mp4'));
    expect(kept['extraction_status'], 'unsupported_yet');
    engine.speech = (path) async => [];
    final silent = await api.uploadFile(video('b.mov'));
    expect(silent['extraction_status'], 'failed');
    expect(silent['notes'], contains('no speech'));
    engine.speech = (path) async => null;
    final broken = await api.uploadFile(video('c.mkv'));
    expect(broken['notes'], contains('failed'));
    var listened = 0;
    engine.speech = (path) async {
      listened++;
      return [];
    };
    await expectLater(api.uploadFile(video('c.mkv')), throwsA(isA<EngineException>()));
    expect(listened, 0); // a duplicate is refused before the slow listening
  });
}
