@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:uata_app/engine/knowledge/extract.dart';

import 'parity.dart';

String srt() {
  final b = StringBuffer('﻿');
  String t(int s) => '${(s ~/ 3600).toString().padLeft(2, '0')}:${(s ~/ 60 % 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')},500';
  final lines = [
    'مرحباً، اليوم نتعلم استراتيجية الارتداد.',
    '<i>إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فادخل صفقة شراء لمدة دقيقتين.</i>',
    '{\\an8}When RSI is overbought near resistance, sell for 3 minutes.',
    'لا تدخل أي صفقة عند صدور الأخبار المهمة.',
  ];
  var n = 1;
  for (var s = 0; s < 3700; s += 25) {
    b.write('$n\r\n${t(s)} --> ${t(s + 4)}\r\n${lines[n % lines.length]}\r\n\r\n');
    n++;
  }
  return b.toString();
}

const vtt = 'WEBVTT\n\nNOTE made by hand\n\n00:01.000 --> 00:04.000 align:start\nIf the candle closes below support, exit the trade.\n\n'
    '00:05.250 --> 00:07.000\n\n00:08.000 --> 00:10.000\n<v Ahmad>MACD cross up in an uptrend: buy.</v>\n';

void main() {
  test('subtitles become timestamped pieces of about a minute; plain text with an arrow stays text', () {
    final chunks = extractTxt(utf8.encode(srt()));
    expect(chunks.first.location, '00:00');
    expect(chunks.first.text, startsWith('إذا كان مؤشر القوة النسبية')); // cue 1 = lines[1]; tags removed
    expect(chunks[1].location, '01:15'); // cues every 25 s: 0, 25, 50 | 75 …
    expect(chunks.last.location, startsWith('1:0')); // past one hour → h:mm:ss
    expect(chunks.every((c) => !c.text.contains('<i>') && !c.text.contains('{')), isTrue);
    final v = extractTxt(utf8.encode(vtt));
    expect(v.map((c) => c.location), ['00:01']);
    expect(v.single.text, 'If the candle closes below support, exit the trade. MACD cross up in an uptrend: buy.');
    final plain = extractTxt(utf8.encode('Rule: RSI < 30 --> buy\n\nanother paragraph'));
    expect(plain.first.location, startsWith('¶1'));
  });

  test('the same pieces and timestamps as the computer engine', () async {
    final texts = [srt(), vtt, 'Rule: RSI < 30 --> buy\n\nanother paragraph', '1\n00:00:01,000 --> 00:00:02,000\n\n'];
    final py = await python({'op': 'kn_txt', 'texts': texts}) as List;
    for (var i = 0; i < texts.length; i++) {
      expect([for (final c in extractTxt(utf8.encode(texts[i]))) [c.text, c.location]], py[i], reason: 'text $i');
    }
  }, skip: paritySkip);
}
