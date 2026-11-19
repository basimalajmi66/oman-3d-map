/// Local hybrid retrieval (port of knowledge/retrieval.py): FTS5/BM25 keywords + local hashing vectors, fused
/// with RRF. The vectors are the same as the computer engine's (blake2b feature hashing), so a restored backup's
/// index stays valid on the phone and vice versa.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pointycastle/digests/blake2b.dart';
import 'package:sqlite3/sqlite3.dart';

import '../local/db.dart';
import 'textnorm.dart';

final _arabic = RegExp('[؀-ۿ]');
final _clitic = RegExp('^(وال|بال|فال|كال|لل|ال)');

class HashingEmbedder {
  HashingEmbedder({this.dim = 2048});
  final String name = 'hashing-v1';
  final int dim;
  final _f32 = Float32List(1);

  double _fround(double x) => (_f32..[0] = x)[0];

  (int, double) _idx(String feat) {
    final d = Blake2bDigest(digestSize: 8).process(Uint8List.fromList(utf8.encode(feat)));
    var h = BigInt.zero;
    for (var i = 7; i >= 0; i--) {
      h = (h << 8) | BigInt.from(d[i]); // little-endian unsigned 64-bit
    }
    return ((h % BigInt.from(dim)).toInt(), (d[7] >> 7) & 1 == 1 ? 1.0 : -1.0);
  }

  /// Insertion-ordered feature weights, like Python's Counter.
  Map<String, double> features(String text) {
    final t = normalize(text);
    final ws = words(t);
    final f = <String, double>{};
    void add(String k, double v) => f[k] = (f[k] ?? 0) + v;
    for (final w in ws) {
      add('w:$w', 1.0);
      final core = _arabic.hasMatch(w) ? w.replaceFirst(_clitic, '') : w;
      if (core != w) add('w:$core', 1.0);
      final padded = '#$core#'.runes.toList();
      for (var i = 0; i < padded.length - 2; i++) {
        add('c:${String.fromCharCodes(padded.sublist(i, i + 3))}', 0.35);
      }
    }
    for (var i = 0; i + 1 < ws.length; i++) {
      add('b:${ws[i]}_${ws[i + 1]}', 0.7);
    }
    for (final c in concepts(text)) {
      add('k:$c', 2.0); // bilingual concept bridge
    }
    return f;
  }

  Float32List embed(String text) {
    final v = Float32List(dim);
    for (final e in features(text).entries) {
      final (i, sign) = _idx(e.key);
      final tf = e.value;
      v[i] = v[i] + _fround(tf >= 1 ? sign * (1.0 + math.log(tf)) : sign * tf);
    }
    var n = 0.0;
    for (final x in v) {
      n += x * x;
    }
    n = math.sqrt(n);
    if (n > 0) {
      for (var i = 0; i < dim; i++) {
        v[i] = v[i] / n;
      }
    }
    return v;
  }
}

/// Add the other-language surface forms of every concept in the query.
String expandQuery(String query) {
  final extra = [for (final c in concepts(query)) ...surfaceForms(c).take(3)];
  return extra.isEmpty ? query : '$query ${extra.join(' ')}';
}

/// OR of prefix terms (recall-oriented; ranking by BM25 + fusion).
String? ftsOrQuery(String text) {
  final tokens = words(text);
  if (tokens.isEmpty) return null;
  final uniq = <String>[];
  for (final t in tokens.take(24)) {
    if (!uniq.contains(t)) uniq.add(t);
  }
  return uniq.map((t) => '"$t"*').join(' OR ');
}

class Retriever {
  Retriever([HashingEmbedder? embedder]) : embedder = embedder ?? HashingEmbedder();
  final HashingEmbedder embedder;

  void indexItem(Database db, int itemId, String text, String now) {
    final v = embedder.embed(text);
    db.execute(
        'INSERT INTO knowledge_embeddings(item_id, model, dim, vector, created_at) VALUES (?,?,?,?,?) '
        'ON CONFLICT(item_id) DO UPDATE SET model=excluded.model, dim=excluded.dim, vector=excluded.vector, '
        'created_at=excluded.created_at',
        [itemId, embedder.name, embedder.dim, v.buffer.asUint8List(), now]);
  }

  int reindexMissing(Database db, String now) {
    final rows = db.select(
        'SELECT i.id, i.title, i.content FROM knowledge_items i LEFT JOIN knowledge_embeddings e '
        'ON e.item_id=i.id WHERE e.item_id IS NULL OR e.model<>?',
        [embedder.name]);
    for (final r in rows) {
      indexItem(db, r['id'] as int, '${r['title']}\n${r['content']}', now);
    }
    return rows.length;
  }

  List<Map<String, dynamic>> search(Database db, String query, {bool approvedOnly = true, int k = 8, int rrfK = 60}) {
    final q = expandQuery(query);
    final statusSql = approvedOnly ? " AND i.status='approved'" : " AND i.status IN ('approved','pending_review')";
    final ranks = <int, Map<String, num>>{};
    final fq = ftsOrQuery('${normalize(q)} $q');
    if (fq != null) {
      final rows = db.select(
          'SELECT i.id FROM knowledge_items_fts f JOIN knowledge_items i ON i.id=f.rowid '
          'WHERE knowledge_items_fts MATCH ?$statusSql ORDER BY bm25(knowledge_items_fts) LIMIT 50',
          [fq]);
      for (var rank = 0; rank < rows.length; rank++) {
        ranks.putIfAbsent(rows[rank]['id'] as int, () => {})['kw'] = rank;
      }
    }
    final qv = embedder.embed(q);
    final vrows = db.select(
        'SELECT e.item_id, e.vector FROM knowledge_embeddings e JOIN knowledge_items i ON i.id=e.item_id '
        'WHERE e.model=?$statusSql',
        [embedder.name]);
    final sims = <(int, double)>[];
    for (final r in vrows) {
      final bytes = r['vector'] as Uint8List;
      final vec = Float32List.view(Uint8List.fromList(bytes).buffer);
      var s = 0.0;
      for (var i = 0; i < vec.length && i < qv.length; i++) {
        s += vec[i] * qv[i];
      }
      sims.add((r['item_id'] as int, s));
    }
    sims.sort((a, b) => b.$2.compareTo(a.$2));
    for (var rank = 0; rank < sims.length && rank < 50; rank++) {
      if (sims[rank].$2 <= 0.05) break;
      ranks.putIfAbsent(sims[rank].$1, () => {})
        ..['vec'] = rank
        ..['sim'] = sims[rank].$2;
    }
    final scored = [
      for (final e in ranks.entries)
        (e.value.entries.where((x) => x.key == 'kw' || x.key == 'vec').fold<double>(0, (s, x) => s + 1.0 / (rrfK + x.value)), e.key, e.value)
    ]..sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.compareTo(a.$2));
    final top = scored.take(k).toList();
    if (top.isEmpty) return [];
    final ids = [for (final s in top) s.$2];
    final meta = {
      for (final r in db.select(
          'SELECT i.id, i.title, i.content, i.status, i.item_type, i.location, i.source_id, s.title AS source_title, '
          's.kind AS source_kind FROM knowledge_items i LEFT JOIN knowledge_sources s ON s.id=i.source_id '
          'WHERE i.id IN (${List.filled(ids.length, '?').join(',')})',
          ids))
        r['id'] as int: rowToMap(r)
    };
    return [
      for (final (score, iid, v) in top)
        {
          'item_id': iid, 'title': meta[iid]!['title'],
          'snippet': (meta[iid]!['content'] as String).substring(0, math.min(300, (meta[iid]!['content'] as String).length)),
          'status': meta[iid]!['status'], 'item_type': meta[iid]!['item_type'], 'location': meta[iid]!['location'],
          'source_id': meta[iid]!['source_id'], 'source_title': meta[iid]!['source_title'], 'source_kind': meta[iid]!['source_kind'],
          'score': (score * 100000).round() / 100000,
          'matched_by': [for (final key in const ['kw', 'vec']) if (v.containsKey(key)) key],
          'similarity': ((v['sim'] ?? 0.0) * 1000).round() / 1000,
        }
    ];
  }
}
