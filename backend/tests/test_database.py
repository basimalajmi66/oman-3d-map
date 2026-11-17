import sqlite3

import pytest

from uata.db.database import Database


def test_migrate_is_idempotent(tmp_path):
    db = Database(tmp_path / "x.sqlite3")
    assert db.migrate() == 2
    assert db.migrate() == 2
    assert db.integrity_ok()


def test_all_tables_exist(tmp_path):
    db = Database(tmp_path / "x.sqlite3")
    db.migrate()
    with db.session() as conn:
        names = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table')")}
    for t in ("settings", "knowledge_sources", "knowledge_items", "knowledge_items_fts", "knowledge_links",
              "knowledge_embeddings", "learning_reports", "strategies", "strategy_examples", "backtest_runs",
              "analysis_sessions", "signals", "trade_results", "audit_log", "schema_migrations",
              "analysis_inputs"):
        assert t in names, t


def test_transaction_rolls_back_on_error(tmp_path):
    db = Database(tmp_path / "x.sqlite3")
    db.migrate()
    with pytest.raises(RuntimeError):
        with db.session() as conn:
            conn.execute("INSERT INTO settings VALUES ('k','1','t')")
            raise RuntimeError("boom")
    with db.session() as conn:
        assert conn.execute("SELECT count(*) FROM settings").fetchone()[0] == 0


def test_constraints_reject_invalid_signal(tmp_path):
    db = Database(tmp_path / "x.sqlite3")
    db.migrate()
    with pytest.raises(sqlite3.IntegrityError):
        with db.session() as conn:  # BUY without duration violates CHECK
            conn.execute("INSERT INTO signals(created_at,timeframe_sec,signal,data_basis,engine_version) "
                         "VALUES ('t',30,'BUY','image_only','0')")
    with pytest.raises(sqlite3.IntegrityError):
        with db.session() as conn:
            conn.execute("INSERT INTO signals(created_at,timeframe_sec,signal,data_basis,engine_version) "
                         "VALUES ('t',30,'MAYBE','image_only','0')")


def test_data_persists_across_reopen(tmp_path):
    path = tmp_path / "x.sqlite3"
    db = Database(path)
    db.migrate()
    with db.session() as conn:
        conn.execute("INSERT INTO settings VALUES ('k','1','t')")
    db2 = Database(path)
    db2.migrate()
    with db2.session() as conn:
        assert conn.execute("SELECT value_json FROM settings WHERE key='k'").fetchone()[0] == "1"


def test_upgrade_from_v1_database(tmp_path, monkeypatch):
    """A database created by Phase 1 (schema v1) is upgraded in place without data loss."""
    from uata.db import database as dbmod
    path = tmp_path / "old.sqlite3"
    monkeypatch.setattr(dbmod, "MIGRATIONS", [1])
    old = Database(path)
    assert old.migrate() == 1
    with old.session() as conn:
        conn.execute("INSERT INTO settings VALUES ('k','\"kept\"','t')")
    monkeypatch.setattr(dbmod, "MIGRATIONS", [1, 2])
    assert Database(path).migrate() == 2
    with Database(path).session() as conn:
        assert conn.execute("SELECT value_json FROM settings WHERE key='k'").fetchone()[0] == '"kept"'
        conn.execute("SELECT count(*) FROM analysis_inputs").fetchone()
