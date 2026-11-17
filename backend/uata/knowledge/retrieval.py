"""Local hybrid retrieval: FTS5/BM25 keywords + local vectors, fused with RRF.

Embedder: deterministic *feature hashing* of normalised words, word bigrams,
character 3-grams and glossary concepts (Arabic ↔ English). It needs no model
download, works offline on every device, and handles Arabic morphology
reasonably via character n-grams. It is lexical-semantic, not a neural model;
the ``Embedder`` interface allows plugging a local neural model later without
touching callers (vectors are stored with the model name and re-built on change).
"""

from __future__ import annotations

import hashlib
import math
import re
import sqlite3
from collections import Counter
from typing import Protocol

import numpy as np

from uata.knowledge.textnorm import concepts, normalize, surface_forms


class Embedder(Protocol):
    name: str
    dim: int

    def embed(self, text: str) -> np.ndarray: ...


class HashingEmbedder:
    name = "hashing-v1"

    def __init__(self, dim: int = 2048):
        self.dim = dim

    def _idx(self, feat: str) -> tuple[int, float]:
        h = int.from_bytes(hashlib.blake2b(feat.encode(), digest_size=8).digest(), "little")
        return h % self.dim, (1.0 if (h >> 63) & 1 else -1.0)

    def features(self, text: str) -> Counter:
        t = normalize(text)
        words = re.findall(r"\w+", t, flags=re.UNICODE)
        f: Counter = Counter()
        for w in words:
            f["w:" + w] += 1.0
            core = re.sub(r"^(وال|بال|فال|كال|لل|ال)", "", w) if re.search(r"[؀-ۿ]", w) else w
            if core != w:
                f["w:" + core] += 1.0
            padded = f"#{core}#"
            for i in range(len(padded) - 2):
                f["c:" + padded[i:i + 3]] += 0.35
        for a, b in zip(words, words[1:]):
            f["b:" + a + "_" + b] += 0.7
        for c in concepts(text):
            f["k:" + c] += 2.0  # bilingual concept bridge
        return f

    def embed(self, text: str) -> np.ndarray:
        v = np.zeros(self.dim, dtype=np.float32)
        for feat, tf in self.features(text).items():
            i, sign = self._idx(feat)
            v[i] += sign * (1.0 + math.log(tf)) if tf >= 1 else sign * tf
        n = np.linalg.norm(v)
        return v / n if n > 0 else v


def expand_query(query: str) -> str:
    """Add the other-language surface forms of every concept in the query."""
    extra = []
    for c in concepts(query):
        extra.extend(surface_forms(c)[:3])
    return query + (" " + " ".join(extra) if extra else "")


def fts_query(text: str) -> str | None:
    tokens = re.findall(r"\w+", text, flags=re.UNICODE)
    if not tokens:
        return None
    # OR of prefix terms: recall-oriented; ranking is done by BM25 + fusion
    return " OR ".join(f'"{t}"*' for t in dict.fromkeys(tokens[:24]))


class Retriever:
    def __init__(self, embedder: Embedder | None = None):
        self.embedder = embedder or HashingEmbedder()

    # ------------------------------------------------------------ index maintenance
    def index_item(self, conn: sqlite3.Connection, item_id: int, text: str, now: str) -> None:
        v = self.embedder.embed(text)
        conn.execute(
            "INSERT INTO knowledge_embeddings(item_id, model, dim, vector, created_at) VALUES (?,?,?,?,?) "
            "ON CONFLICT(item_id) DO UPDATE SET model=excluded.model, dim=excluded.dim, vector=excluded.vector, "
            "created_at=excluded.created_at", (item_id, self.embedder.name, self.embedder.dim, v.tobytes(), now))

    def reindex_missing(self, conn: sqlite3.Connection, now: str) -> int:
        rows = conn.execute(
            "SELECT i.id, i.title, i.content FROM knowledge_items i LEFT JOIN knowledge_embeddings e "
            "ON e.item_id=i.id WHERE e.item_id IS NULL OR e.model<>?", (self.embedder.name,)).fetchall()
        for r in rows:
            self.index_item(conn, r["id"], f"{r['title']}\n{r['content']}", now)
        return len(rows)

    # ------------------------------------------------------------ search
    def search(self, conn: sqlite3.Connection, query: str, approved_only: bool = True, k: int = 8,
               rrf_k: int = 60) -> list[dict]:
        q = expand_query(query)
        status_sql = " AND i.status='approved'" if approved_only else " AND i.status IN ('approved','pending_review')"
        ranks: dict[int, dict] = {}

        fq = fts_query(normalize(q) + " " + q)
        if fq:
            rows = conn.execute(
                "SELECT i.id FROM knowledge_items_fts f JOIN knowledge_items i ON i.id=f.rowid "
                f"WHERE knowledge_items_fts MATCH ?{status_sql} ORDER BY bm25(knowledge_items_fts) LIMIT 50",
                (fq,)).fetchall()
            for rank, r in enumerate(rows):
                ranks.setdefault(r["id"], {})["kw"] = rank

        qv = self.embedder.embed(q)
        rows = conn.execute(
            "SELECT e.item_id, e.vector FROM knowledge_embeddings e JOIN knowledge_items i ON i.id=e.item_id "
            f"WHERE e.model=?{status_sql}", (self.embedder.name,)).fetchall()
        if rows:
            mat = np.frombuffer(b"".join(r["vector"] for r in rows), dtype=np.float32).reshape(len(rows), -1)
            sims = mat @ qv
            order = np.argsort(-sims)[:50]
            for rank, j in enumerate(order):
                if sims[j] <= 0.05:
                    break
                ranks.setdefault(rows[j]["item_id"], {})["vec"] = rank
                ranks[rows[j]["item_id"]]["sim"] = float(sims[j])

        scored = sorted(((sum(1.0 / (rrf_k + r) for key, r in v.items() if key in ("kw", "vec")), iid, v)
                         for iid, v in ranks.items()), reverse=True)[:k]
        if not scored:
            return []
        ids = [iid for _, iid, _ in scored]
        meta = {r["id"]: r for r in conn.execute(
            "SELECT i.id, i.title, i.content, i.status, i.item_type, i.location, i.source_id, "
            "s.title AS source_title, s.kind AS source_kind FROM knowledge_items i "
            f"LEFT JOIN knowledge_sources s ON s.id=i.source_id WHERE i.id IN ({','.join('?' * len(ids))})",
            ids).fetchall()}
        out = []
        for score, iid, v in scored:
            m = meta[iid]
            out.append({"item_id": iid, "title": m["title"], "snippet": m["content"][:300],
                        "status": m["status"], "item_type": m["item_type"], "location": m["location"],
                        "source_id": m["source_id"], "source_title": m["source_title"],
                        "source_kind": m["source_kind"], "score": round(score, 5),
                        "matched_by": sorted(k_ for k_ in ("kw", "vec") if k_ in v),
                        "similarity": round(v.get("sim", 0.0), 3)})
        return out
