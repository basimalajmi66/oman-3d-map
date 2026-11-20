/// On-device SQLite store: the SAME schema files as the computer engine (assets/schema = backend/uata/db),
/// applied as versioned migrations; one transaction per unit of work; WAL for crash safety.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

const migrations = [1, 2, 3, 4, 5, 6, 7, 8]; // keep in step with backend/uata/db/database.py

/// Same format as Python's `datetime.now(timezone.utc).isoformat(timespec="milliseconds")`.
String utcnow() {
  final t = DateTime.now().toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}:'
      '${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}+00:00';
}

typedef SchemaLoader = Future<String> Function(int version);

class LocalDb {
  LocalDb._(this.path, this._db);
  final String path;
  Database _db;

  static Future<LocalDb> open(String path, SchemaLoader schema) async {
    File(path).parent.createSync(recursive: true);
    final db = LocalDb._(path, _connect(path));
    await db.migrate(schema);
    return db;
  }

  static Database _connect(String path) {
    final d = sqlite3.open(path);
    d.execute('PRAGMA foreign_keys = ON');
    d.execute('PRAGMA journal_mode = WAL');
    d.execute('PRAGMA synchronous = NORMAL');
    d.execute('PRAGMA busy_timeout = 5000'); // the background service has its own connection to the same file
    return d;
  }

  Future<int> migrate(SchemaLoader schema) async {
    _db.execute('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)');
    final applied = {for (final r in _db.select('SELECT version FROM schema_migrations')) r['version'] as int};
    for (final v in migrations) {
      if (applied.contains(v)) continue;
      final sql = await schema(v);
      _db.execute('BEGIN');
      try {
        _db.execute(sql);
        _db.execute('INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)', [v, utcnow()]);
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
    return _db.select('SELECT max(version) AS v FROM schema_migrations').first['v'] as int;
  }

  /// Run `fn` inside one transaction (commit on success, roll back on any error).
  T session<T>(T Function(Database db) fn) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = fn(_db);
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  bool integrityOk() {
    try {
      return _db.select('PRAGMA integrity_check').first.values.first == 'ok';
    } catch (_) {
      return false;
    }
  }

  /// Delete the database file and start an empty one ("delete all my data").
  Future<void> recreate(SchemaLoader schema) async {
    _db.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    _db = _connect(path);
    await migrate(schema);
  }

  /// Consistent copy of the live database (safe while in use).
  void copyTo(String dest) {
    final f = File(dest);
    if (f.existsSync()) f.deleteSync();
    _db.execute('VACUUM INTO ?', [dest]);
  }

  int schemaVersion() => _db.select('SELECT max(version) AS v FROM schema_migrations').first['v'] as int? ?? 0;

  /// Swap in another database file (a validated backup), then upgrade it to the current schema.
  Future<int> replaceWith(String source, SchemaLoader schema) async {
    _db.close();
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    File(source).copySync(path);
    _db = _connect(path);
    return migrate(schema);
  }

  void close() => _db.close();
}

/// True when `path` is an intact SQLite database.
bool sqliteIntegrityOk(String path) {
  try {
    final d = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return d.select('PRAGMA integrity_check').first.values.first == 'ok';
    } finally {
      d.close();
    }
  } catch (_) {
    return false;
  }
}

/// A row as a map; `*_json` columns are decoded (`tags_json` → `tags`), like the Python `row_to_dict`.
Map<String, dynamic> rowToMap(Row row) {
  final out = <String, dynamic>{};
  for (final k in row.keys) {
    final v = row[k];
    if (k.endsWith('_json')) {
      out[k.substring(0, k.length - 5)] = (v is String && v.isNotEmpty) ? jsonDecode(v) : null;
    } else {
      out[k] = v;
    }
  }
  return out;
}

Map<String, dynamic>? firstRow(ResultSet rs) => rs.isEmpty ? null : rowToMap(rs.first);

void audit(Database db, String actor, String action, [Map<String, dynamic> detail = const {}]) =>
    db.execute('INSERT INTO audit_log(at, actor, action, detail_json) VALUES (?,?,?,?)',
        [utcnow(), actor, action, jsonEncode(detail, toEncodable: (o) => '$o')]);
