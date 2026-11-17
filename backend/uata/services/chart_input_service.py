"""Chart images submitted for analysis.

Phase 2 scope: receive an image from any allowed input path (file upload,
Android/iOS share sheet, a screenshot the user took), verify that it really is a
decodable image, store it locally and register it. The image is read with
OpenCV so the reported dimensions are real.

Chart reading itself is Phase 3. Until then the analysis result is always WAIT
with ``reason_code = analysis_engine_not_installed`` and ``data_basis =
image_only`` — no signal is invented and nothing is written to the signal log
(an "engine missing" WAIT is not an analysis and would distort the statistics).
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any, BinaryIO

import cv2
import numpy as np

from uata.db.database import Database, audit, row_to_dict, utcnow

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
    def __init__(self, db: Database, files_dir: Path):
        self.db = db
        self.files_dir = Path(files_dir)

    def submit(self, stream: BinaryIO, filename: str | None, input_mode: str,
               screen_capture_allowed: bool, session_id: int | None = None) -> dict[str, Any]:
        if input_mode not in INPUT_MODES:
            raise ValueError(f"input_mode must be one of {INPUT_MODES}")
        if input_mode in SCREEN_MODES and not screen_capture_allowed:
            raise PermissionError("screen capture permission has not been granted by the user")

        data = stream.read(MAX_IMAGE_BYTES + 1)
        if not data:
            raise InvalidImage("empty file")
        if len(data) > MAX_IMAGE_BYTES:
            raise InvalidImage("image too large (max 25 MB)")
        img = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            raise InvalidImage("file is not a readable image")
        height, width = img.shape[:2]
        if min(width, height) < MIN_SIDE:
            raise InvalidImage(f"image too small to analyse ({width}x{height})")

        digest = hashlib.sha256(data).hexdigest()
        rel = f"inputs/{digest[:2]}/{digest}.png"
        dest = self.files_dir / rel
        if not dest.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            # normalise to PNG (lossless) so later phases read one format
            ok, png = cv2.imencode(".png", img)
            if not ok:
                raise InvalidImage("could not store image")
            tmp = dest.with_suffix(".part")
            tmp.write_bytes(png.tobytes())
            tmp.replace(dest)

        with self.db.session() as conn:
            iid = conn.execute(
                "INSERT INTO analysis_inputs(session_id,input_mode,original_name,sha256,stored_path,width,height,"
                "size_bytes,created_at) VALUES (?,?,?,?,?,?,?,?,?)",
                (session_id, input_mode, Path(filename).name if filename else None, digest, rel,
                 width, height, len(data), utcnow())).lastrowid
            audit(conn, "user", "analysis.input", input_id=iid, mode=input_mode, width=width, height=height)
            row = row_to_dict(conn.execute("SELECT * FROM analysis_inputs WHERE id=?", (iid,)).fetchone())
        self._enforce_retention()
        return {
            "input": row,
            "analysis": {
                "signal": "WAIT",
                "reason_code": "analysis_engine_not_installed",
                "data_basis": "image_only",
                "confidence": None,
                "confidence_calibrated": False,
                "duration_sec": None,
                "image": {"width": width, "height": height},
            },
        }

    def list(self, limit: int = 50) -> list[dict[str, Any]]:
        with self.db.session() as conn:
            rows = conn.execute("SELECT * FROM analysis_inputs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [row_to_dict(r) for r in rows]

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
