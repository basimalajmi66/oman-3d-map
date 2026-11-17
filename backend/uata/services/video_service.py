"""Educational-video jobs: analysis in the background, results into the knowledge library.

Every extracted piece keeps its exact time in the video (``video_timestamp_ms``)
and a clarity score. Rules become pending items, a *draft* strategy is created,
and a learning report waits for the user. Nothing is approved automatically.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any, Callable

from uata.db.database import Database, audit, row_to_dict, utcnow
from uata.knowledge.rules import CandidateRule, conflicts
from uata.video.analyzer import VideoAnalyzer, fmt_ts
from uata.video.transcript import FasterWhisperSTT, SpeechToText, parse_subtitles, transcribe_video

SPEECH_CHUNK_MS = 60_000  # group speech into ~1 minute knowledge items


class VideoService:
    def __init__(self, db: Database, files_dir: Path, knowledge, stt_factory: Callable[[], SpeechToText] | None = None,
                 analyzer: VideoAnalyzer | None = None):
        self.db = db
        self.files_dir = Path(files_dir)
        self.knowledge = knowledge
        self.stt_factory = stt_factory or (lambda: FasterWhisperSTT())
        self.analyzer = analyzer or VideoAnalyzer()
        # one worker processes jobs in order: no two analyses of the same (or any) video run at once
        self._cond = threading.Condition()
        self._queue: list[int] = []
        self._running: int | None = None
        self._worker: threading.Thread | None = None

    # ------------------------------------------------------------ jobs
    def enqueue(self, source_id: int, sync: bool = False, subtitles: str | None = None) -> None:
        """Queue (re-)analysis. Subtitles, if given, are stored *before* the job starts."""
        now = utcnow()
        if subtitles is not None:
            parse_subtitles(subtitles)
        with self.db.session() as conn:
            conn.execute(
                "INSERT INTO video_analyses(source_id,status,progress,created_at,updated_at) VALUES (?,?,0,?,?) "
                "ON CONFLICT(source_id) DO UPDATE SET status='queued', progress=0, error=NULL, updated_at=excluded.updated_at",
                (source_id, "queued", now, now))
            if subtitles is not None:
                conn.execute("UPDATE video_analyses SET subtitles_text=? WHERE source_id=?", (subtitles, source_id))
                audit(conn, "user", "video.subtitles", source_id=source_id)
            conn.execute("UPDATE knowledge_sources SET extraction_status='pending' WHERE id=?", (source_id,))
        if sync:
            self._run(source_id)
            return
        with self._cond:
            if source_id not in self._queue:  # a request during a running job re-runs it afterwards
                self._queue.append(source_id)
            if self._worker is None or not self._worker.is_alive():
                self._worker = threading.Thread(target=self._work, name="uata-video-worker", daemon=True)
                self._worker.start()
            self._cond.notify_all()

    def _work(self) -> None:
        while True:
            with self._cond:
                while not self._queue:
                    if not self._cond.wait(timeout=30):
                        self._worker = None  # idle: let the thread end; enqueue starts a new one
                        return
                self._running = self._queue.pop(0)
            try:
                self._run(self._running)
            finally:
                with self._cond:
                    self._running = None
                    self._cond.notify_all()

    def wait(self, source_id: int, timeout: float = 120) -> bool:
        """Block until the source has no queued or running job. Returns False on timeout."""
        with self._cond:
            return self._cond.wait_for(lambda: source_id not in self._queue and self._running != source_id, timeout)

    def set_subtitles(self, source_id: int, text: str) -> None:
        parse_subtitles(text)  # validate before storing
        with self.db.session() as conn:
            n = conn.execute("UPDATE video_analyses SET subtitles_text=?, updated_at=? WHERE source_id=?",
                             (text, utcnow(), source_id)).rowcount
            if n == 0:
                raise KeyError(source_id)
            audit(conn, "user", "video.subtitles", source_id=source_id)

    def _progress(self, source_id: int, value: float) -> None:
        with self.db.session() as conn:
            conn.execute("UPDATE video_analyses SET progress=?, updated_at=? WHERE source_id=?",
                         (round(value, 3), utcnow(), source_id))

    def _run(self, source_id: int) -> None:
        try:
            with self.db.session() as conn:
                src = conn.execute("SELECT stored_path, title FROM knowledge_sources WHERE id=?", (source_id,)).fetchone()
                va = conn.execute("SELECT subtitles_text FROM video_analyses WHERE source_id=?", (source_id,)).fetchone()
                conn.execute("UPDATE video_analyses SET status='processing', updated_at=? WHERE source_id=?",
                             (utcnow(), source_id))
            if src is None:
                return
            path = self.files_dir / src["stored_path"]
            segments, source, note = [], "none", None
            if va and va["subtitles_text"]:
                segments, source = parse_subtitles(va["subtitles_text"]), "subtitles"
            else:
                segments, note = transcribe_video(path, self.stt_factory())
                source = "speech_to_text" if segments else "none"
            analysis = self.analyzer.analyze(path, segments, source, note,
                                             progress=lambda v: self._progress(source_id, v))
            self._store(source_id, src["title"], analysis.to_dict())
        except Exception as e:  # report, never crash the engine or leave the job "processing"
            try:
                with self.db.session() as conn:
                    conn.execute("UPDATE video_analyses SET status='failed', error=?, updated_at=? WHERE source_id=?",
                                 (str(e), utcnow(), source_id))
                    conn.execute("UPDATE knowledge_sources SET extraction_status='failed', notes=? WHERE id=?",
                                 (f"video analysis: {e}", source_id))
                    audit(conn, "system", "video.failed", source_id=source_id, error=str(e))
            except Exception:  # nosec B110 - the source may have been deleted meanwhile; nothing left to update
                pass

    # ------------------------------------------------------------ results → library
    def _store(self, sid: int, title: str, a: dict) -> None:
        now = utcnow()
        retr = self.knowledge.retriever
        with self.db.session() as conn:
            # re-analysis replaces what is not approved yet; approved knowledge is kept
            conn.execute("DELETE FROM knowledge_items WHERE source_id=? AND status<>'approved'", (sid,))
            old = conn.execute("SELECT strategy_id FROM video_analyses WHERE source_id=?", (sid,)).fetchone()
            if old and old["strategy_id"]:
                conn.execute("DELETE FROM strategies WHERE id=? AND status='draft'", (old["strategy_id"],))

            item_ids = []

            def add(item_type, ttl, content, start_ms, clarity, rule_json=None):
                iid = conn.execute(
                    "INSERT INTO knowledge_items(source_id,item_type,title,content,location,video_timestamp_ms,"
                    "clarity,rule_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                    (sid, item_type, ttl, content, fmt_ts(start_ms), start_ms, clarity,
                     json.dumps(rule_json, ensure_ascii=False) if rule_json else None, now, now)).lastrowid
                retr.index_item(conn, iid, f"{ttl}\n{content}", now)
                item_ids.append(iid)
                return iid

            # speech grouped per ~minute, on-screen text per scene
            group: list[dict] = []
            for t in [x for x in a["timeline"] if x["kind"] == "speech"] + [None]:
                if t is None or (group and t["start_ms"] - group[0]["start_ms"] >= SPEECH_CHUNK_MS):
                    if group:
                        confs = [g["clarity"] for g in group if g["clarity"] is not None]
                        add("note", f"{title} — {fmt_ts(group[0]['start_ms'])}", " ".join(g["text"] for g in group),
                            group[0]["start_ms"], round(sum(confs) / len(confs), 3) if confs else None)
                    group = []
                if t is not None:
                    group.append(t)
            for t in a["timeline"]:
                if t["kind"] == "screen_text":
                    add("note", f"{title} — {t['time']} (screen)", t["text"], t["start_ms"], t["clarity"])
            for c in a["charts"]:
                desc = (f"Chart at {c['time']}: {c['candles']} candles, trend {c['trend'] or 'n/a'}, "
                        f"market {c['market_condition'] or 'n/a'}"
                        + (f", patterns: {', '.join(c['patterns'])}" if c["patterns"] else "")
                        + (f", factors: {', '.join(f'{k}={v}' for k, v in c['factors'].items())}" if c["factors"] else ""))
                add("example", f"{title} — chart {c['time']}", desc, c["start_ms"], c["data_quality"])

            approved = [{"item_id": r["id"], "text": r["content"], **json.loads(r["rule_json"])}
                        for r in conn.execute("SELECT id, content, rule_json FROM knowledge_items "
                                              "WHERE status='approved' AND rule_json IS NOT NULL").fetchall()]
            found_conflicts, rule_entries = [], []
            for r in a["rules"]:
                rule = {"actions": r["actions"], "conditions": r["conditions"], "timeframes": r["timeframes"]}
                iid = add("rule", f"{title} — rule {r['location']}", r["text"], r["start_ms"], r["clarity"], rule)
                cand = CandidateRule(r["text"], r["actions"], r["conditions"], r["timeframes"], r["location"])
                for x in conflicts(cand, approved):
                    x["new_item_id"] = iid
                    found_conflicts.append(x)
                rule_entries.append({"item_id": iid, **r})

            st = a["strategy"]
            strategy_id = conn.execute(
                "INSERT INTO strategies(name,description,source_id,entry_conditions_json,exit_conditions_json,"
                "no_entry_conditions_json,timeframes_json,market_conditions_json,indicators_json,status,created_at,"
                "updated_at) VALUES (?,?,?,?,?,?,?,?,?,'draft',?,?)",
                (f"{title} (video #{sid})", " ".join(s["text"] for s in a["summary"])[:2000], sid,
                 json.dumps(st["entry_conditions"], ensure_ascii=False), json.dumps(st["exit_conditions"], ensure_ascii=False),
                 json.dumps(st["no_entry_conditions"], ensure_ascii=False), json.dumps(st["timeframes"], ensure_ascii=False),
                 json.dumps(sorted({c["trend"] for c in a["charts"] if c["trend"]})), json.dumps(st["indicators"]),
                 now, now)).lastrowid

            summary = (f"video {fmt_ts(a['duration_ms'])}, transcript: {a['transcript_source']}, "
                       f"{len(a['timeline'])} timed text(s), {len(a['charts'])} chart scene(s), "
                       f"{len(a['rules'])} candidate rule(s), {len(found_conflicts)} conflict(s) with approved knowledge")
            extracted = {"items": item_ids, "rules": rule_entries, "concepts": a["concepts"],
                         "locations": [t["time"] for t in a["timeline"]][:50], "video": True, "strategy_id": strategy_id}
            conn.execute(
                "INSERT INTO learning_reports(source_id,summary,extracted_json,conflicts_json,status,created_at) "
                "VALUES (?,?,?,?,'pending_review',?)",
                (sid, summary, json.dumps(extracted, ensure_ascii=False), json.dumps(found_conflicts, ensure_ascii=False), now))
            conn.execute("UPDATE video_analyses SET status='done', progress=1, error=NULL, transcript_source=?, "
                         "analysis_json=?, strategy_id=?, updated_at=? WHERE source_id=?",
                         (a["transcript_source"], json.dumps(a, ensure_ascii=False), strategy_id, now, sid))
            conn.execute("UPDATE knowledge_sources SET extraction_status='done', extracted_text=? WHERE id=?",
                         ("\n".join(t["text"] for t in a["timeline"]), sid))
            audit(conn, "system", "video.analysed", source_id=sid, rules=len(a["rules"]), charts=len(a["charts"]))

    # ------------------------------------------------------------ reads
    def list(self) -> list[dict[str, Any]]:
        with self.db.session() as conn:
            rows = conn.execute(
                "SELECT v.source_id, v.status, v.progress, v.error, v.transcript_source, v.updated_at, s.title, "
                "s.size_bytes, (SELECT status FROM learning_reports r WHERE r.source_id=v.source_id ORDER BY id DESC "
                "LIMIT 1) AS report_status FROM video_analyses v JOIN knowledge_sources s ON s.id=v.source_id "
                "ORDER BY v.source_id DESC").fetchall()
        return [row_to_dict(r) for r in rows]

    def page(self, source_id: int) -> dict[str, Any]:
        """Everything the video page shows: name, summary, strategy, rules with time + clarity, status."""
        with self.db.session() as conn:
            v = conn.execute("SELECT v.*, s.title FROM video_analyses v JOIN knowledge_sources s ON s.id=v.source_id "
                             "WHERE v.source_id=?", (source_id,)).fetchone()
            if v is None:
                raise KeyError(source_id)
            items = conn.execute("SELECT id, item_type, content, status, video_timestamp_ms, clarity, location "
                                 "FROM knowledge_items WHERE source_id=? ORDER BY video_timestamp_ms, id",
                                 (source_id,)).fetchall()
            report = conn.execute("SELECT * FROM learning_reports WHERE source_id=? ORDER BY id DESC LIMIT 1",
                                  (source_id,)).fetchone()
            strategy = conn.execute("SELECT * FROM strategies WHERE id=?", (v["strategy_id"],)).fetchone() \
                if v["strategy_id"] else None
        a = json.loads(v["analysis_json"]) if v["analysis_json"] else None
        return {
            "source_id": source_id, "title": v["title"], "status": v["status"], "progress": v["progress"],
            "error": v["error"], "transcript_source": v["transcript_source"],
            "has_subtitles": bool(v["subtitles_text"]),
            "duration_ms": a["duration_ms"] if a else None,
            "summary": a["summary"] if a else [],
            "concepts": a["concepts"] if a else [],
            "charts": a["charts"] if a else [],
            "timeline": a["timeline"] if a else [],
            "warnings": a["warnings"] if a else [],
            "strategy": row_to_dict(strategy) if strategy else None,
            "rules": [row_to_dict(i) for i in items if i["item_type"] == "rule"],
            "items": [row_to_dict(i) for i in items],
            "report": row_to_dict(report) if report else None,
        }
