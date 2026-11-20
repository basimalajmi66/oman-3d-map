/// Chart images submitted for analysis on the phone (port of chart_input_service.py).
/// Decoding, reading and technical analysis run in a background isolate so the UI never freezes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as im;

import '../../core/engine_api.dart';
import '../analysis/analyzer.dart';
import '../vision/axis.dart';
import '../vision/imgops.dart';
import '../vision/reader.dart';
import 'db.dart';
import 'knowledge_service.dart';
import 'services.dart';

const chartInputModes = ['upload', 'share', 'screenshot', 'screen_region'];
const maxImageBytes = 25 * 1024 * 1024;
const minSide = 64;
const maxKeep = 500;

RgbImage rgbOf(im.Image d) {
  final c = d.numChannels == 3 && d.format == im.Format.uint8 ? d : d.convert(numChannels: 3, format: im.Format.uint8);
  return RgbImage(c.width, c.height, c.getBytes(order: im.ChannelOrder.rgb));
}

/// Runs in a background isolate: decode → PNG → read → technical analysis.
Future<Map<String, dynamic>> _process(Uint8List data, double minQuality, Map<String, bool> enabled, int maxCandles,
    bool withAxis) async {
  final decoded = im.decodeImage(data);
  if (decoded == null) return {'error': 'file is not a readable image'};
  if (decoded.width < minSide || decoded.height < minSide) {
    return {'error': 'image too small to analyse (${decoded.width}x${decoded.height})'};
  }
  final rgb = rgbOf(decoded);
  final png = im.encodePng(im.Image.fromBytes(width: rgb.width, height: rgb.height, bytes: rgb.rgb.buffer, numChannels: 3));
  final full = await ChartReader(minQuality: minQuality).read(rgb);
  final cds = (full['candles'] as List).cast<Map>();
  // the axis label lines are cut here (pure Dart); the OCR itself runs afterwards on the main isolate
  final job = withAxis && cds.isNotEmpty
      ? prepareAxisJob(rgb, cds.map((c) => c['left'] as int).reduce(math.min), cds.map((c) => c['right'] as int).reduce(math.max))
      : null;
  final reading = limitCandles(full, maxCandles);
  reading['technical'] = analyzeReading(reading, enabled: enabled);
  return {'reading': reading, 'png': png, 'width': rgb.width, 'height': rgb.height, 'axis': job};
}

class ChartInputService {
  ChartInputService(this.db, this.filesDir, this.signals, {this.knowledge, this.ocr});

  /// On-device OCR of single text lines (Tesseract on the phone); null = relative units only.
  final LineOcr? ocr;
  final LocalDb db;
  final String filesDir;
  final SignalService signals;
  final KnowledgeService? knowledge; // approved library passages relevant to the chart (local RAG)

  List<Map<String, dynamic>> _relatedKnowledge(Map? technical) {
    final k = knowledge;
    if (k == null || technical == null || technical['available'] != true) return [];
    final q = knowledgeQuery(technical);
    if (q.isEmpty) return [];
    return [
      for (final h in k.retrieve(q, approvedOnly: true, k: 5))
        {for (final f in const ['item_id', 'title', 'snippet', 'location', 'source_id', 'source_title', 'item_type', 'score']) f: h[f]}
    ];
  }

  Future<Map<String, dynamic>> submit(Uint8List data, String? filename, String inputMode,
      {required bool screenAllowed, int? sessionId, required double minQuality, required Map<String, bool> enabled}) async {
    if (!chartInputModes.contains(inputMode)) throw badRequest('input_mode must be one of $chartInputModes');
    if ({'screenshot', 'screen_region'}.contains(inputMode) && !screenAllowed) {
      throw EngineException(403, 'screen capture permission has not been granted by the user');
    }
    if (data.isEmpty) throw EngineException(422, 'empty file');
    if (data.length > maxImageBytes) throw EngineException(422, 'image too large (max 25 MB)');
    final maxCandles = signals.settings.get()['chart_max_candles'] as int;
    final withAxis = ocr != null;
    final r = await Isolate.run(() => _process(data, minQuality, enabled, maxCandles, withAxis));
    if (r['error'] != null) throw EngineException(422, r['error'] as String);
    final png = r['png'] as Uint8List;
    var reading = r['reading'] as Map<String, dynamic>;
    if (r['axis'] case final AxisJob job when ocr != null && !job.isEmpty) {
      final (scale, tfSec, tfLabel, axisDiag) = await runAxisJob(job, ocr!);
      reading = applyAxis(reading, scale, tfSec, tfLabel, axisDiag);
    }
    final digest = sha256.convert(png).toString();
    final rel = 'inputs/${digest.substring(0, 2)}/$digest.png';
    final dest = File('$filesDir/$rel');
    if (!dest.existsSync()) {
      dest.parent.createSync(recursive: true);
      final tmp = File('${dest.path}.part')..writeAsBytesSync(png, flush: true);
      tmp.renameSync(dest.path);
    }
    reading['knowledge'] = _relatedKnowledge(reading['technical'] as Map?);
    reading['decision'] = signals.evaluate(reading, reading['technical'] as Map<String, dynamic>?, 'input:$inputMode',
        sessionId: sessionId, knowledge: (reading['knowledge'] as List).cast<Map>());
    final width = r['width'] as int, height = r['height'] as int;
    final row = db.session((d) {
      d.execute(
          'INSERT INTO analysis_inputs(session_id,input_mode,original_name,sha256,stored_path,width,height,size_bytes,created_at,'
          'reading_json,data_quality,usable) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
          [
            sessionId, inputMode, filename?.split(RegExp(r'[\\/]')).last, digest, rel, width, height, data.length, utcnow(),
            jsonEncode(reading), reading['data_quality'], reading['usable'] == true ? 1 : 0,
          ]);
      final id = d.lastInsertRowId;
      audit(d, 'user', 'analysis.input', {
        'input_id': id, 'mode': inputMode, 'width': width, 'height': height, 'usable': reading['usable'],
        'candles': (reading['candles'] as List).length,
      });
      return firstRow(d.select('SELECT * FROM analysis_inputs WHERE id=?', [id]))!;
    })
      ..remove('reading');
    _enforceRetention();
    return {'input': row, 'analysis': analysisFromReading(reading, width, height)};
  }

  Map<String, dynamic> reading(int id) {
    final r = db.session((d) => d.select('SELECT reading_json FROM analysis_inputs WHERE id=?', [id]));
    if (r.isEmpty) throw EngineException(404, 'input not found');
    final v = r.first['reading_json'] as String?;
    return v == null ? {} : (jsonDecode(v) as Map).cast<String, dynamic>();
  }

  List<Map<String, dynamic>> list({int limit = 50}) => db.session((d) => [
        for (final r in d.select('SELECT * FROM analysis_inputs ORDER BY id DESC LIMIT ?', [limit]))
          () {
            final m = rowToMap(r);
            final rd = (m.remove('reading') as Map?) ?? const {};
            m['summary'] = rd['summary'];
            return m;
          }()
      ]);

  String imagePath(int id) {
    final r = db.session((d) => d.select('SELECT stored_path FROM analysis_inputs WHERE id=?', [id]));
    if (r.isEmpty) throw EngineException(404, 'input not found');
    return '$filesDir/${r.first['stored_path']}';
  }

  /// PNG with what the reader detected drawn on it, so the user can check the reading.
  Future<List<int>> annotatedPng(int id) async {
    final path = imagePath(id), rd = reading(id);
    return Isolate.run(() {
      final img = im.decodePng(File(path).readAsBytesSync())!;
      for (final c in (rd['candles'] as List? ?? const []).cast<Map>()) {
        final col = c['status'] == 'possibly_forming'
            ? im.ColorRgb8(255, 200, 0)
            : (c['bullish'] == true ? im.ColorRgb8(0, 255, 0) : im.ColorRgb8(255, 0, 0));
        final top = [c['y_open'] as int, c['y_close'] as int].reduce((a, b) => a < b ? a : b);
        final bot = [c['y_open'] as int, c['y_close'] as int].reduce((a, b) => a > b ? a : b);
        im.drawRect(img, x1: (c['left'] as int) - 1, y1: top - 1, x2: (c['right'] as int) + 1, y2: bot + 1, color: col);
        im.drawLine(img, x1: c['x'] as int, y1: c['y_high'] as int, x2: c['x'] as int, y2: c['y_low'] as int, color: im.ColorRgb8(0, 255, 255));
      }
      final q = (rd['data_quality'] as num? ?? 0).toStringAsFixed(2);
      im.drawString(img, 'candles=${(rd['candles'] as List? ?? const []).length} q=$q prices=${rd['price_scale'] != null ? 'yes' : 'no'}',
          font: im.arial14, x: 8, y: img.height - 22, color: im.ColorRgb8(255, 255, 0));
      return im.encodePng(img);
    });
  }

  bool delete(int id) {
    final (row, stillUsed) = db.session((d) {
      final r = d.select('SELECT stored_path FROM analysis_inputs WHERE id=?', [id]);
      if (r.isEmpty) return (null, false);
      d.execute('DELETE FROM analysis_inputs WHERE id=?', [id]);
      final used = d.select('SELECT 1 FROM analysis_inputs WHERE stored_path=?', [r.first['stored_path']]).isNotEmpty;
      audit(d, 'user', 'analysis.input_delete', {'input_id': id});
      return (r.first['stored_path'] as String, used);
    });
    if (row == null) return false;
    if (!stillUsed) {
      final f = File('$filesDir/$row');
      if (f.existsSync()) f.deleteSync();
    }
    return true;
  }

  void _enforceRetention() {
    final old = db.session((d) => [for (final r in d.select('SELECT id FROM analysis_inputs ORDER BY id DESC LIMIT -1 OFFSET ?', [maxKeep])) r['id'] as int]);
    for (final id in old) {
      delete(id);
    }
  }
}

/// The recommendation for one image, from the decision engine (same shape as the computer engine).
Map<String, dynamic> analysisFromReading(Map<String, dynamic> reading, int width, int height) {
  final d = (reading['decision'] as Map?) ?? const {};
  return {
    'signal': d['signal'] ?? 'WAIT',
    'reason_code': d['reason_code'] ?? (reading['usable'] == true ? 'signal_engine_not_installed' : 'image_quality_insufficient'),
    'reason_codes': d['reason_codes'] ?? [],
    'reasons': d['reasons'] ?? [],
    'supporting': d['supporting'] ?? [],
    'opposing': d['opposing'] ?? [],
    'steps': d['steps'] ?? [],
    'strategy': d['strategy'],
    'signal_id': d['signal_id'],
    'repeated': d['repeated'] ?? false,
    'data_basis': 'image_only',
    'confidence': d['confidence'],
    'confidence_calibrated': false,
    'duration_sec': d['duration_sec'],
    'data_quality': reading['data_quality'],
    'image': {'width': width, 'height': height},
    'reading': reading['summary'],
    'technical': technicalSummary(reading['technical'] as Map?),
    'knowledge': reading['knowledge'] ?? [],
  };
}

Map<String, dynamic>? technicalSummary(Map? t) {
  if (t == null) return null;
  if (t['available'] != true) return {'available': false, 'reason': t['reason'], 'candles_used': t['candles_used']};
  final active = [for (final f in (t['factors'] as List).cast<Map>()) if (f['enabled'] == true && f['available'] == true) f];
  Map<String, dynamic> brief(Map f) => {'name': f['name'], 'code': f['code'], 'strength': f['strength'], 'params': f['params']};
  final conf = t['confluence'] as Map;
  return {
    'available': true, 'units': t['units'], 'candles_used': t['candles_used'], 'market_condition': t['market_condition'],
    'trend': t['trend'],
    'supporting_bullish': [for (final f in active) if (f['direction'] == 'bullish') brief(f)],
    'supporting_bearish': [for (final f in active) if (f['direction'] == 'bearish') brief(f)],
    'neutral': [for (final f in active) if (f['direction'] == 'neutral') f['name']],
    'disabled': conf['disabled'], 'unavailable': conf['unavailable'], 'bullish_score': conf['bullish_score'],
    'bearish_score': conf['bearish_score'], 'levels': t['levels'],
    'patterns': [for (final p in (t['patterns'] as List).cast<Map>()) p['name']], 'warnings': t['warnings'],
  };
}
