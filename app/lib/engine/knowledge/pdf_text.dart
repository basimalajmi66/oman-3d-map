/// PDF text extraction in pure Dart (for the phone; the computer engine uses pypdf).
///
/// Supports what books and office documents use: classic and compressed (object-stream / xref-stream) files,
/// FlateDecode, simple and composite (Type0) fonts, ToUnicode CMaps, WinAnsi / Differences encodings, form XObjects,
/// text and graphics matrices. Glyphs are placed on the page, grouped into lines and ordered left→right; Arabic lines
/// stored in visual order (as LibreOffice / Word write them) are restored to reading order at GLYPH level, so a lam-alef
/// ligature stays "لا", while Latin words and numbers inside the line keep their direction.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as im;

class PdfError implements Exception {
  PdfError(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------- objects
class PdfName {
  const PdfName(this.name);
  final String name;
  @override
  bool operator ==(Object other) => other is PdfName && other.name == name;
  @override
  int get hashCode => name.hashCode;
  @override
  String toString() => '/$name';
}

class PdfRef {
  const PdfRef(this.num, this.gen);
  final int num, gen;
}

class PdfStream {
  PdfStream(this.dict, this.raw);
  final Map<String, Object?> dict;
  final Uint8List raw;
}

class PdfOp {
  const PdfOp(this.op);
  final String op;
}

bool _ws(int c) => c == 0x20 || c == 0x0a || c == 0x0d || c == 0x09 || c == 0x0c || c == 0x00;
bool _delim(int c) => c == 0x28 || c == 0x29 || c == 0x3c || c == 0x3e || c == 0x5b || c == 0x5d || c == 0x7b || c == 0x7d || c == 0x2f || c == 0x25;

/// Tokeniser + object parser for both file objects and content streams.
class _Lexer {
  _Lexer(this.b, [this.p = 0]);
  final Uint8List b;
  int p;

  void skipWs() {
    while (p < b.length) {
      final c = b[p];
      if (_ws(c)) {
        p++;
      } else if (c == 0x25) {
        while (p < b.length && b[p] != 0x0a && b[p] != 0x0d) {
          p++;
        }
      } else {
        break;
      }
    }
  }

  String _regular() {
    final s = p;
    while (p < b.length && !_ws(b[p]) && !_delim(b[p])) {
      p++;
    }
    return latin1.decode(b.sublist(s, p));
  }

  /// Next object (or operator keyword in content streams). Returns `#eof` at the end.
  Object? next() {
    skipWs();
    if (p >= b.length) return const PdfOp('#eof');
    final c = b[p];
    if (c == 0x2f) {
      p++;
      final raw = _regular();
      return PdfName(raw.replaceAllMapped(RegExp(r'#([0-9A-Fa-f]{2})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16))));
    }
    if (c == 0x28) return _literal();
    if (c == 0x3c) {
      if (p + 1 < b.length && b[p + 1] == 0x3c) {
        p += 2;
        return _dict();
      }
      return _hex();
    }
    if (c == 0x5b) {
      p++;
      final out = <Object?>[];
      while (true) {
        skipWs();
        if (p >= b.length) return out;
        if (b[p] == 0x5d) {
          p++;
          return out;
        }
        out.add(_valueWithRefs());
      }
    }
    if (c == 0x5d || c == 0x3e || c == 0x7b || c == 0x7d || c == 0x29) {
      p++;
      return PdfOp(String.fromCharCode(c));
    }
    final tok = _regular();
    if (tok.isEmpty) {
      p++;
      return const PdfOp('?');
    }
    final n = num.tryParse(tok);
    if (n != null) return n;
    if (tok == 'true') return true;
    if (tok == 'false') return false;
    if (tok == 'null') return null;
    return PdfOp(tok);
  }

  /// A value inside arrays / dictionaries: `n g R` becomes a reference.
  Object? _valueWithRefs() {
    final v = next();
    if (v is int) {
      final save = p;
      final g = next();
      if (g is int) {
        final r = next();
        if (r is PdfOp && r.op == 'R') return PdfRef(v, g);
      }
      p = save;
    }
    return v;
  }

  Map<String, Object?> _dict() {
    final out = <String, Object?>{};
    while (true) {
      skipWs();
      if (p >= b.length) return out;
      if (b[p] == 0x3e && p + 1 < b.length && b[p + 1] == 0x3e) {
        p += 2;
        return out;
      }
      final k = next();
      if (k is! PdfName) continue;
      out[k.name] = _valueWithRefs();
    }
  }

  Uint8List _literal() {
    p++;
    final out = BytesBuilder();
    var depth = 1;
    while (p < b.length) {
      final c = b[p++];
      if (c == 0x5c) {
        if (p >= b.length) break;
        final e = b[p++];
        switch (e) {
          case 0x6e:
            out.addByte(0x0a);
          case 0x72:
            out.addByte(0x0d);
          case 0x74:
            out.addByte(0x09);
          case 0x62:
            out.addByte(0x08);
          case 0x66:
            out.addByte(0x0c);
          case 0x0d:
            if (p < b.length && b[p] == 0x0a) p++;
          case 0x0a:
            break;
          default:
            if (e >= 0x30 && e <= 0x37) {
              var v = e - 0x30;
              for (var k = 0; k < 2 && p < b.length && b[p] >= 0x30 && b[p] <= 0x37; k++) {
                v = v * 8 + b[p++] - 0x30;
              }
              out.addByte(v & 0xff);
            } else {
              out.addByte(e);
            }
        }
      } else if (c == 0x28) {
        depth++;
        out.addByte(c);
      } else if (c == 0x29) {
        if (--depth == 0) break;
        out.addByte(c);
      } else {
        out.addByte(c);
      }
    }
    return out.takeBytes();
  }

  Uint8List _hex() {
    p++;
    final digits = <int>[];
    while (p < b.length && b[p] != 0x3e) {
      final c = b[p++];
      final v = c >= 0x30 && c <= 0x39 ? c - 0x30 : (c | 0x20) >= 0x61 && (c | 0x20) <= 0x66 ? (c | 0x20) - 0x61 + 10 : -1;
      if (v >= 0) digits.add(v);
    }
    p++;
    if (digits.length.isOdd) digits.add(0);
    return Uint8List.fromList([for (var i = 0; i < digits.length; i += 2) digits[i] * 16 + digits[i + 1]]);
  }
}

int _indexOf(Uint8List b, List<int> pat, int from) {
  outer:
  for (var i = from; i <= b.length - pat.length; i++) {
    for (var k = 0; k < pat.length; k++) {
      if (b[i + k] != pat[k]) continue outer;
    }
    return i;
  }
  return -1;
}

Uint8List _inflate(Uint8List raw) {
  try {
    return Uint8List.fromList(const ZLibDecoder().decodeBytes(raw));
  } catch (_) {
    try {
      return Uint8List.fromList(Inflate(raw).getBytes()); // raw deflate / damaged zlib header
    } catch (_) {
      return Uint8List(0);
    }
  }
}

class PdfDocument {
  PdfDocument(this.bytes) {
    if (_indexOf(bytes, ascii.encode('%PDF'), 0) < 0 || _indexOf(bytes, ascii.encode('%PDF'), 0) > 1024) {
      throw PdfError('not a PDF file');
    }
    _scan();
  }
  final Uint8List bytes;
  final _objects = <int, Object?>{};
  final _fromObjStm = <int>{};
  bool encrypted = false;

  void _scan() {
    final text = latin1.decode(bytes, allowInvalid: true);
    final objRe = RegExp(r'(\d+)\s+(\d+)\s+obj\b');
    for (final m in objRe.allMatches(text)) {
      final num = int.parse(m[1]!);
      try {
        final lx = _Lexer(bytes, m.end);
        final v = lx._valueWithRefs();
        Object? value = v;
        if (v is Map<String, Object?>) {
          lx.skipWs();
          if (_indexOf(bytes, ascii.encode('stream'), lx.p) == lx.p) {
            var s = lx.p + 6;
            if (s < bytes.length && bytes[s] == 0x0d) s++;
            if (s < bytes.length && bytes[s] == 0x0a) s++;
            final len = v['Length'];
            var end = len is int && s + len <= bytes.length ? s + len : -1;
            if (end < 0 || _indexOf(bytes, ascii.encode('endstream'), end) - end > 4) {
              end = _indexOf(bytes, ascii.encode('endstream'), s);
              if (end < 0) end = bytes.length;
              while (end > s && (bytes[end - 1] == 0x0a || bytes[end - 1] == 0x0d)) {
                end--;
              }
            }
            value = PdfStream(v, Uint8List.sublistView(bytes, s, end));
          }
          if (v.containsKey('Encrypt') && (v['Type'] == const PdfName('XRef') || v.containsKey('Root'))) encrypted = true;
        }
        _objects[num] = value; // later definitions (incremental updates) win
        _fromObjStm.remove(num);
      } catch (_) {
        // a damaged object is skipped; the rest of the file is still read
      }
    }
    for (final m in RegExp(r'trailer\s*<<').allMatches(text)) {
      final d = _Lexer(bytes, m.end - 2).next();
      if (d is Map && d.containsKey('Encrypt')) encrypted = true;
    }
    for (final e in _objects.entries.toList()) {
      final v = e.value;
      if (v is PdfStream && v.dict['Type'] == const PdfName('ObjStm')) _readObjStm(v);
    }
  }

  void _readObjStm(PdfStream s) {
    final data = decode(s);
    final n = resolve(s.dict['N']) as int? ?? 0;
    final first = resolve(s.dict['First']) as int? ?? 0;
    final lx = _Lexer(data);
    final pairs = <(int, int)>[];
    for (var i = 0; i < n; i++) {
      final num = lx.next(), off = lx.next();
      if (num is int && off is int) pairs.add((num, off));
    }
    for (final (num, off) in pairs) {
      if (_objects.containsKey(num) && !_fromObjStm.contains(num)) continue; // a direct definition wins
      try {
        _objects[num] = _Lexer(data, first + off)._valueWithRefs();
        _fromObjStm.add(num);
      } catch (_) {}
    }
  }

  Object? resolve(Object? v, [int depth = 0]) {
    while (v is PdfRef && depth++ < 32) {
      v = _objects[v.num];
    }
    return v;
  }

  Map<String, Object?> dictOf(Object? v) {
    final r = resolve(v);
    if (r is PdfStream) return r.dict;
    if (r is Map) return r.cast<String, Object?>();
    return const {};
  }

  /// Stream data with its filters applied (FlateDecode with PNG predictors; other filters → empty).
  Uint8List decode(PdfStream s) {
    var data = s.raw;
    final f = resolve(s.dict['Filter']);
    final filters = f is List ? [for (final x in f) resolve(x)] : (f == null ? [] : [f]);
    final parms = resolve(s.dict['DecodeParms']);
    for (var i = 0; i < filters.length; i++) {
      final name = (filters[i] as PdfName?)?.name;
      if (name == 'FlateDecode' || name == 'Fl') {
        data = _inflate(data);
        final pm = parms is List ? dictOf(parms[i]) : dictOf(parms);
        final pred = resolve(pm['Predictor']) as int? ?? 1;
        if (pred >= 10) data = _pngUnpredict(data, resolve(pm['Columns']) as int? ?? 1);
      } else if (name == 'ASCII85Decode' || name == 'A85') {
        data = _ascii85(data);
      } else if (name == 'ASCIIHexDecode' || name == 'AHx') {
        data = _Lexer(Uint8List.fromList([0x3c, ...data]))._hex();
      } else {
        return Uint8List(0); // images (DCT, JBIG2, …) carry no text
      }
    }
    return data;
  }

  /// An image XObject as a file the OCR can read: JPEG kept as it is, 8-bit / 1-bit gray, RGB and indexed pixels
  /// turned into PNG. Null for formats without a decoder here (JPEG 2000, JBIG2, CCITT fax).
  (Uint8List, String)? imageFile(PdfStream s) {
    final f = resolve(s.dict['Filter']);
    final filters = [for (final x in (f is List ? f : (f == null ? [] : [f]))) (resolve(x) as PdfName?)?.name];
    final w = resolve(s.dict['Width']) as int? ?? 0, h = resolve(s.dict['Height']) as int? ?? 0;
    if (w <= 0 || h <= 0) return null;
    if (filters.isNotEmpty && (filters.last == 'DCTDecode' || filters.last == 'DCT')) {
      var data = s.raw;
      for (final name in filters.sublist(0, filters.length - 1)) {
        if (name == 'FlateDecode' || name == 'Fl') {
          data = _inflate(data);
        } else if (name == 'ASCII85Decode' || name == 'A85') {
          data = _ascii85(data);
        } else {
          return null;
        }
      }
      return (data, 'jpg');
    }
    if (filters.any((n) => n != 'FlateDecode' && n != 'Fl' && n != 'ASCII85Decode' && n != 'A85')) return null;
    final px = decode(s);
    final bpc = resolve(s.dict['BitsPerComponent']) as int? ?? 8;
    var cs = resolve(s.dict['ColorSpace']);
    List<int>? palette;
    var comps = 1;
    if (cs is List && cs.isNotEmpty && resolve(cs.first) == const PdfName('Indexed')) {
      final base = resolve(cs[1]);
      comps = base == const PdfName('DeviceRGB') ? 3 : 1;
      final lookup = resolve(cs[3]);
      palette = lookup is Uint8List ? lookup : (lookup is PdfStream ? decode(lookup) : null);
      cs = null;
    } else if (cs is List && cs.isNotEmpty && resolve(cs.first) == const PdfName('ICCBased')) {
      comps = (dictOf(resolve(cs[1]) is PdfStream ? (resolve(cs[1]) as PdfStream).dict : null)['N'] as int?) ?? 3;
    } else if (cs == const PdfName('DeviceRGB')) {
      comps = 3;
    } else if (cs == const PdfName('DeviceCMYK')) {
      return null;
    }
    final img = im.Image(width: w, height: h, numChannels: 3);
    final rowBytes = palette != null ? (w * bpc + 7) ~/ 8 : (bpc == 1 ? (w + 7) ~/ 8 : w * comps);
    if (px.length < rowBytes * h) return null;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        int r, g, b;
        if (palette != null) {
          final idx = bpc == 8 ? px[y * rowBytes + x] : (px[y * rowBytes + (x * bpc >> 3)] >> (8 - bpc - (x * bpc & 7))) & ((1 << bpc) - 1);
          final o = idx * comps;
          if (o + comps > palette.length) return null;
          r = palette[o];
          g = comps == 3 ? palette[o + 1] : r;
          b = comps == 3 ? palette[o + 2] : r;
        } else if (bpc == 1) {
          final bit = (px[y * rowBytes + (x >> 3)] >> (7 - (x & 7))) & 1;
          r = g = b = bit == 1 ? 255 : 0;
        } else if (bpc == 8 && comps == 3) {
          final o = y * rowBytes + x * 3;
          r = px[o];
          g = px[o + 1];
          b = px[o + 2];
        } else if (bpc == 8 && comps == 1) {
          r = g = b = px[y * rowBytes + x];
        } else {
          return null;
        }
        img.setPixelRgb(x, y, r, g, b);
      }
    }
    if (resolve(s.dict['Decode']) case final List d when d.length >= 2 && (resolve(d[0]) as num) == 1) {
      im.invert(img); // a "Decode [1 0]" image is stored inverted (common for 1-bit scans)
    }
    return (im.encodePng(img, level: 1), 'png');
  }

  static Uint8List _ascii85(Uint8List d) {
    final out = BytesBuilder();
    final group = <int>[];
    for (var i = 0; i < d.length; i++) {
      final c = d[i];
      if (c == 0x7e) break; // "~>"
      if (_ws(c)) continue;
      if (c == 0x7a && group.isEmpty) {
        out.add([0, 0, 0, 0]);
        continue;
      }
      if (c < 0x21 || c > 0x75) continue;
      group.add(c - 0x21);
      if (group.length == 5) {
        final v = group.fold<int>(0, (a, x) => a * 85 + x);
        out.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
        group.clear();
      }
    }
    if (group.isNotEmpty) {
      final n = group.length;
      while (group.length < 5) {
        group.add(84);
      }
      final v = group.fold<int>(0, (a, x) => a * 85 + x);
      out.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff].sublist(0, n - 1));
    }
    return out.takeBytes();
  }

  static Uint8List _pngUnpredict(Uint8List d, int cols) {
    final out = BytesBuilder();
    var prev = Uint8List(cols);
    for (var i = 0; i + cols < d.length + 1 && i < d.length; i += cols + 1) {
      final t = d[i];
      final row = Uint8List(cols);
      for (var k = 0; k < cols && i + 1 + k < d.length; k++) {
        final x = d[i + 1 + k];
        final a = k > 0 ? row[k - 1] : 0, up = prev[k], c = k > 0 ? prev[k - 1] : 0;
        row[k] = switch (t) {
          1 => x + a,
          2 => x + up,
          3 => x + ((a + up) >> 1),
          4 => x + _paeth(a, up, c),
          _ => x,
        } & 0xff;
      }
      out.add(row);
      prev = row;
    }
    return out.takeBytes();
  }

  static int _paeth(int a, int b, int c) {
    final p = a + b - c, pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
    return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
  }

  /// Pages in document order with inherited resources.
  List<Map<String, Object?>> pages() {
    Map<String, Object?>? catalog;
    for (final v in _objects.values) {
      final d = v is Map ? v.cast<String, Object?>() : null;
      if (d != null && d['Type'] == const PdfName('Catalog')) catalog = d;
    }
    final out = <Map<String, Object?>>[];
    final seen = <Object>{};
    void walk(Object? node, Object? res, int depth) {
      final d = dictOf(node);
      if (d.isEmpty || depth > 64 || !seen.add(d)) return;
      final r = d['Resources'] ?? res;
      final type = resolve(d['Type']);
      if (type == const PdfName('Page') || (type == null && d.containsKey('Contents'))) {
        out.add({...d, 'Resources': r});
      } else {
        for (final k in (resolve(d['Kids']) as List? ?? const [])) {
          walk(k, r, depth + 1);
        }
      }
    }

    if (catalog != null) walk(catalog['Pages'], null, 0);
    if (out.isEmpty) {
      // no usable page tree: every page object in object-number order
      final nums = _objects.keys.toList()..sort();
      for (final n in nums) {
        final d = dictOf(_objects[n]);
        if (d['Type'] == const PdfName('Page')) out.add(d);
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------- fonts
const _cp1252 = {
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02c6, //
  0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c,
  0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc, 0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a,
  0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178,
};

const _glyphNames = {
  'space': ' ', 'exclam': '!', 'quotedbl': '"', 'numbersign': '#', 'dollar': r'$', 'percent': '%', 'ampersand': '&',
  'quotesingle': "'", 'quoteright': '’', 'quoteleft': '‘', 'parenleft': '(', 'parenright': ')', 'asterisk': '*',
  'plus': '+', 'comma': ',', 'hyphen': '-', 'minus': '−', 'period': '.', 'slash': '/', 'colon': ':', 'semicolon': ';',
  'less': '<', 'equal': '=', 'greater': '>', 'question': '?', 'at': '@', 'bracketleft': '[', 'backslash': r'\',
  'bracketright': ']', 'underscore': '_', 'braceleft': '{', 'bar': '|', 'braceright': '}', 'zero': '0', 'one': '1',
  'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
  'endash': '–', 'emdash': '—', 'quotedblleft': '“', 'quotedblright': '”', 'bullet': '•', 'ellipsis': '…',
  'fi': 'fi', 'fl': 'fl', 'eacute': 'é', 'egrave': 'è', 'agrave': 'à', 'ccedilla': 'ç', 'idieresis': 'ï', 'degree': '°',
};

class _Font {
  _Font(this.toUnicode, this.codeLengths, this.simpleMap, this.widths, this.defaultWidth, this.isComposite);
  final Map<int, String> toUnicode;
  final List<(int, int, int)> codeLengths; // (length, lo, hi) code space ranges
  final Map<int, String>? simpleMap;
  final Map<int, double> widths; // per code (glyph space units / 1000)
  final double defaultWidth;
  final bool isComposite;

  /// Split a string operand into (code, text) glyphs.
  List<(int, String)> glyphs(Uint8List s) {
    final out = <(int, String)>[];
    var i = 0;
    while (i < s.length) {
      var len = isComposite ? 2 : 1;
      if (codeLengths.isNotEmpty) {
        for (final (l, lo, hi) in codeLengths) {
          if (i + l > s.length) continue;
          var code = 0;
          for (var k = 0; k < l; k++) {
            code = code << 8 | s[i + k];
          }
          if (code >= lo && code <= hi) {
            len = l;
            break;
          }
        }
      }
      if (i + len > s.length) len = s.length - i;
      var code = 0;
      for (var k = 0; k < len; k++) {
        code = code << 8 | s[i + k];
      }
      i += len;
      final t = toUnicode[code] ?? simpleMap?[code] ?? (isComposite ? '' : String.fromCharCode(_cp1252[code] ?? code));
      out.add((code, t));
    }
    return out;
  }

  double width(int code) => widths[code] ?? defaultWidth;
}

_Font _loadFont(PdfDocument doc, Map<String, Object?> f) {
  final subtype = (doc.resolve(f['Subtype']) as PdfName?)?.name;
  final composite = subtype == 'Type0';
  final toUni = <int, String>{};
  final ranges = <(int, int, int)>[];
  final tu = doc.resolve(f['ToUnicode']);
  if (tu is PdfStream) _parseCMap(doc.decode(tu), toUni, ranges);
  Map<int, String>? simple;
  if (!composite) {
    simple = {};
    final enc = doc.resolve(f['Encoding']);
    final encDict = enc is Map ? enc.cast<String, Object?>() : const <String, Object?>{};
    final diffs = doc.resolve(encDict['Differences']);
    if (diffs is List) {
      var code = 0;
      for (final d in diffs) {
        final v = doc.resolve(d);
        if (v is int) {
          code = v;
        } else if (v is PdfName) {
          final n = v.name;
          final u = RegExp(r'^uni([0-9A-Fa-f]{4})').firstMatch(n) ?? RegExp(r'^u([0-9A-Fa-f]{4,6})$').firstMatch(n);
          simple[code] = u != null
              ? String.fromCharCode(int.parse(u[1]!, radix: 16))
              : (_glyphNames[n] ?? (n.length == 1 ? n : String.fromCharCode(_cp1252[code] ?? code)));
          code++;
        }
      }
    }
  }
  final widths = <int, double>{};
  var dw = composite ? 1.0 : 0.5;
  if (composite) {
    final desc = doc.dictOf((doc.resolve(f['DescendantFonts']) as List?)?.firstOrNull);
    dw = ((doc.resolve(desc['DW']) as num?) ?? 1000) / 1000;
    final w = doc.resolve(desc['W']) as List?;
    if (w != null) {
      var i = 0;
      while (i < w.length) {
        final c0 = doc.resolve(w[i]) as int;
        final nxt = doc.resolve(w[i + 1]);
        if (nxt is List) {
          for (var k = 0; k < nxt.length; k++) {
            widths[c0 + k] = ((doc.resolve(nxt[k]) as num?) ?? 0) / 1000;
          }
          i += 2;
        } else {
          final c1 = nxt as int, v = ((doc.resolve(w[i + 2]) as num?) ?? 0) / 1000;
          for (var c = c0; c <= c1; c++) {
            widths[c] = v;
          }
          i += 3;
        }
      }
    }
  } else {
    final fc = doc.resolve(f['FirstChar']) as int? ?? 0;
    final ws = doc.resolve(f['Widths']) as List?;
    if (ws != null) {
      for (var k = 0; k < ws.length; k++) {
        widths[fc + k] = ((doc.resolve(ws[k]) as num?) ?? 0) / 1000;
      }
    }
  }
  return _Font(toUni, ranges, simple, widths, dw, composite);
}

String _utf16be(Uint8List b) {
  final units = [for (var i = 0; i + 1 < b.length; i += 2) b[i] << 8 | b[i + 1]];
  return String.fromCharCodes(units);
}

void _parseCMap(Uint8List data, Map<int, String> map, List<(int, int, int)> ranges) {
  final lx = _Lexer(data);
  final stack = <Object?>[];
  int toInt(Uint8List b) => b.fold(0, (a, x) => a << 8 | x);
  while (true) {
    final t = lx.next();
    if (t is PdfOp) {
      switch (t.op) {
        case '#eof':
          ranges.sort((a, b) => a.$1.compareTo(b.$1));
          return;
        case 'endcodespacerange':
          for (var i = 0; i + 1 < stack.length; i += 2) {
            final lo = stack[i], hi = stack[i + 1];
            if (lo is Uint8List && hi is Uint8List) ranges.add((lo.length, toInt(lo), toInt(hi)));
          }
        case 'endbfchar':
          for (var i = 0; i + 1 < stack.length; i += 2) {
            final src = stack[i], dst = stack[i + 1];
            if (src is Uint8List && dst is Uint8List) map[toInt(src)] = _utf16be(dst);
          }
        case 'endbfrange':
          for (var i = 0; i + 2 < stack.length; i += 3) {
            final lo = stack[i], hi = stack[i + 1], dst = stack[i + 2];
            if (lo is! Uint8List || hi is! Uint8List) continue;
            final a = toInt(lo), z = toInt(hi);
            if (z - a > 65535) continue;
            if (dst is Uint8List) {
              final base = _utf16be(dst).codeUnits;
              for (var c = a; c <= z; c++) {
                map[c] = String.fromCharCodes([...base.sublist(0, base.length - 1), base.last + (c - a)]);
              }
            } else if (dst is List) {
              for (var c = a; c <= z && c - a < dst.length; c++) {
                final d = dst[c - a];
                if (d is Uint8List) map[c] = _utf16be(d);
              }
            }
          }
      }
      if (t.op.startsWith('end') || t.op.startsWith('begin')) stack.clear();
    } else {
      stack.add(t);
    }
  }
}

// ---------------------------------------------------------------- text layout
class _Glyph {
  _Glyph(this.x, this.y, this.x2, this.text, this.size);
  final double x, y, x2, size;
  final String text;
}

List<double> _mul(List<double> a, List<double> b) => [
      a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], //
      a[2] * b[1] + a[3] * b[3], a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5],
    ];

class _Interpreter {
  _Interpreter(this.doc);
  final PdfDocument doc;
  final glyphs = <_Glyph>[];
  final images = <PdfStream>[]; // image XObjects drawn on the page (for OCR)
  final _fontCache = <Object, _Font>{};

  void run(Uint8List content, Map<String, Object?> resources, List<double> ctm0, int depth) {
    if (depth > 8) return;
    var ctm = [...ctm0];
    final gstack = <List<double>>[];
    var tm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0], tlm = [...tm];
    _Font? font;
    var size = 12.0, charSp = 0.0, wordSp = 0.0, hScale = 1.0, leading = 0.0, rise = 0.0;
    final operands = <Object?>[];
    final fonts = doc.dictOf(resources['Font']);
    final xobjects = doc.dictOf(resources['XObject']);
    final lx = _Lexer(content);

    void showString(Uint8List s) {
      final f = font;
      if (f == null) return;
      for (final (code, text) in f.glyphs(s)) {
        final w0 = f.width(code);
        final trm = _mul([size * hScale, 0, 0, size, 0, rise], _mul(tm, ctm));
        final adv = (w0 * size + charSp + (text == ' ' ? wordSp : 0)) * hScale;
        final end = _mul([1, 0, 0, 1, adv, 0], _mul(tm, ctm));
        final scale = math.sqrt(trm[2] * trm[2] + trm[3] * trm[3]);
        if (text.isNotEmpty) glyphs.add(_Glyph(trm[4], trm[5], end[4], text, scale));
        tm = _mul([1, 0, 0, 1, adv, 0], tm);
      }
    }

    void newline(double tx, double ty) {
      tlm = _mul([1, 0, 0, 1, tx, ty], tlm);
      tm = [...tlm];
    }

    double n(int i) => (operands.length > i ? (operands[i] as num?) : null)?.toDouble() ?? 0;

    while (true) {
      final t = lx.next();
      if (t is! PdfOp) {
        operands.add(t);
        continue;
      }
      switch (t.op) {
        case '#eof':
          return;
        case 'q':
          gstack.add([...ctm]);
        case 'Q':
          if (gstack.isNotEmpty) ctm = gstack.removeLast();
        case 'cm':
          if (operands.length >= 6) ctm = _mul([n(0), n(1), n(2), n(3), n(4), n(5)], ctm);
        case 'BT':
          tm = [1, 0, 0, 1, 0, 0];
          tlm = [...tm];
        case 'Tf':
          final name = operands.isNotEmpty ? operands[0] : null;
          size = n(1);
          if (name is PdfName) {
            final ref = fonts[name.name];
            final key = ref is PdfRef ? ref.num : (ref ?? name.name);
            final fd = doc.dictOf(ref);
            font = fd.isEmpty ? null : _fontCache.putIfAbsent(key, () => _loadFont(doc, fd));
          }
        case 'Tc':
          charSp = n(0);
        case 'Tw':
          wordSp = n(0);
        case 'Tz':
          hScale = n(0) / 100;
        case 'TL':
          leading = n(0);
        case 'Ts':
          rise = n(0);
        case 'Td':
          newline(n(0), n(1));
        case 'TD':
          leading = -n(1);
          newline(n(0), n(1));
        case 'Tm':
          tlm = [n(0), n(1), n(2), n(3), n(4), n(5)];
          tm = [...tlm];
        case 'T*':
          newline(0, -leading);
        case 'Tj':
          if (operands.isNotEmpty && operands.last is Uint8List) showString(operands.last as Uint8List);
        case "'":
          newline(0, -leading);
          if (operands.isNotEmpty && operands.last is Uint8List) showString(operands.last as Uint8List);
        case '"':
          wordSp = n(0);
          charSp = n(1);
          newline(0, -leading);
          if (operands.length > 2 && operands[2] is Uint8List) showString(operands[2] as Uint8List);
        case 'TJ':
          final arr = operands.isNotEmpty ? operands.last : null;
          if (arr is List) {
            for (final e in arr) {
              if (e is Uint8List) {
                showString(e);
              } else if (e is num) {
                tm = _mul([1, 0, 0, 1, -e / 1000 * size * hScale, 0], tm);
              }
            }
          }
        case 'Do':
          final name = operands.isNotEmpty ? operands.last : null;
          if (name is PdfName) {
            final xo = doc.resolve(xobjects[name.name]);
            if (xo is PdfStream && doc.resolve(xo.dict['Subtype']) == const PdfName('Image')) {
              if (!images.contains(xo)) images.add(xo);
            } else if (xo is PdfStream && doc.resolve(xo.dict['Subtype']) == const PdfName('Form')) {
              final m = doc.resolve(xo.dict['Matrix']) as List?;
              final fm = m == null ? [1.0, 0.0, 0.0, 1.0, 0.0, 0.0] : [for (final v in m) ((doc.resolve(v) as num?) ?? 0).toDouble()];
              final res = xo.dict['Resources'] != null ? doc.dictOf(xo.dict['Resources']) : resources;
              run(doc.decode(xo), res, _mul(fm, ctm), depth + 1);
            }
          }
        case 'BI':
          // inline image: skip its binary data up to "EI"
          final ei = _indexOf(content, ascii.encode('EI'), lx.p);
          lx.p = ei < 0 ? content.length : ei + 2;
      }
      operands.clear();
    }
  }
}

// ---------------------------------------------------------------- reading order
final _arabicRe = RegExp('[؀-ۿﭐ-﷿ﹰ-﻿]');
final _ltrRe = RegExp(r'[A-Za-z0-9À-ɏ]');

/// Arabic presentation forms → base letters (some generators map glyphs to shaped forms).
String _unshape(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    b.write(_shapes[r] ?? String.fromCharCode(r));
  }
  return b.toString();
}

final Map<int, String> _shapes = () {
  // Presentation Forms-B: isolated/final/initial/medial per letter, in Unicode order
  const letters = 'ءآآأأؤؤإإئئئئااببببةةتتتتثثثثججججححححخخخخددذذررززسسسسششششصصصصضضضضططططظظظظععععغغغغففففققققككككللللممممننننههههووىىيييي';
  final m = <int, String>{};
  for (var i = 0; i < letters.length; i++) {
    m[0xfe80 + i] = letters[i];
  }
  const lamAlef = ['لآ', 'لآ', 'لأ', 'لأ', 'لإ', 'لإ', 'لا', 'لا'];
  for (var i = 0; i < lamAlef.length; i++) {
    m[0xfef5 + i] = lamAlef[i];
  }
  return m;
}();

/// How Arabic-like a line reads: words start with "ال", never with "ة"/"ى", rarely end with "لا".
int _arabicScore(String line) {
  var s = 0;
  for (final w in line.split(RegExp(r'[\s\.\,\:\;\!\?\(\)«»"،؛؟\-—]+'))) {
    if (w.isEmpty || !_arabicRe.hasMatch(w)) continue;
    if (w.startsWith('ال')) s += 2;
    if (w.endsWith('لا') && w.length > 3) s -= 2;
    if (w.startsWith('ة') || w.startsWith('ى')) s -= 3;
    if (w.endsWith('ة') || w.endsWith('ى')) s += 1;
  }
  return s;
}

/// Visual → logical for one line of glyph strings: reverse the glyph order, then put LTR runs back in order.
List<String> _visualToLogical(List<String> units) {
  final r = units.reversed.toList();
  final out = <String>[];
  var i = 0;
  while (i < r.length) {
    if (_arabicRe.hasMatch(r[i]) || !_ltrRe.hasMatch(r[i])) {
      out.add(r[i++]);
      continue;
    }
    var j = i;
    while (j < r.length && !_arabicRe.hasMatch(r[j]) && (j == i || _ltrRe.hasMatch(r[j]) || r[j] == ' ' || '.,:%-/'.contains(r[j]))) {
      j++;
    }
    // trailing neutrals stay in RTL flow
    while (j > i + 1 && !_ltrRe.hasMatch(r[j - 1])) {
      j--;
    }
    out.addAll(r.sublist(i, j).reversed);
    i = j;
  }
  return out;
}

/// Lines of a page (top to bottom), each a list of glyph strings in visual left→right order.
List<List<String>> _layoutPage(List<_Glyph> glyphs) {
  if (glyphs.isEmpty) return const [];
  final lines = <List<_Glyph>>[];
  final sorted = [...glyphs]..sort((a, b) => b.y.compareTo(a.y));
  for (final g in sorted) {
    final tol = math.max(1.0, g.size * 0.45);
    final line = lines.where((l) => (l.first.y - g.y).abs() <= tol).firstOrNull;
    line == null ? lines.add([g]) : line.add(g);
  }
  final out = <List<String>>[];
  for (final l in lines) {
    l.sort((a, b) => a.x.compareTo(b.x));
    final units = <String>[];
    _Glyph? prev;
    for (final g in l) {
      if (prev != null && (g.x - prev.x).abs() < 0.01 && g.text == prev.text) continue; // overprint (fake bold)
      if (prev != null) {
        final gap = g.x - prev.x2;
        final hasSpace = units.isNotEmpty && units.last.endsWith(' ') || g.text.startsWith(' ');
        if (!hasSpace && gap > g.size * 0.2) units.add(' ');
      }
      units.add(_unshape(g.text));
      prev = g;
    }
    if (units.join().trim().isNotEmpty) out.add(units);
  }
  return out;
}

final _leadingPunct = RegExp(r'^([\.\,\:\;\!\?،؛؟]+)\s*');

String _finishLine(List<String> units, bool visualArabic) {
  var text = units.join();
  if (visualArabic && _arabicRe.hasMatch(text)) {
    text = _visualToLogical(units).join().trim();
    // a sentence-final mark drawn at the right edge (left-to-right paragraph) belongs at the end
    final m = _leadingPunct.firstMatch(text);
    if (m != null) text = '${text.substring(m.end)}${m[1]}';
  }
  return text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
}

/// An image found on a PDF page, ready for OCR.
class PdfPageImage {
  PdfPageImage(this.page, this.bytes, this.ext, this.width, this.height);
  final int page; // 0-based
  final Uint8List bytes;
  final String ext; // jpg | png
  final int width, height;
}

/// The images drawn on each page that are big enough to hold readable text (scanned pages, pictures of text),
/// largest first, at most `limit` for the whole document. Throws PdfError like [pdfPageTexts].
List<PdfPageImage> pdfPageImages(Uint8List data, {int limit = 40, int minWidth = 200, int minHeight = 40}) {
  final doc = PdfDocument(data);
  if (doc.encrypted) throw PdfError('PDF is password protected');
  final found = <(int, PdfStream)>[];
  final pages = doc.pages();
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    final interp = _Interpreter(doc);
    final contents = doc.resolve(p['Contents']);
    final parts = contents is List ? [for (final c in contents) doc.resolve(c)] : [contents];
    final buf = BytesBuilder();
    for (final c in parts) {
      if (c is PdfStream) {
        buf
          ..add(doc.decode(c))
          ..addByte(0x0a);
      }
    }
    try {
      interp.run(buf.takeBytes(), doc.dictOf(p['Resources']), const [1, 0, 0, 1, 0, 0], 0);
    } catch (_) {}
    for (final s in interp.images) {
      final w = doc.resolve(s.dict['Width']) as int? ?? 0, h = doc.resolve(s.dict['Height']) as int? ?? 0;
      if (w >= minWidth && h >= minHeight) found.add((i, s));
    }
  }
  int area((int, PdfStream) e) => ((e.$2.dict['Width'] as int?) ?? 0) * ((e.$2.dict['Height'] as int?) ?? 0);
  found.sort((a, b) => area(b).compareTo(area(a)));
  final out = <PdfPageImage>[];
  for (final (page, s) in found) {
    if (out.length >= limit) break;
    try {
      final f = doc.imageFile(s);
      if (f != null) {
        out.add(PdfPageImage(page, f.$1, f.$2, doc.resolve(s.dict['Width']) as int, doc.resolve(s.dict['Height']) as int));
      }
    } catch (_) {
      // one damaged image does not stop the others
    }
  }
  out.sort((a, b) => a.page.compareTo(b.page));
  return out;
}

/// Text of every page (empty strings for pages without text). Throws PdfError for encrypted / unreadable files.
List<String> pdfPageTexts(Uint8List data) {
  final doc = PdfDocument(data);
  if (doc.encrypted) throw PdfError('PDF is password protected');
  final pages = doc.pages();
  if (pages.isEmpty) throw PdfError('no pages found');
  final pageLines = <List<List<String>>>[];
  for (final p in pages) {
    final interp = _Interpreter(doc);
    final contents = doc.resolve(p['Contents']);
    final parts = contents is List ? [for (final c in contents) doc.resolve(c)] : [contents];
    final buf = BytesBuilder();
    for (final c in parts) {
      if (c is PdfStream) {
        buf
          ..add(doc.decode(c))
          ..addByte(0x0a);
      }
    }
    try {
      interp.run(buf.takeBytes(), doc.dictOf(p['Resources']), const [1, 0, 0, 1, 0, 0], 0);
    } catch (_) {
      // keep what was read before a damaged operator
    }
    pageLines.add(_layoutPage(interp.glyphs));
  }
  // A file stores all its Arabic the same way (visual order from Word / LibreOffice, or reading order):
  // decide once for the whole document from the lines that carry enough evidence.
  var evidence = 0;
  for (final lines in pageLines) {
    for (final u in lines) {
      final asIs = u.join();
      if (!_arabicRe.hasMatch(asIs)) continue;
      evidence += _arabicScore(_visualToLogical(u).join()) - _arabicScore(asIs);
    }
  }
  final visual = evidence > 0;
  return [for (final lines in pageLines) lines.map((u) => _finishLine(u, visual)).where((t) => t.isNotEmpty).join('\n')];
}
