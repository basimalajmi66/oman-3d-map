import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/screens/knowledge_screen.dart';
import 'package:uata_app/ui/screens/videos_screen.dart';

import 'fake_engine.dart';

Json page({String status = 'done', String transcript = 'subtitles', List<String> warnings = const []}) => {
      'source_id': 5, 'title': 'lesson.mp4', 'status': status, 'progress': status == 'done' ? 1.0 : 0.4,
      'error': null, 'transcript_source': transcript, 'warnings': warnings, 'duration_ms': 21000,
      'summary': [{'time': '00:04', 'text': 'When RSI is oversold at support, buy.'}],
      'charts': [{'time': '00:10', 'candles': 60, 'trend': 'up', 'patterns': ['marubozu']}],
      'strategy': {
        'status': 'draft',
        'entry_conditions': [{'time': '00:04', 'text': 'When RSI is oversold at support, buy.', 'clarity': 0.95}],
        'no_entry_conditions': [{'time': '00:16', 'text': 'Do not enter when big news is expected.', 'clarity': 0.9}],
        'exit_conditions': <Map>[],
      },
      'rules': [
        {'id': 41, 'location': '00:04', 'content': 'When RSI is oversold at support, buy.', 'clarity': 0.95,
          'status': 'pending_review', 'video_timestamp_ms': 4000},
      ],
      'report': {'id': 9, 'status': 'pending_review', 'summary': 'video 00:21, 1 chart scene(s), 3 candidate rule(s)'},
    };

Future<void> pump(WidgetTester tester, FakeEngine e, Widget home) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('video page shows summary, draft strategy, timestamped rules with clarity, charts', (tester) async {
    final e = FakeEngine()..videoPages = {5: page()};
    await pump(tester, e, const VideoPage(sourceId: 5, poll: false));
    expect(find.text(tr('ar', 'vs_done')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'ts_subtitles')), findsOneWidget);
    expect(find.textContaining('[00:04] When RSI is oversold'), findsWidgets);
    expect(find.byKey(const Key('video_strategy')), findsOneWidget);
    expect(find.text(tr('ar', 'strategy_draft_note')), findsOneWidget);
    expect(find.textContaining('[00:16] Do not enter'), findsOneWidget);
    expect(find.textContaining('95%'), findsWidgets);
    expect(find.byKey(const Key('vrule_41')), findsOneWidget);
    expect(find.textContaining('[00:10] 60'), findsOneWidget);
  });

  testWidgets('approve the video report', (tester) async {
    final e = FakeEngine()..videoPages = {5: page()};
    await pump(tester, e, const VideoPage(sourceId: 5, poll: false));
    await tester.tap(find.byKey(const Key('video_approve')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('report:approve:9'));
    expect(find.byKey(const Key('video_approve')), findsNothing);
  });

  testWidgets('missing transcript is explained; adding subtitles re-analyses', (tester) async {
    final e = FakeEngine()
      ..videoPages = {5: page(transcript: 'none', warnings: ['speech_to_text_model_not_installed'])};
    await pump(tester, e, VideoPage(
      sourceId: 5,
      poll: false,
      pickSubtitlesFn: () async => UploadFile(name: 'lesson.srt', length: 3, openRead: () => Stream.value([1, 2, 3])),
    ));
    expect(find.textContaining(tr('ar', 'w_speech_to_text_model_not_installed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_subtitles')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('subtitles:5:lesson.srt'));
    expect(find.textContaining(tr('ar', 'ts_subtitles')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_reanalyze')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('reanalyze:5'));
  });

  testWidgets('processing shows progress; failed shows error', (tester) async {
    final e = FakeEngine()..videoPages = {5: page(status: 'processing')};
    await pump(tester, e, const VideoPage(sourceId: 5, poll: false));
    expect(find.text(tr('ar', 'vs_processing')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    e.videoPages[5] = {...page(status: 'failed'), 'error': 'video could not be opened'};
    await pump(tester, e, VideoPage(key: UniqueKey(), sourceId: 5, poll: false));
    expect(find.text('video could not be opened'), findsOneWidget);
  });

  testWidgets('videos list and navigation from the library', (tester) async {
    final e = FakeEngine()
      ..videos = [{'source_id': 5, 'title': 'lesson.mp4', 'status': 'done', 'progress': 1.0, 'report_status': 'pending_review'}]
      ..videoPages = {5: page()};
    await pump(tester, e, const KnowledgeScreen());
    await tester.tap(find.byKey(const Key('open_videos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video_5')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'pending_review')), findsOneWidget);
  });
}
