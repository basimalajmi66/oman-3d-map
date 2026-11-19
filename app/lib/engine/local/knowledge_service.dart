/// The knowledge library on the phone (port of services/knowledge_service.py).
///
/// Everything the user adds becomes a *source*; what is extracted from it becomes *items* in `pending_review`
/// plus a *learning report* (sections, candidate rules, conflicts with approved rules). Only items the user
/// explicitly approves are ever used by the analysis. Same tables as the computer engine, so a backup moves both ways.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/engine_api.dart';
import '../knowledge/extract.dart' as kx;
import '../knowledge/retrieval.dart';
import '../knowledge/rules.dart';
import '../knowledge/textnorm.dart';
import 'db.dart';
import 'services.dart' show badRequest;

const maxUploadBytes = 200 * 1024 * 1024; // the phone keeps documents; videos stay on the computer
const extKind = {
  '.pdf': 'pdf', '.docx': 'docx', '.xlsx': 'xlsx', '.xlsm': 'xlsx', '.txt': 'txt', '.md': 'txt', '.csv': 'txt', //
  '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.webp': 'image', '.bmp': 'image',
  '.mp4': 'video', '.mkv': 'video', '.mov': 'video', '.avi': 'video', '.webm': 'video',
};
const itemTypes = ['note', 'rule', 'strategy_fragment', 'example', 'definition'];

EngineException _nf(String what) => EngineException(404, 'not found: $what');

class KnowledgeService {
  KnowledgeService(this.db, this.filesDir) {
    db.session((d) => retriever.reindexMissing(d, utcnow())); // items restored from a backup get indexed once
  }
  final LocalDb db;
  final String filesDir;
  final retriever = Retriever();

  Map<String, dynamic> _ingest(Database conn, int sid, List<kx.Chunk> chunks, String baseTitle, String? category,
      String tagsJson, String now,
      {String itemType = 'note'}) {
    final itemIds = <int>[];
    final rules = <CandidateRule>[];
    for (final ch in chunks) {
      final title = chunks.length == 1 ? baseTitle : '$baseTitle — ${ch.location}';
      conn.execute(
          'INSERT INTO knowledge_items(source_id,item_type,title,content,category,tags_json,location,created_at,updated_at) '
          'VALUES (?,?,?,?,?,?,?,?,?)',
          [sid, itemType, title, ch.text, category, tagsJson, ch.location, now, now]);
      final iid = conn.lastInsertRowId;
      itemIds.add(iid);
      retriever.indexItem(conn, iid, '$title\n${ch.text}', now);
      rules.addAll(extractRules(ch.text, ch.location));
    }
    final approved = [
      for (final r in conn.select("SELECT id, content, rule_json FROM knowledge_items WHERE status='approved' AND rule_json IS NOT NULL"))
        {'item_id': r['id'], 'text': r['content'], ...(jsonDecode(r['rule_json'] as String) as Map).cast<String, dynamic>()}
    ];
    final found = <Map<String, dynamic>>[];
    final ruleEntries = <Map<String, dynamic>>[];
    for (final r in rules) {
      conn.execute(
          'INSERT INTO knowledge_items(source_id,item_type,title,content,category,tags_json,location,rule_json,created_at,updated_at) '
          "VALUES (?,'rule',?,?,?,?,?,?,?,?)",
          [sid, '$baseTitle — rule (${r.location})', r.text, category, tagsJson, r.location,
            jsonEncode({'actions': r.actions, 'conditions': r.conditions, 'timeframes': r.timeframes}), now, now]);
      final iid = conn.lastInsertRowId;
      retriever.indexItem(conn, iid, r.text, now);
      for (final c in conflicts(r, approved)) {
        found.add({...c, 'new_item_id': iid});
      }
      ruleEntries.add({'item_id': iid, ...r.toJson()});
    }
    final allText = chunks.map((c) => c.text).join('\n');
    final summary = '${chunks.length} section(s), ${rules.length} candidate rule(s), ${found.length} conflict(s) with approved knowledge';
    final extracted = {
      'chunks': chunks.length, 'items': itemIds, 'rules': ruleEntries,
      'concepts': (concepts(allText).where((c) => !c.startsWith('act_')).toList()..sort()),
      'locations': chunks.map((c) => c.location).take(50).toList(), 'characters': allText.length,
    };
    conn.execute(
        "INSERT INTO learning_reports(source_id,summary,extracted_json,conflicts_json,status,created_at) VALUES (?,?,?,?,'pending_review',?)",
        [sid, summary, jsonEncode(extracted), jsonEncode(found), now]);
    return {'report_id': conn.lastInsertRowId, 'rules': rules.length, 'conflicts': found.length};
  }

  // ------------------------------------------------------------ learning reports
  List<Map<String, dynamic>> listReports({String? status, int limit = 100}) => db.session((d) => [
        for (final r in d.select(
            'SELECT r.*, s.title AS source_title, s.kind AS source_kind FROM learning_reports r '
            'LEFT JOIN knowledge_sources s ON s.id=r.source_id${status == null ? '' : ' WHERE r.status=?'} ORDER BY r.id DESC LIMIT ?',
            [?status, limit]))
          rowToMap(r)
      ]);

  Map<String, dynamic> decideReport(int reportId, String decision) {
    final status = {'approve': 'approved', 'reject': 'rejected'}[decision];
    if (status == null) throw badRequest("decision must be 'approve' or 'reject'");
    final now = utcnow();
    return db.session((d) {
      final row = d.select('SELECT source_id, status FROM learning_reports WHERE id=?', [reportId]);
      if (row.isEmpty) throw _nf('report $reportId');
      d.execute('UPDATE learning_reports SET status=?, decided_at=? WHERE id=?', [status, now, reportId]);
      d.execute("UPDATE knowledge_items SET status=?, decided_at=?, updated_at=? WHERE source_id=? AND status='pending_review'",
          [status, now, now, row.first['source_id']]);
      final n = d.updatedRows;
      audit(d, 'user', 'knowledge.report_$decision', {'report_id': reportId, 'items': n});
      return firstRow(d.select(
          'SELECT r.*, s.title AS source_title FROM learning_reports r LEFT JOIN knowledge_sources s ON s.id=r.source_id WHERE r.id=?',
          [reportId]))!
        ..['items_updated'] = n;
    });
  }

  List<Map<String, dynamic>> retrieve(String query, {bool approvedOnly = true, int k = 8}) =>
      db.session((d) => retriever.search(d, query, approvedOnly: approvedOnly, k: k));

  // ------------------------------------------------------------ sources
  Map<String, dynamic> addNote(String title, String content, {String? category, List<String> tags = const [], String itemType = 'note'}) {
    if (title.trim().isEmpty || content.trim().isEmpty) throw badRequest('title and content are required');
    if (title.length > 300 || content.length > 200000) throw EngineException(422, 'note too long');
    if (!itemTypes.contains(itemType)) throw badRequest('item_type must be one of $itemTypes');
    final now = utcnow();
    final tagsJson = jsonEncode(tags);
    final sid = db.session((d) {
      d.execute(
          'INSERT INTO knowledge_sources(kind,title,category,tags_json,extraction_status,extracted_text,created_at,updated_at) '
          "VALUES ('note',?,?,?, 'done', ?,?,?)",
          [title.trim(), category, tagsJson, content, now, now]);
      final sid = d.lastInsertRowId;
      _ingest(d, sid, [kx.Chunk(content.trim(), 'note')], title.trim(), category, tagsJson, now, itemType: itemType);
      audit(d, 'user', 'knowledge.add_note', {'source_id': sid});
      return sid;
    });
    return getSource(sid);
  }

  /// Catalogue a link. The page is NOT fetched (no network access without permission).
  Map<String, dynamic> addUrl(String url, {String? title, String? notes}) {
    if (!RegExp(r'^https?://').hasMatch(url)) throw badRequest('url must start with http:// or https://');
    final now = utcnow();
    final sid = db.session((d) {
      d.execute(
          "INSERT INTO knowledge_sources(kind,title,url,notes,extraction_status,created_at,updated_at) VALUES ('url',?,?,?,'unsupported_yet',?,?)",
          [title ?? url, url, notes, now, now]);
      final sid = d.lastInsertRowId;
      audit(d, 'user', 'knowledge.add_url', {'source_id': sid});
      return sid;
    });
    return getSource(sid);
  }

  Map<String, dynamic> addFile(String filename, Uint8List data, {String? title, String? category, List<String> tags = const []}) {
    final safeName = filename.split(RegExp(r'[\\/]')).last.isEmpty ? 'upload.bin' : filename.split(RegExp(r'[\\/]')).last;
    final dot = safeName.lastIndexOf('.');
    final ext = dot >= 0 ? safeName.substring(dot).toLowerCase() : '';
    final kind = extKind[ext] ?? 'other';
    if (data.isEmpty) throw badRequest('empty file');
    if (data.length > maxUploadBytes) throw badRequest('file too large for the phone (max 200 MB) — add it on the computer');
    final digest = sha256.convert(data).toString();
    final existing = db.session((d) => d.select('SELECT id FROM knowledge_sources WHERE sha256=?', [digest]));
    if (existing.isNotEmpty) {
      throw EngineException(409, 'file already in library as source ${existing.first['id']}');
    }
    final rel = '${digest.substring(0, 2)}/$digest$ext';
    final dest = File('$filesDir/$rel');
    dest.parent.createSync(recursive: true);
    dest.writeAsBytesSync(data, flush: true);
    var chunks = <kx.Chunk>[];
    var status = 'unsupported_yet';
    String? error;
    if (kx.phoneExtractable.contains(kind)) {
      try {
        chunks = kx.extract(kind, data);
        status = 'done';
      } on kx.ExtractionError catch (e) {
        status = 'failed';
        error = e.message;
      }
    }
    final text = chunks.isEmpty ? null : chunks.map((c) => c.text).join('\n\n');
    final now = utcnow();
    final tagsJson = jsonEncode(tags);
    final sid = db.session((d) {
      d.execute(
          'INSERT INTO knowledge_sources(kind,title,original_name,mime_type,sha256,stored_path,size_bytes,category,tags_json,'
          'extraction_status,extracted_text,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [kind, title ?? safeName, safeName, null, digest, rel, data.length, category, tagsJson, status, text, now, now]);
      final sid = d.lastInsertRowId;
      if (error != null) d.execute('UPDATE knowledge_sources SET notes=? WHERE id=?', ['extraction: $error', sid]);
      if (status == 'unsupported_yet' && kind != 'other') {
        d.execute('UPDATE knowledge_sources SET notes=? WHERE id=?',
            ['$kind files are kept here; their content is extracted by the computer app (connect or restore a backup there)', sid]);
      }
      if (chunks.isNotEmpty) _ingest(d, sid, chunks, title ?? safeName, category, tagsJson, now);
      audit(d, 'user', 'knowledge.add_file', {'source_id': sid, 'kind': kind, 'size': data.length, 'extraction': status});
      return sid;
    });
    return getSource(sid);
  }

  Map<String, dynamic> _public(Map<String, dynamic> d) {
    final text = d.remove('extracted_text') as String?;
    d['extracted_chars'] = text?.length ?? 0;
    return d;
  }

  List<Map<String, dynamic>> listSources({String? kind, String? category, int limit = 100}) => db.session((d) => [
        for (final r in d.select(
            'SELECT s.*, (SELECT count(*) FROM knowledge_items i WHERE i.source_id=s.id) AS item_count, '
            "(SELECT count(*) FROM knowledge_items i WHERE i.source_id=s.id AND i.status='pending_review') AS pending_count "
            'FROM knowledge_sources s WHERE 1=1${kind == null ? '' : ' AND s.kind=?'}${category == null ? '' : ' AND s.category=?'} '
            'ORDER BY s.id DESC LIMIT ?',
            [?kind, ?category, limit]))
          _public(rowToMap(r))
      ]);

  Map<String, dynamic> getSource(int id) => db.session((d) {
        final row = d.select('SELECT * FROM knowledge_sources WHERE id=?', [id]);
        if (row.isEmpty) throw _nf('source $id');
        final src = _public(rowToMap(row.first));
        src['items'] = [for (final i in d.select('SELECT * FROM knowledge_items WHERE source_id=? ORDER BY id', [id])) rowToMap(i)];
        src['report'] = firstRow(d.select('SELECT * FROM learning_reports WHERE source_id=? ORDER BY id DESC LIMIT 1', [id]));
        return src;
      });

  void deleteSource(int id) {
    final row = db.session((d) {
      final r = d.select('SELECT stored_path FROM knowledge_sources WHERE id=?', [id]);
      if (r.isEmpty) throw _nf('source $id');
      d.execute('DELETE FROM knowledge_sources WHERE id=?', [id]);
      audit(d, 'user', 'knowledge.delete_source', {'source_id': id});
      return r.first['stored_path'] as String?;
    });
    if (row != null) {
      final f = File('$filesDir/$row');
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// User approval gate. `decision` is 'approve' or 'reject'.
  Map<String, dynamic> decideItem(int itemId, String decision) {
    final status = {'approve': 'approved', 'reject': 'rejected'}[decision];
    if (status == null) throw badRequest("decision must be 'approve' or 'reject'");
    return db.session((d) {
      d.execute('UPDATE knowledge_items SET status=?, decided_at=?, updated_at=? WHERE id=?', [status, utcnow(), utcnow(), itemId]);
      if (d.updatedRows == 0) throw _nf('item $itemId');
      audit(d, 'user', 'knowledge.$decision', {'item_id': itemId});
      return firstRow(d.select('SELECT * FROM knowledge_items WHERE id=?', [itemId]))!;
    });
  }

  List<Map<String, dynamic>> search(String query, {bool approvedOnly = false, int limit = 20}) {
    if (query.trim().isEmpty) return [];
    return [
      for (final h in retrieve(query, approvedOnly: approvedOnly, k: limit)) {...h, 'id': h['item_id'], 'content': h['snippet']}
    ];
  }
}

/// Retrieval query from the directional factors and patterns of an analysis (as chart_input_service.knowledge_query).
String knowledgeQuery(Map technical) {
  final cs = <String>[];
  for (final f in (technical['factors'] as List? ?? const []).cast<Map>()) {
    if (f['enabled'] == true && f['available'] == true && f['direction'] != 'neutral') {
      final byCode = factorConcepts[f['code']] ?? const [];
      cs.addAll(byCode.isNotEmpty ? byCode : (factorConcepts[f['name']] ?? const []));
    }
  }
  for (final p in (technical['patterns'] as List? ?? const []).cast<Map>()) {
    cs.addAll(factorConcepts['pattern_${p['name']}'] ?? const []);
  }
  final trend = (technical['trend'] as Map?)?['direction'];
  if (trend == 'up' || trend == 'down') cs.add(trend == 'up' ? 'uptrend' : 'downtrend');
  final out = <String>[];
  final seen = <String>{};
  for (final c in cs) {
    if (seen.add(c)) out.addAll(surfaceForms(c).take(2));
  }
  return out.join(' ');
}
