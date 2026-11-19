/// Local text extraction with exact locations (port of knowledge/extract.py) — TXT/MD/CSV, Word (DOCX) and
/// Excel (XLSX). Every chunk keeps where it came from (¶ range, table row, sheet and rows). Nothing leaves the device.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../util.dart';
import 'pdf_text.dart';

const chunkChars = 1200;

class Chunk {
  Chunk(this.text, this.location);
  final String text;
  final String location; // "¶12-18", "table1.r3", "Sheet1!r2-r40", "note"
}

class ExtractionError implements Exception {
  ExtractionError(this.message);
  final String message;
  @override
  String toString() => message;
}

String _merge(List<String> locs) {
  final uniq = <String>[];
  for (final l in locs) {
    if (!uniq.contains(l)) uniq.add(l);
  }
  if (uniq.length == 1) return uniq.first;
  final re = RegExp(r'^(\D+)(\d+)$');
  final m1 = re.firstMatch(uniq.first), m2 = re.firstMatch(uniq.last);
  if (m1 != null && m2 != null && m1[1] == m2[1]) return '${m1[1]}${m1[2]}-${m2[2]}';
  return '${uniq.first}…${uniq.last}';
}

int _rfind(String s, String sub, int end) {
  final i = s.lastIndexOf(sub, end - sub.length < 0 ? 0 : end - sub.length);
  return i >= 0 && i + sub.length <= end ? i : -1;
}

/// Pack (text, location) paragraphs into chunks, merging locations ("p.3-4").
List<Chunk> pack(List<(String, String)> paragraphs, {int size = chunkChars}) {
  final out = <Chunk>[];
  var buf = '';
  var locs = <String>[];
  for (final (raw, loc) in paragraphs) {
    var text = raw.trim();
    if (text.isEmpty) continue;
    while (text.length > size) {
      final cut0 = [_rfind(text, '. ', size), _rfind(text, '۔', size), _rfind(text, '\n', size)].reduce((a, b) => a > b ? a : b);
      final cut = cut0 > size ~/ 2 ? cut0 + 1 : size;
      if (buf.isNotEmpty) {
        out.add(Chunk(buf, _merge(locs)));
        buf = '';
        locs = [];
      }
      out.add(Chunk(text.substring(0, cut).trim(), loc));
      text = text.substring(cut).trim();
    }
    if (buf.isNotEmpty && buf.length + 2 + text.length > size) {
      out.add(Chunk(buf, _merge(locs)));
      buf = '';
      locs = [];
    }
    buf = buf.isNotEmpty ? '$buf\n\n$text' : text;
    locs.add(loc);
  }
  if (buf.isNotEmpty) out.add(Chunk(buf, _merge(locs)));
  return out;
}

List<Chunk> extractTxt(Uint8List data) {
  String text;
  try {
    text = utf8.decode(data);
  } on FormatException {
    throw ExtractionError('text file is not UTF-8');
  }
  if (text.startsWith('﻿')) text = text.substring(1);
  final subs = subtitleChunks(text.replaceAll('\r\n', '\n'));
  if (subs != null) return subs;
  final paras = text.split(RegExp(r'\n\s*\n'));
  return pack([for (var i = 0; i < paras.length; i++) (paras[i], '¶${i + 1}')]);
}

const subtitleGroupMs = 60000; // a video's words are kept in ~1 minute pieces, each with its timestamp
final _cueLine = RegExp(r'^\s*(?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3}\s*-->', multiLine: true);
final _ts = RegExp(r'(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})');

String fmtTs(int ms) {
  final s = ms ~/ 1000;
  String two(int v) => v.toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${two(s ~/ 60)}:${two(s % 60)}';
}

/// One subtitle cue (port of video/transcript.py parse_subtitles).
typedef Cue = ({int startMs, int endMs, String text});

int _cueMs(String ts) {
  final m = _ts.firstMatch(ts);
  if (m == null) throw FormatException('bad timestamp: $ts');
  final h = int.parse(m[1] ?? '0');
  return ((h * 60 + int.parse(m[2]!)) * 60 + int.parse(m[3]!)) * 1000 + int.parse(m[4]!.padRight(3, '0'));
}

/// SRT or WebVTT; tags (<i>, {\an8}) stripped, empty cues dropped. Throws FormatException when there are no cues.
List<Cue> parseSubtitles(String text) {
  text = text.replaceAll('\r\n', '\n').replaceAll('\ufeff', '');
  final out = <Cue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = [for (final l in block.trim().split('\n')) if (l.trim().isNotEmpty) l];
    final idx = lines.indexWhere((l) => l.contains('-->'));
    if (idx < 0) continue;
    final parts = lines[idx].split('-->');
    final start = parts[0].trim(), end = parts[1].trim();
    final body = lines.sublist(idx + 1).join(' ').replaceAll(RegExp(r'<[^>]+>|\{[^}]+\}'), '').trim();
    if (body.isNotEmpty) out.add((startMs: _cueMs(start), endMs: _cueMs(end.split(' ').first), text: body));
  }
  if (out.isEmpty) throw const FormatException('no subtitle cues found (expected SRT or WebVTT)');
  return stableSorted(out, (a, b) => a.startMs.compareTo(b.startMs));
}

/// A video's subtitles → chunks located by video time ("01:23"); null if the text is not subtitles.
List<Chunk>? subtitleChunks(String text, {int size = chunkChars}) {
  if (!_cueLine.hasMatch(text)) return null;
  final List<Cue> cues;
  try {
    cues = parseSubtitles(text);
  } on FormatException {
    return null;
  }
  final out = <Chunk>[];
  var group = <Cue>[];
  for (final c in [...cues, null]) {
    if (c == null ||
        (group.isNotEmpty &&
            (c.startMs - group.first.startMs >= subtitleGroupMs ||
                group.fold<int>(0, (n, g) => n + g.text.length + 1) + c.text.length > size))) {
      if (group.isNotEmpty) out.add(Chunk(group.map((g) => g.text).join(' '), fmtTs(group.first.startMs)));
      group = [];
    }
    if (c != null) group.add(c);
  }
  return out;
}

Archive _zip(Uint8List data, String what) {
  try {
    return ZipDecoder().decodeBytes(data);
  } catch (e) {
    throw ExtractionError('$what file could not be read: $e');
  }
}

XmlDocument? _xml(Archive a, String name) {
  final f = a.findFile(name);
  if (f == null) return null;
  return XmlDocument.parse(utf8.decode(f.content as List<int>, allowMalformed: true));
}

/// Paragraph text like python-docx: runs' w:t, w:tab → \t, w:br/w:cr → \n.
String _paragraphText(XmlElement p) {
  final b = StringBuffer();
  for (final n in p.descendants.whereType<XmlElement>()) {
    switch (n.name.local) {
      case 't':
        b.write(n.innerText);
      case 'tab':
        if (n.parentElement?.name.local == 'r') b.write('\t');
      case 'br' || 'cr':
        b.write('\n');
    }
  }
  return b.toString();
}

List<Chunk> extractDocx(Uint8List data) {
  final a = _zip(data, 'Word');
  final doc = _xml(a, 'word/document.xml');
  if (doc == null) throw ExtractionError('Word file could not be read: no document.xml');
  final body = doc.rootElement.findElements('w:body').firstOrNull ?? doc.rootElement;
  final paras = <(String, String)>[];
  var pi = 0;
  for (final p in body.childElements.where((e) => e.name.local == 'p')) {
    paras.add((_paragraphText(p), '¶${++pi}'));
  }
  var ti = 0;
  for (final t in body.childElements.where((e) => e.name.local == 'tbl')) {
    ti++;
    var ri = 0;
    for (final row in t.childElements.where((e) => e.name.local == 'tr')) {
      ri++;
      final cells = <String>[];
      for (final tc in row.childElements.where((e) => e.name.local == 'tc')) {
        final text = [for (final p in tc.childElements.where((e) => e.name.local == 'p')) _paragraphText(p)].join('\n').trim();
        final span = int.tryParse(tc.descendants.whereType<XmlElement>().where((e) => e.name.local == 'gridSpan').firstOrNull?.getAttribute('w:val') ?? '') ?? 1;
        for (var k = 0; k < span; k++) {
          cells.add(text); // python-docx repeats a horizontally merged cell
        }
      }
      if (cells.any((c) => c.isNotEmpty)) paras.add((cells.join(' | '), 'table$ti.r$ri'));
    }
  }
  return pack(paras);
}

int _colIndex(String ref) {
  var n = 0;
  for (final ch in ref.codeUnits) {
    if (ch < 65 || ch > 90) break;
    n = n * 26 + (ch - 64);
  }
  return n - 1;
}

/// openpyxl `str(value)`: ints without ".0", floats like Python repr, booleans True/False.
String _pyStr(String raw, String? type) {
  if (type == 'b') return raw == '1' ? 'True' : 'False';
  final i = int.tryParse(raw);
  if (i != null) return '$i';
  final d = double.tryParse(raw);
  if (d != null) {
    if (d == d.truncateToDouble() && d.abs() < 1e16) return '${d.toInt()}.0';
    return '$d';
  }
  return raw;
}

List<Chunk> extractXlsx(Uint8List data) {
  final a = _zip(data, 'Excel');
  final wb = _xml(a, 'xl/workbook.xml');
  if (wb == null) throw ExtractionError('Excel file could not be read: no workbook.xml');
  final shared = <String>[
    for (final si in (_xml(a, 'xl/sharedStrings.xml')?.rootElement.childElements ?? const <XmlElement>[]))
      [for (final t in si.descendants.whereType<XmlElement>().where((e) => e.name.local == 't')) t.innerText].join()
  ];
  final rels = {
    for (final r in (_xml(a, 'xl/_rels/workbook.xml.rels')?.rootElement.childElements ?? const <XmlElement>[]))
      r.getAttribute('Id'): r.getAttribute('Target')
  };
  final out = <Chunk>[];
  for (final s in wb.rootElement.descendants.whereType<XmlElement>().where((e) => e.name.local == 'sheet')) {
    final target = rels[s.getAttribute('r:id')] ?? '';
    final path = target.startsWith('/') ? target.substring(1) : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
    final sheet = _xml(a, path);
    if (sheet == null) continue;
    final rowsXml = sheet.rootElement.descendants.whereType<XmlElement>().where((e) => e.name.local == 'row').toList();
    final cellsByRow = <int, Map<int, String>>{};
    var maxCol = -1;
    for (final row in rowsXml) {
      final r = int.parse(row.getAttribute('r') ?? '${cellsByRow.length + 1}');
      final m = <int, String>{};
      var autoCol = 0;
      for (final c in row.childElements.where((e) => e.name.local == 'c')) {
        final ref = c.getAttribute('r');
        final col = ref == null ? autoCol : _colIndex(ref);
        autoCol = col + 1;
        final t = c.getAttribute('t');
        String? v;
        if (t == 'inlineStr') {
          v = c.descendants.whereType<XmlElement>().where((e) => e.name.local == 't').map((e) => e.innerText).join();
        } else {
          final raw = c.childElements.where((e) => e.name.local == 'v').firstOrNull?.innerText;
          if (raw != null) v = t == 's' ? shared[int.parse(raw)] : (t == 'str' || t == 'e' ? raw : _pyStr(raw, t));
        }
        if (v != null) {
          m[col] = v;
          if (col > maxCol) maxCol = col;
        }
      }
      cellsByRow[r] = m;
    }
    final rows = <(int, String)>[];
    for (final e in (cellsByRow.entries.toList()..sort((x, y) => x.key.compareTo(y.key)))) {
      final vals = [for (var c = 0; c <= maxCol; c++) e.value[c] ?? ''];
      if (vals.any((v) => v.trim().isNotEmpty)) rows.add((e.key, vals.join(' | ')));
    }
    final header = rows.isEmpty ? '' : rows.first.$2;
    for (var start = 0; start < rows.length; start += 40) {
      final part = rows.sublist(start, start + 40 > rows.length ? rows.length : start + 40);
      var body = part.map((r) => r.$2).join('\n');
      if (start > 0 && header.isNotEmpty) body = '$header\n$body';
      out.add(Chunk(body, '${s.getAttribute('name')}!r${part.first.$1}-r${part.last.$1}'));
    }
  }
  return out;
}

List<Chunk> extractPdf(Uint8List data) {
  final List<String> pages;
  try {
    pages = pdfPageTexts(data);
  } on PdfError catch (e) {
    throw ExtractionError(e.message == 'PDF is password protected' ? e.message : 'PDF could not be read: ${e.message}');
  } catch (e) {
    throw ExtractionError('PDF could not be read: $e');
  }
  if (!pages.any((t) => t.trim().isNotEmpty)) {
    throw ExtractionError('PDF has no extractable text (scanned images; OCR of PDFs is not supported yet)');
  }
  return pack([for (var i = 0; i < pages.length; i++) (pages[i], 'p.${i + 1}')]);
}

/// Extractors available on the phone. Image OCR and video stay on the computer.
const phoneExtractable = {'txt', 'docx', 'xlsx', 'pdf'};

List<Chunk> extract(String kind, Uint8List data) => switch (kind) {
      'txt' => extractTxt(data),
      'docx' => extractDocx(data),
      'xlsx' => extractXlsx(data),
      'pdf' => extractPdf(data),
      _ => throw ExtractionError("extraction for '$kind' is not available on the phone yet"),
    };
