@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:uata_app/engine/knowledge/extract.dart';
import 'package:uata_app/engine/knowledge/retrieval.dart';
import 'package:uata_app/engine/knowledge/rules.dart';
import 'package:uata_app/engine/knowledge/textnorm.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

import 'parity.dart';

const texts = [
  'إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فاشترِ بعد إغلاق الشمعة.',
  'When RSI is overbought near resistance, sell for 2 minutes.',
  'لا تدخل أي صفقة عند صدور الأخبار.',
  'عندما يكون الاتجاه صاعداً والماكد إيجابياً ادخل صفقة شراء لمدة دقيقتين.',
  'Only when the price breaks out above resistance with strong momentum, buy. If the candle closes below support, exit.',
  'نموذج الابتلاعية الشرائية عند الدعم إشارة قوية. وإذا ظهرت نجمة الصباح بعد هبوط فادخل شراء ٣ دقائق.',
  'Bollinger bands squeeze then breakout; ٥ دقائق. avoid trading during news.',
  'Moving averages: EMA 50 above SMA 200 means uptrend. Do not enter against the trend.',
];

void main() {
  test('normalisation, concepts, rule extraction, features and vectors match the computer engine', () async {
    final py = await python({'op': 'kn_text', 'texts': texts}) as List;
    final emb = HashingEmbedder();
    for (var i = 0; i < texts.length; i++) {
      final ref = py[i] as Map;
      final t = texts[i];
      expect(normalize(t), ref['normalized'], reason: 'normalize $i');
      expect(concepts(t).toList()..sort(), ref['concepts'], reason: 'concepts $i');
      expect(concepts(expandQuery(t)).toList()..sort(), ref['expanded_concepts'], reason: 'expand $i');
      expectSame([for (final r in extractRules(t, 'x')) r.toJson()], ref['rules'], path: 'rules $i');
      final f = emb.features(t);
      expectSame({for (final e in f.entries) e.key: e.value}, ref['features'], path: 'features $i', tol: 1e-6);
      expectSame(emb.embed(t).toList(), ref['vector'], path: 'vector $i', tol: 2e-6);
    }
  }, skip: paritySkip);

  test('Word, Excel and text extraction match the computer engine (same files)', () async {
    final dir = Directory.systemTemp.createTempSync('uata_kn_files');
    final req = {
      'op': 'kn_files',
      'docx_path': '${dir.path}/a.docx',
      'xlsx_path': '${dir.path}/a.xlsx',
      'docx_paragraphs': ['قواعد الدخول', 'إذا كان RSI أقل من 30 عند الدعم اشترِ.', '', 'When MACD crosses up in an uptrend, buy.'],
      'docx_table': [['الشرط', 'الإجراء'], ['تشبع بيعي', 'شراء'], ['تشبع شرائي', 'بيع']],
      'xlsx_rows': [['Condition', 'Action', 'Minutes'], ['RSI < 30 at support', 'BUY', 2], ['RSI > 70 at resistance', 'SELL', 3.5], ['news', 'avoid', null]],
      'txt': 'سطر أول\n\nWhen RSI is oversold, buy.\n\n\n${'نص طويل. ' * 200}',
    };
    final py = await python(req) as Map;
    List<Map<String, String>> j(List<Chunk> cs) => [for (final c in cs) {'text': c.text, 'location': c.location}];
    expectSame(j(extractDocx(File(req['docx_path'] as String).readAsBytesSync())), py['docx'], path: 'docx');
    expectSame(j(extractXlsx(File(req['xlsx_path'] as String).readAsBytesSync())), py['xlsx'], path: 'xlsx');
    expectSame(j(extractTxt(Uint8List.fromList(utf8.encode(req['txt'] as String)))), py['txt'], path: 'txt');
    dir.deleteSync(recursive: true);
  }, skip: paritySkip);

  test('the same library returns the same search results in the same order (Arabic ↔ English)', () async {
    final notes = [
      {'title': 'RSI reversal', 'content': 'When RSI is oversold near support, buy after the candle closes.', 'approve': true},
      {'title': 'ارتداد القوة النسبية', 'content': 'إذا كان مؤشر القوة النسبية في التشبع البيعي عند الدعم فاشترِ.', 'approve': true},
      {'title': 'MACD trend', 'content': 'A MACD cross up in an uptrend is a buy setup; avoid it in ranging markets.', 'approve': true},
      {'title': 'الماكد', 'content': 'تقاطع الماكد الصاعد مع الاتجاه الصاعد فرصة شراء.', 'approve': false},
      {'title': 'News', 'content': 'Do not enter any trade during high-impact news releases.', 'approve': true},
      {'title': 'الأخبار', 'content': 'لا تدخل أي صفقة وقت الأخبار المهمة.', 'approve': true},
      {'title': 'Bollinger', 'content': 'Bollinger band squeeze often precedes a breakout with strong momentum.', 'approve': true},
      {'title': 'الشموع', 'content': 'نموذج الابتلاع الشرائي عند الدعم وإشارة المطرقة بعد الهبوط.', 'approve': true},
      {'title': 'Volume', 'content': 'Breakouts with rising volume are more reliable than quiet ones.', 'approve': false},
    ];
    final queries = ['RSI oversold', 'القوة النسبية', 'macd buy', 'الأخبار', 'news trading', 'breakout momentum', 'ابتلاع دعم', 'volume'];
    final pyDir = Directory.systemTemp.createTempSync('uata_kn_py');
    final py = await python({'op': 'kn_search', 'dir': pyDir.path, 'notes': notes, 'queries': queries}) as Map;
    final dir = Directory.systemTemp.createTempSync('uata_kn_dart');
    final engine = await LocalEngine.open(dir.path, (v) => File('assets/schema/schema_v$v.sql').readAsString());
    for (final n in notes) {
      final src = engine.knowledge.addNote(n['title'] as String, n['content'] as String);
      if (n['approve'] == true) engine.knowledge.decideReport((src['report'] as Map)['id'] as int, 'approve');
    }
    var nonEmpty = 0;
    for (final q in queries) {
      final dart = [for (final h in engine.knowledge.retrieve(q)) h['title']];
      expect(dart, py[q], reason: q);
      if (dart.isNotEmpty) nonEmpty++;
    }
    expect(nonEmpty, greaterThan(5));
    expect(py['القوة النسبية'], contains('RSI reversal')); // Arabic query finds the English note
    expect([for (final h in engine.knowledge.retrieve('macd buy')) h['title']], isNot(contains('الماكد'))); // not approved
    engine.close();
    dir.deleteSync(recursive: true);
    pyDir.deleteSync(recursive: true);
  }, skip: paritySkip);
}
