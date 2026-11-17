"""SQLite access layer with versioned migrations.

Design notes
------------
* One short-lived connection per unit of work (``Database.session()``) keeps the
  code thread-safe under FastAPI's thread pool without global locks.
* WAL journal mode + ``synchronous=NORMAL`` gives durability across crashes and
  lets the UI read while a write is in progress. Committed data is never lost when
  the program closes.
* Migrations are plain SQL files named ``schema_v<N>.sql`` applied in order and
  recorded in ``schema_migrations``.
"""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime, timezone
from importlib import resources
from pathlib import Path
from typing import Any

MIGRATIONS = [1]  # append new versions here, add schema_v<N>.sql next to this file


def utcnow() -> str:
    """ISO-8601 UTC timestamp with millisecond precision (sortable as text)."""
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


class Database:
    def __init__(self, path: Path):
        self.path = Path(path)

    # ------------------------------------------------------------ connections
    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = NORMAL")
        return conn

    @contextmanager
    def session(self) -> Iterator[sqlite3.Connection]:
        """Open a connection, run inside a transaction, commit or roll back."""
        conn = self._connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()

    # ------------------------------------------------------------ migrations
    def migrate(self) -> int:
        """Apply pending migrations; return the resulting schema version."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = self._connect()
        try:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS schema_migrations ("
                "version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
            )
            applied = {r[0] for r in conn.execute("SELECT version FROM schema_migrations")}
            for version in MIGRATIONS:
                if version in applied:
                    continue
                sql = resources.files("uata.db").joinpath(f"schema_v{version}.sql").read_text("utf-8")
                conn.executescript("BEGIN;\n" + sql + "\nCOMMIT;")
                conn.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                    (version, utcnow()),
                )
            return self.schema_version(conn)
        finally:
            conn.close()

    @staticmethod
    def schema_version(conn: sqlite3.Connection) -> int:
        row = conn.execute("SELECT max(version) FROM schema_migrations").fetchone()
        return int(row[0] or 0)

    def integrity_ok(self) -> bool:
        conn = self._connect()
        try:
            return conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        finally:
            conn.close()

    def backup_to(self, dest: Path) -> None:
        """Consistent online copy using SQLite's backup API (safe while in use)."""
        src = self._connect()
        dst = sqlite3.connect(dest)
        try:
            src.backup(dst)
        finally:
            dst.close()
            src.close()


# ---------------------------------------------------------------- row helpers
JSON_SUFFIX = "_json"


def row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    """Convert a row to a dict, decoding ``*_json`` columns (``tags_json`` -> ``tags``)."""
    if row is None:
        return None
    out: dict[str, Any] = {}
    for key in row.keys():
        value = row[key]
        if key.endswith(JSON_SUFFIX):
            out[key[: -len(JSON_SUFFIX)]] = json.loads(value) if value else None
        else:
            out[key] = value
    return out


def audit(conn: sqlite3.Connection, actor: str, action: str, **detail: Any) -> None:
    conn.execute(
        "INSERT INTO audit_log(at, actor, action, detail_json) VALUES (?,?,?,?)",
        (utcnow(), actor, action, json.dumps(detail, ensure_ascii=False, default=str)),
    )
