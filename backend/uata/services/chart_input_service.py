"""Chart images submitted for analysis.

Receive an image from any allowed input path (file upload, Android/iOS share
sheet, a screenshot), verify that it really is a decodable image, store it
locally, and read the chart with :class:`uata.vision.reader.ChartReader`
(Phase 3): candles, quality, price axis when legible, timeframe label.

The recommendation stays WAIT until the signal engine exists (Phase 8):
``reason_code`` is ``image_quality_insufficient`` when the reader abstains,
otherwise ``signal_engine_not_installed``. No signal is invented and nothing is
written to the signal log.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, BinaryIO

import cv2
import numpy as np

from uata.db.database import Database, audit, row_to_dict, utcnow
from uata.analysis.engine import analyze_reading
from uata.vision.reader import ChartReader, annotate

INPUT_MODES = ("upload", "share", "screenshot", "screen_region")
# Automatic capture modes read the screen; they need the user's permission.
# "share" and "upload" are explicit user actions on a single image.
SCREEN_MODES = {"screenshot", "screen_region"}
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MIN_SIDE = 64
MAX_KEEP = 500  # oldest inputs beyond this are deleted automatically


class InvalidImage(ValueError):
    pass


class ChartInputService:
    def __init__(self, db: Database, files_dir: Path, reader: ChartReader | None = None):
        self.db = db
        self.files_dir = Path(files_dir)
        self.reader = reader or ChartReader()

    def submit(self, stream: BinaryIO, filename: str | None, input_mode: str,
               screen_capture_allowed: bool, session_id: int | None = None,
               min_quality: float | None = None, enabled: dict[str, bool] | None = None) -> dict[str, Any]:
        self._check_mode(input_mode, screen_capture_allowed)
        data = stream.read(MAX_IMAGE_BYTES + 1)
        if not data:
            raise InvalidImage("empty file")
        if len(data) > MAX_IMAGE_BYTES:
            raise InvalidImage("image too large (max 25 MB)")
        img = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            raise InvalidImage("file is not a readable image")
        return self.submit_image(img, filename, input_mode, screen_capture_allowed, session_id,
                                 min_quality, size_bytes=len(data), enabled=enabled)

    @staticmethod
    def _check_mode(input_mode: str, screen_capture_allowed: bool) -> None:
        if input_mode not in INPUT_MODES:
            raise ValueError(f"input_mode must be one of {INPUT_MODES}")
        if input_mode in SCREEN_MODES and not screen_capture_allowed:
            raise PermissionError("screen capture permission has not been granted by the user")

    def read_only(self, img: np.ndarray, min_quality: float | None = None,
                  enabled: dict[str, bool] | None = None) -> dict[str, Any]:
        """Read + analyse a chart without storing anything (continuous screen reading)."""
        reading = self._reader(min_quality).read(img).to_dict()
        reading["technical"] = analyze_reading(reading, enabled)
        return reading

    def _reader(self, min_quality: float | None) -> ChartReader:
        if min_quality is None or min_quality == self.reader.min_quality:
            return self.reader
        return ChartReader(min_quality=min_quality, use_ocr=self.reader.use_ocr)

    def submit_image(self, img: np.ndarray, filename: str | None, input_mode: str, screen_capture_allowed: bool,
                     session_id: int | None = None, min_quality: float | None = None,
                     size_bytes: int | None = None, enabled: dict[str, bool] | None = None) -> dict[str, Any]:
        self._check_mode(input_mode, screen_capture_allowed)
        height, width = img.shape[:2]
        if min(width, height) < MIN_SIDE:
            raise InvalidImage(f"image too small to analyse ({width}x{height})")

        # normalise to PNG (lossless) so every later step reads one format
        ok, png = cv2.imencode(".png", img)
        if not ok:
            raise InvalidImage("could not store image")
        png_bytes = png.tobytes()
        digest = hashlib.sha256(png_bytes).hexdigest()
        rel = f"inputs/{digest[:2]}/{digest}.png"
        dest = self.files_dir / rel
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix(".part")
            tmp.write_bytes(png_bytes)
            tmp.replace(dest)

        reading = self._reader(min_quality).read(img).to_dict()
        reading["technical"] = analyze_reading(reading, enabled)  # Phase 4: closed candles only

        with self.db.session() as conn:
            iid = conn.execute(
                "INSERT INTO analysis_inputs(session_id,input_mode,original_name,sha256,stored_path,width,height,"
                "size_bytes,created_at,reading_json,data_quality,usable) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                (session_id, input_mode, Path(filename).name if filename else None, digest, rel,
                 width, height, size_bytes or len(png_bytes), utcnow(), json.dumps(reading),
                 reading["data_quality"], int(reading["usable"]))).lastrowid
            audit(conn, "user", "analysis.input", input_id=iid, mode=input_mode, width=width, height=height,
                  usable=reading["usable"], candles=len(reading["candles"]))
            row = row_to_dict(conn.execute("SELECT * FROM analysis_inputs WHERE id=?", (iid,)).fetchone())
        row.pop("reading", None)  # full reading has its own endpoint
        self._enforce_retention()
        return {"input": row, "analysis": analysis_from_reading(reading, width, height)}

    def reading(self, input_id: int) -> dict[str, Any]:
        with self.db.session() as conn:
            row = conn.execute("SELECT reading_json FROM analysis_inputs WHERE id=?", (input_id,)).fetchone()
        if row is None:
            raise KeyError(input_id)
        return json.loads(row[0]) if row[0] else {}

    def annotated_png(self, input_id: int) -> bytes:
        img = cv2.imread(str(self.image_path(input_id)), cv2.IMREAD_COLOR)
        ok, buf = cv2.imencode(".png", annotate(img, self.reading(input_id)))
        return buf.tobytes()

    def list(self, limit: int = 50) -> list[dict[str, Any]]:
        with self.db.session() as conn:
            rows = conn.execute("SELECT * FROM analysis_inputs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        out = []
        for r in rows:
            d = row_to_dict(r)
            reading = d.pop("reading", None) or {}
            d["summary"] = reading.get("summary")
            out.append(d)
        return out

    def image_path(self, input_id: int) -> Path:
        with self.db.session() as conn:
            row = conn.execute("SELECT stored_path FROM analysis_inputs WHERE id=?", (input_id,)).fetchone()
        if row is None:
            raise KeyError(input_id)
        return self.files_dir / row["stored_path"]

    def delete(self, input_id: int) -> bool:
        with self.db.session() as conn:
            row = conn.execute("SELECT stored_path FROM analysis_inputs WHERE id=?", (input_id,)).fetchone()
            if row is None:
                return False
            conn.execute("DELETE FROM analysis_inputs WHERE id=?", (input_id,))
            still_used = conn.execute("SELECT 1 FROM analysis_inputs WHERE stored_path=?",
                                      (row["stored_path"],)).fetchone()
            audit(conn, "user", "analysis.input_delete", input_id=input_id)
        if not still_used:
            (self.files_dir / row["stored_path"]).unlink(missing_ok=True)
        return True

    def _enforce_retention(self) -> None:
        with self.db.session() as conn:
            old = conn.execute("SELECT id FROM analysis_inputs ORDER BY id DESC LIMIT -1 OFFSET ?",
                               (MAX_KEEP,)).fetchall()
        for r in old:
            self.delete(r["id"])


def analysis_from_reading(reading: dict, width: int, height: int) -> dict[str, Any]:
    """The recommendation for one image. WAIT until the signal engine (Phase 8) exists."""
    return {
        "signal": "WAIT",
        "reason_code": "signal_engine_not_installed" if reading["usable"] else "image_quality_insufficient",
        "data_basis": "image_only",
        "confidence": None,
        "confidence_calibrated": False,
        "duration_sec": None,
        "data_quality": reading["data_quality"],
        "image": {"width": width, "height": height},
        "reading": reading["summary"],
        "technical": technical_summary(reading.get("technical")),
    }


def technical_summary(t: dict | None) -> dict | None:
    """Compact view of the technical analysis for the panel / result dialog."""
    if not t:
        return None
    if not t.get("available"):
        return {"available": False, "reason": t.get("reason"), "candles_used": t.get("candles_used")}
    active = [f for f in t["factors"] if f["enabled"] and f["available"]]
    return {
        "available": True,
        "units": t.get("units"),
        "candles_used": t["candles_used"],
        "market_condition": t["market_condition"],
        "trend": t["trend"],
        "supporting_bullish": [{"name": f["name"], "code": f["code"], "strength": f["strength"], "params": f["params"]}
                               for f in active if f["direction"] == "bullish"],
        "supporting_bearish": [{"name": f["name"], "code": f["code"], "strength": f["strength"], "params": f["params"]}
                               for f in active if f["direction"] == "bearish"],
        "neutral": [f["name"] for f in active if f["direction"] == "neutral"],
        "disabled": t["confluence"]["disabled"],
        "unavailable": t["confluence"]["unavailable"],
        "bullish_score": t["confluence"]["bullish_score"],
        "bearish_score": t["confluence"]["bearish_score"],
        "levels": t["levels"],
        "patterns": [p["name"] for p in t["patterns"]],
        "warnings": t["warnings"],
    }
