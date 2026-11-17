import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/l10n/strings.dart';
import 'package:uata_app/state/app_state.dart';
import 'package:uata_app/ui/panel/floating_panel.dart';
import 'package:uata_app/ui/screens/knowledge_screen.dart';
import 'package:uata_app/ui/screens/learning_reports_screen.dart';

import 'fake_engine.dart';

Future<void> pump(WidgetTester tester, FakeEngine e, Widget home) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState(engine: e, window: FakeWindow(), pollInterval: null);
  await state.init();
  await tester.pumpWidget(AppScope(state: state, child: MaterialApp(home: home)));
  await tester.pumpAndSettle();
}

Json report(int id, {List<Json> conflicts = const []}) => {
      'id': id, 'source_id': 3, 'source_title': 'strategy.pdf', 'status': 'pending_review',
      'summary': '2 section(s), 1 candidate rule(s), ${conflicts.length} conflict(s) with approved knowledge',
      'created_at': '2026-11-17T10:00:00.000+00:00',
      'extracted': {
        'concepts': ['rsi', 'support'],
        'rules': [
          {'item_id': 77, 'text': 'When RSI is oversold at support, buy.', 'actions': ['act_buy'],
            'conditions': ['oversold', 'rsi', 'support'], 'location': 'p.2', 'timeframes': <String>[]},
        ],
      },
      'conflicts': conflicts,
    };

void main() {
  testWidgets('reports screen lists rules, highlights conflicts, approve sends decision', (tester) async {
    final e = FakeEngine()
      ..reports = [
        report(1, conflicts: [
          {'new_text': 'When RSI is oversold at support, buy.', 'existing_text': 'RSI oversold at support: sell',
            'new_actions': ['act_buy'], 'existing_actions': ['act_sell'], 'shared_conditions': ['rsi', 'support']},
        ]),
      ];
    await pump(tester, e, const LearningReportsScreen());
    expect(find.textContaining('strategy.pdf'), findsOneWidget);
    expect(find.textContaining('When RSI is oversold at support, buy.'), findsWidgets);
    expect(find.textContaining('${tr('ar', 'location')}: p.2'), findsOneWidget);
    expect(find.byKey(const Key('conflicts_1')), findsOneWidget);
    expect(find.textContaining(tr('ar', 'act_act_sell')), findsOneWidget);
    await tester.tap(find.byKey(const Key('report_approve_1')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('report:approve:1'));
    expect(find.byKey(const Key('no_reports')), findsOneWidget); // no longer pending
  });

  testWidgets('reject a report', (tester) async {
    final e = FakeEngine()..reports = [report(2)];
    await pump(tester, e, const LearningReportsScreen());
    expect(find.byKey(const Key('conflicts_2')), findsNothing);
    await tester.tap(find.byKey(const Key('report_reject_2')));
    await tester.pumpAndSettle();
    expect(e.calls, contains('report:reject:2'));
  });

  testWidgets('library opens learning reports', (tester) async {
    final e = FakeEngine()..reports = [report(3)];
    await pump(tester, e, const KnowledgeScreen());
    await tester.tap(find.byKey(const Key('open_reports')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'learning_reports')), findsOneWidget);
    expect(find.byKey(const Key('report_3')), findsOneWidget);
  });

  testWidgets('chart result cites related approved knowledge with source and location', (tester) async {
    final e = FakeEngine();
    await pump(tester, e, FloatingPanel(
      pickImage: () async => UploadFile(name: 'c.png', length: 1, openRead: () => Stream.value([0])),
    ));
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    expect(find.text(tr('ar', 'related_knowledge')), findsOneWidget);
    final k = find.byKey(const Key('knowledge_501'));
    expect(k, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(of: k, matching: find.byType(Text))).data!;
    expect(text, contains('strategy.pdf'));
    expect(text, contains('(p.2)'));
  });

  testWidgets('no related knowledge is stated', (tester) async {
    final e = FakeEngine()..knowledge = [];
    await pump(tester, e, FloatingPanel(
      pickImage: () async => UploadFile(name: 'c.png', length: 1, openRead: () => Stream.value([0])),
    ));
    await tester.tap(find.byKey(const Key('btn_analyze_image')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('no_related_knowledge')), 200,
        scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)));
    expect(find.byKey(const Key('no_related_knowledge')), findsOneWidget);
  });
}
