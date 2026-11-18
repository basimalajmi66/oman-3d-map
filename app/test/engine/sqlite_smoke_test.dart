import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('sqlite with FTS5 is available', () {
    final db = sqlite3.openInMemory();
    db.execute('CREATE VIRTUAL TABLE t USING fts5(x)');
    db.execute("INSERT INTO t VALUES ('hello world')");
    expect(db.select("SELECT x FROM t WHERE t MATCH 'hello'").single['x'], 'hello world');
    db.close();
  });
}
