@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:uata_app/core/engine_api.dart';
import 'package:uata_app/engine/knowledge/extract.dart';
import 'package:uata_app/engine/knowledge/pdf_text.dart';
import 'package:uata_app/engine/knowledge/rules.dart';
import 'package:uata_app/engine/knowledge/textnorm.dart';
import 'package:uata_app/engine/local/local_engine_api.dart';

import 'parity.dart';

Uint8List fx(String n) => File('test/fixtures/pdf/$n.pdf').readAsBytesSync();

void main() {
  test('Word → PDF (LibreOffice): Arabic restored to reading order, English, table, two pages', () {
    final pages = pdfPageTexts(fx('lo_mixed'));
    expect(pages, hasLength(2));
    final p1 = pages[0], p2 = pages[1];
    expect(extractPdf(fx('lo_mixed')).first.location, startsWith('p.1'));
    expect(p1, contains('إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فادخل صفقة شراء لمدة'));
    expect(p1, contains('دقيقتين.'));
    expect(p1, contains('When RSI is overbought near resistance, sell for 3 minutes.'));
    expect(p2, startsWith('لا تدخل أي صفقة عند صدور الأخبار المهمة.')); // lam-alef ligature kept as "لا"
    expect(p2, contains('MACD cross up in an uptrend buy'));
  });

  test('reportlab (standard font, ASCII85 + Flate), object streams + xref stream', () {
    final rl = pdfPageTexts(fx('rl_simple'));
    expect(rl[0], contains('When the price breaks out above resistance with strong momentum, buy.'));
    expect(rl[0], contains('Café, naïve — special characters: 30% & “quotes”.'));
    expect(rl[1], 'If the candle closes below support, exit the trade.');
    expect(pdfPageTexts(fx('objstm')).single, 'Object streams: when MACD crosses down in a downtrend, sell.');
  });

  test('password-protected, scanned and broken files are refused with a clear reason', () {
    expect(() => extractPdf(fx('encrypted')), throwsA(predicate((e) => e is ExtractionError && e.message == 'PDF is password protected')));
    expect(() => extractPdf(fx('scanned')), throwsA(predicate((e) => e is ExtractionError && e.message.contains('no extractable text'))));
    expect(() => extractPdf(Uint8List.fromList('hello'.codeUnits)), throwsA(predicate((e) => e is ExtractionError && e.message.contains('could not be read'))));
    final cut = fx('lo_mixed');
    expect(() => extractPdf(Uint8List.sublistView(cut, 0, cut.length ~/ 3)), throwsA(isA<ExtractionError>()));
  });

  test('the same concepts and rules as the computer engine (pypdf) on the same PDFs', () async {
    final names = ['lo_mixed', 'rl_simple', 'objstm', 'scanned', 'encrypted'];
    final paths = [for (final n in names) File('test/fixtures/pdf/$n.pdf').absolute.path];
    final py = await python({'op': 'kn_pdf', 'paths': paths}) as Map;
    for (var i = 0; i < names.length; i++) {
      final ref = py[paths[i]] as Map;
      if (ref.containsKey('error')) {
        expect(() => extractPdf(fx(names[i])), throwsA(isA<ExtractionError>()), reason: names[i]);
        continue;
      }
      final chunks = extractPdf(fx(names[i]));
      expect(chunks.map((c) => c.location).toList(), ref['locations'], reason: names[i]);
      expect(({for (final c in chunks) ...concepts(c.text)}.toList()..sort()), ref['concepts'], reason: '${names[i]} concepts');
      final rules = {for (final c in chunks) for (final r in extractRules(c.text, c.location)) '${r.actions.join(' ')}|${r.conditions.join(' ')}'};
      expect((rules.toList()..sort()), ref['rules'], reason: '${names[i]} rules');
    }
  }, skip: paritySkip);

  test('a PDF uploaded on the phone is read, its rules await approval, and it can be found', () async {
    final dir = Directory.systemTemp.createTempSync('uata_pdf');
    final engine = await LocalEngine.open(dir.path, (v) => File('assets/schema/schema_v$v.sql').readAsString());
    final api = LocalEngineApi(engine);
    final bytes = fx('lo_mixed');
    final src = await api.uploadFile(UploadFile(name: 'rules.pdf', length: bytes.length, openRead: () => Stream.value(bytes)));
    expect(src['kind'], 'pdf');
    expect(src['extraction_status'], 'done');
    final report = src['report'] as Map;
    expect(((report['extracted'] as Map)['rules'] as List), isNotEmpty);
    await api.decideReport(report['id'] as int, 'approve');
    expect((await api.search('RSI oversold support', approvedOnly: true)).first['source_title'], 'rules.pdf');
    final enc = fx('encrypted');
    final bad = await api.uploadFile(UploadFile(name: 'locked.pdf', length: enc.length, openRead: () => Stream.value(enc)));
    expect(bad['extraction_status'], 'failed');
    expect(bad['notes'], contains('password'));
    engine.close();
    dir.deleteSync(recursive: true);
  });
}
