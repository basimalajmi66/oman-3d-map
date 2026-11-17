"""Local knowledge library.

Approval workflow (spec section 8): everything the user adds becomes a *source*;
knowledge extracted from it becomes *items* in ``pending_review``. Only items the
user explicitly approves are ever visible to the analysis engine
(``search(..., approved_only=True)``).

Phase 1 extraction support: notes, TXT/MD/CSV (plain text). PDF, DOCX, XLSX,
images and videos are stored, hashed and catalogued now; their content
extraction is implemented in Phases 3, 5 and 6 and is reported as
``unsupported_yet`` instead of being silently ignored.
"""

from __future__ import annotations

import hashlib
import json
import mimetypes
import re
import shutil
from pathlib import Path
from typing import Any, BinaryIO

from uata.db.database import Database, audit, row_to_dict, utcnow

MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB (videos)
CHUNK_CHARS = 1500

EXT_KIND = {
    ".pdf": "pdf", ".docx": "docx", ".xlsx": "xlsx", ".xlsm": "xlsx",
    ".txt": "txt", ".md": "txt", ".csv": "txt",
    ".png": "image", ".jpg": "image", ".jpeg": "image", ".webp": "image", ".bmp": "image",
    ".mp4": "video", ".mkv": "video", ".mov": "video", ".avi": "video", ".webm": "video",
}
TEXT_KINDS = {"txt"}
ITEM_TYPES = ("note", "rule", "strategy_fragment", "example", "definition")


class NotFound(Exception):
    pass


class Duplicate(Exception):
    def __init__(self, source_id: int):
        super().__init__(f"file already in library as source {source_id}")
        self.source_id = source_id


def chunk_text(text: str, size: int = CHUNK_CHARS) -> list[str]:
    """Split on blank lines, packing paragraphs into chunks of at most ~``size`` chars."""
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks: list[str] = []
    buf = ""
    for p in paragraphs:
        while len(p) > size:  # hard-split very long paragraphs
            if buf:
                chunks.append(buf)
                buf = ""
            chunks.append(p[:size])
            p = p[size:]
        if buf and len(buf) + 2 + len(p) > size:
            chunks.append(buf)
            buf = p
        else:
            buf = f"{buf}\n\n{p}" if buf else p
    if buf:
        chunks.append(buf)
    return chunks


def fts_query(text: str) -> str | None:
    """Turn free user text into a safe FTS5 query (AND of prefix terms)."""
    tokens = re.findall(r"\w+", text, flags=re.UNICODE)
    if not tokens:
        return None
    return " ".join(f'"{t}"*' for t in tokens[:12])


class KnowledgeService:
    def __init__(self, db: Database, files_dir: Path):
        self.db = db
        self.files_dir = Path(files_dir)

    # ------------------------------------------------------------ sources
    def add_note(self, title: str, content: str, category: str | None = None,
                 tags: list[str] | None = None, item_type: str = "note") -> dict[str, Any]:
        if not title.strip() or not content.strip():
            raise ValueError("title and content are required")
        if item_type not in ITEM_TYPES:
            raise ValueError(f"item_type must be one of {ITEM_TYPES}")
        now = utcnow()
        tags_json = json.dumps(tags or [], ensure_ascii=False)
        with self.db.session() as conn:
            sid = conn.execute(
                "INSERT INTO knowledge_sources(kind,title,category,tags_json,extraction_status,"
                "extracted_text,created_at,updated_at) VALUES ('note',?,?,?, 'done', ?,?,?)",
                (title.strip(), category, tags_json, content, now, now)).lastrowid
            conn.execute(
                "INSERT INTO knowledge_items(source_id,item_type,title,content,category,tags_json,"
                "created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)",
                (sid, item_type, title.strip(), content.strip(), category, tags_json, now, now))
            audit(conn, "user", "knowledge.add_note", source_id=sid)
        return self.get_source(sid)

    def add_url(self, url: str, title: str | None = None, notes: str | None = None) -> dict[str, Any]:
        """Catalogue a link. The page is NOT fetched (no network access without permission)."""
        if not re.match(r"^https?://", url):
            raise ValueError("url must start with http:// or https://")
        now = utcnow()
        with self.db.session() as conn:
            sid = conn.execute(
                "INSERT INTO knowledge_sources(kind,title,url,notes,extraction_status,created_at,updated_at)"
                " VALUES ('url',?,?,?,'unsupported_yet',?,?)",
                (title or url, url, notes, now, now)).lastrowid
            audit(conn, "user", "knowledge.add_url", source_id=sid)
        return self.get_source(sid)

    def add_file(self, filename: str, stream: BinaryIO, title: str | None = None,
                 category: str | None = None, tags: list[str] | None = None) -> dict[str, Any]:
        safe_name = Path(filename).name or "upload.bin"
        ext = Path(safe_name).suffix.lower()
        kind = EXT_KIND.get(ext, "other")
        tmp = self.files_dir / f".incoming-{hashlib.sha256(safe_name.encode()).hexdigest()[:12]}-{id(stream)}"
        hasher = hashlib.sha256()
        size = 0
        try:
            with tmp.open("wb") as out:
                while chunk := stream.read(1024 * 1024):
                    size += len(chunk)
                    if size > MAX_UPLOAD_BYTES:
                        raise ValueError("file too large")
                    hasher.update(chunk)
                    out.write(chunk)
            if size == 0:
                raise ValueError("empty file")
            digest = hasher.hexdigest()
            with self.db.session() as conn:
                existing = conn.execute("SELECT id FROM knowledge_sources WHERE sha256=?", (digest,)).fetchone()
            if existing:
                raise Duplicate(existing[0])
            rel = f"{digest[:2]}/{digest}{ext}"
            dest = self.files_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(tmp), dest)
        finally:
            tmp.unlink(missing_ok=True)

        text, status = None, "unsupported_yet"
        if kind in TEXT_KINDS:
            try:
                text = dest.read_bytes().decode("utf-8-sig")
                status = "done"
            except UnicodeDecodeError:
                status = "failed"

        now = utcnow()
        tags_json = json.dumps(tags or [], ensure_ascii=False)
        with self.db.session() as conn:
            sid = conn.execute(
                "INSERT INTO knowledge_sources(kind,title,original_name,mime_type,sha256,stored_path,"
                "size_bytes,category,tags_json,extraction_status,extracted_text,created_at,updated_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (kind, title or safe_name, safe_name, mimetypes.guess_type(safe_name)[0], digest, rel,
                 size, category, tags_json, status, text, now, now)).lastrowid
            for i, chunk in enumerate(chunk_text(text or "")):
                conn.execute(
                    "INSERT INTO knowledge_items(source_id,item_type,title,content,category,tags_json,"
                    "created_at,updated_at) VALUES (?,'note',?,?,?,?,?,?)",
                    (sid, f"{title or safe_name} §{i + 1}", chunk, category, tags_json, now, now))
            audit(conn, "user", "knowledge.add_file", source_id=sid, kind=kind, size=size)
        return self.get_source(sid)

    def list_sources(self, kind: str | None = None, category: str | None = None,
                     limit: int = 100, offset: int = 0) -> list[dict[str, Any]]:
        sql = ("SELECT s.*, (SELECT count(*) FROM knowledge_items i WHERE i.source_id=s.id) AS item_count, "
               "(SELECT count(*) FROM knowledge_items i WHERE i.source_id=s.id AND i.status='pending_review') "
               "AS pending_count FROM knowledge_sources s WHERE 1=1")
        args: list[Any] = []
        if kind:
            sql += " AND s.kind=?"
            args.append(kind)
        if category:
            sql += " AND s.category=?"
            args.append(category)
        sql += " ORDER BY s.id DESC LIMIT ? OFFSET ?"
        args += [limit, offset]
        with self.db.session() as conn:
            rows = conn.execute(sql, args).fetchall()
        return [self._public_source(row_to_dict(r)) for r in rows]

    def get_source(self, source_id: int) -> dict[str, Any]:
        with self.db.session() as conn:
            row = conn.execute("SELECT * FROM knowledge_sources WHERE id=?", (source_id,)).fetchone()
            if row is None:
                raise NotFound(f"source {source_id}")
            items = conn.execute(
                "SELECT * FROM knowledge_items WHERE source_id=? ORDER BY id", (source_id,)).fetchall()
        src = self._public_source(row_to_dict(row))
        src["items"] = [row_to_dict(i) for i in items]
        return src

    def update_source(self, source_id: int, patch: dict[str, Any]) -> dict[str, Any]:
        allowed = {"title", "category", "tags", "notes"}
        bad = set(patch) - allowed
        if bad:
            raise ValueError(f"cannot update fields: {sorted(bad)}")
        sets, args = [], []
        for k, v in patch.items():
            if k == "tags":
                sets.append("tags_json=?")
                args.append(json.dumps(v or [], ensure_ascii=False))
            else:
                sets.append(f"{k}=?")
                args.append(v)
        if not sets:
            return self.get_source(source_id)
        with self.db.session() as conn:
            n = conn.execute(f"UPDATE knowledge_sources SET {', '.join(sets)}, updated_at=? WHERE id=?",
                             (*args, utcnow(), source_id)).rowcount
            if n == 0:
                raise NotFound(f"source {source_id}")
            audit(conn, "user", "knowledge.update_source", source_id=source_id, fields=sorted(patch))
        return self.get_source(source_id)

    def delete_source(self, source_id: int) -> None:
        with self.db.session() as conn:
            row = conn.execute("SELECT stored_path, sha256 FROM knowledge_sources WHERE id=?",
                               (source_id,)).fetchone()
            if row is None:
                raise NotFound(f"source {source_id}")
            conn.execute("DELETE FROM knowledge_sources WHERE id=?", (source_id,))
            audit(conn, "user", "knowledge.delete_source", source_id=source_id)
        if row["stored_path"]:
            (self.files_dir / row["stored_path"]).unlink(missing_ok=True)

    def file_path(self, source_id: int) -> Path:
        src = self.get_source(source_id)
        if not src.get("stored_path"):
            raise NotFound("source has no stored file")
        return self.files_dir / src["stored_path"]

    # ------------------------------------------------------------ items
    def list_items(self, status: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        sql, args = "SELECT * FROM knowledge_items", []
        if status:
            sql += " WHERE status=?"
            args.append(status)
        sql += " ORDER BY id DESC LIMIT ?"
        args.append(limit)
        with self.db.session() as conn:
            return [row_to_dict(r) for r in conn.execute(sql, args).fetchall()]

    def update_item(self, item_id: int, patch: dict[str, Any]) -> dict[str, Any]:
        allowed = {"title", "content", "category", "tags", "item_type"}
        bad = set(patch) - allowed
        if bad:
            raise ValueError(f"cannot update fields: {sorted(bad)}")
        if "item_type" in patch and patch["item_type"] not in ITEM_TYPES:
            raise ValueError(f"item_type must be one of {ITEM_TYPES}")
        sets, args = [], []
        for k, v in patch.items():
            if k == "tags":
                sets.append("tags_json=?")
                args.append(json.dumps(v or [], ensure_ascii=False))
            else:
                sets.append(f"{k}=?")
                args.append(v)
        # Any edit of content sends an approved item back to review: the user must
        # re-approve what the engine will use.
        if {"content", "item_type"} & set(patch):
            sets.append("status='pending_review'")
            sets.append("decided_at=NULL")
        with self.db.session() as conn:
            n = conn.execute(f"UPDATE knowledge_items SET {', '.join(sets)}, updated_at=? WHERE id=?",
                             (*args, utcnow(), item_id)).rowcount if sets else 1
            if n == 0:
                raise NotFound(f"item {item_id}")
            audit(conn, "user", "knowledge.update_item", item_id=item_id, fields=sorted(patch))
            row = conn.execute("SELECT * FROM knowledge_items WHERE id=?", (item_id,)).fetchone()
        if row is None:
            raise NotFound(f"item {item_id}")
        return row_to_dict(row)

    def decide_item(self, item_id: int, decision: str) -> dict[str, Any]:
        """User approval gate. ``decision`` is 'approve' or 'reject'."""
        status = {"approve": "approved", "reject": "rejected"}.get(decision)
        if status is None:
            raise ValueError("decision must be 'approve' or 'reject'")
        with self.db.session() as conn:
            n = conn.execute(
                "UPDATE knowledge_items SET status=?, decided_at=?, updated_at=? WHERE id=?",
                (status, utcnow(), utcnow(), item_id)).rowcount
            if n == 0:
                raise NotFound(f"item {item_id}")
            audit(conn, "user", f"knowledge.{decision}", item_id=item_id)
            row = conn.execute("SELECT * FROM knowledge_items WHERE id=?", (item_id,)).fetchone()
        return row_to_dict(row)

    def link_items(self, from_id: int, to_id: int, relation: str) -> None:
        with self.db.session() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO knowledge_links(from_item_id,to_item_id,relation,created_at) "
                "VALUES (?,?,?,?)", (from_id, to_id, relation, utcnow()))
            audit(conn, "user", "knowledge.link", from_id=from_id, to_id=to_id, relation=relation)

    def search(self, query: str, approved_only: bool = False, limit: int = 20) -> list[dict[str, Any]]:
        """Keyword search (FTS5/BM25). Vector search is added in Phase 5."""
        q = fts_query(query)
        if q is None:
            return []
        sql = ("SELECT i.*, s.title AS source_title, s.kind AS source_kind, bm25(knowledge_items_fts) AS score, "
               "snippet(knowledge_items_fts, 1, '[', ']', '…', 12) AS snippet "
               "FROM knowledge_items_fts JOIN knowledge_items i ON i.id = knowledge_items_fts.rowid "
               "LEFT JOIN knowledge_sources s ON s.id = i.source_id WHERE knowledge_items_fts MATCH ?")
        if approved_only:
            sql += " AND i.status='approved'"
        sql += " ORDER BY score LIMIT ?"
        with self.db.session() as conn:
            return [row_to_dict(r) for r in conn.execute(sql, (q, limit)).fetchall()]

    @staticmethod
    def _public_source(d: dict[str, Any] | None) -> dict[str, Any]:
        assert d is not None
        text = d.pop("extracted_text", None)
        d["extracted_chars"] = len(text) if text else 0
        return d
