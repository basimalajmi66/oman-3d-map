"""Timestamped speech transcripts: subtitle files and (optional) local speech-to-text.

Sources, in order of preference:
1. A subtitle file the user provides (.srt / .vtt) — exact timestamps, no model needed.
2. Local speech-to-text with faster-whisper **if** a model is available on this
   device (``UATA_WHISPER_MODEL`` = path to a local CTranslate2 Whisper model, or
   the ``stt_model_path`` setting). Nothing is downloaded automatically and no
   audio leaves the device.
3. Otherwise: no transcript, reported explicitly (``transcript_source = none``).
"""

from __future__ import annotations

import os
import re
import subprocess  # nosec B404 - fixed ffmpeg argv, never a shell
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class Segment:
    start_ms: int
    end_ms: int
    text: str
    confidence: float | None = None   # 0..1 when the source provides it

    def to_dict(self) -> dict:
        return asdict(self)


_TS = re.compile(r"(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})")


def _ms(ts: str) -> int:
    m = _TS.search(ts)
    if not m:
        raise ValueError(f"bad timestamp: {ts}")
    h = int(m.group(1) or 0)
    return ((h * 60 + int(m.group(2))) * 60 + int(m.group(3))) * 1000 + int(m.group(4).ljust(3, "0"))


def parse_subtitles(text: str) -> list[Segment]:
    """Parse SRT or WebVTT. Tags (<i>, {\\an8}) are stripped; empty cues dropped."""
    text = text.replace("\r\n", "\n").replace("﻿", "")
    out: list[Segment] = []
    for block in re.split(r"\n\s*\n", text):
        lines = [l_ for l_ in block.strip().split("\n") if l_.strip()]
        idx = next((i for i, l_ in enumerate(lines) if "-->" in l_), None)
        if idx is None:
            continue
        start, end = [p.strip() for p in lines[idx].split("-->")[:2]]
        body = " ".join(lines[idx + 1:])
        body = re.sub(r"<[^>]+>|\{[^}]+\}", "", body).strip()
        if body:
            out.append(Segment(_ms(start), _ms(end.split(" ")[0]), body))
    if not out:
        raise ValueError("no subtitle cues found (expected SRT or WebVTT)")
    return sorted(out, key=lambda s: s.start_ms)


def ffmpeg_exe() -> str | None:
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        from shutil import which
        return which("ffmpeg")


def extract_audio(video: Path, out_wav: Path) -> bool:
    """16 kHz mono WAV for speech-to-text. Returns False if the video has no audio."""
    exe = ffmpeg_exe()
    if exe is None:
        raise RuntimeError("ffmpeg is not available")
    r = subprocess.run([exe, "-y", "-v", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", "16000",  # nosec B603
                        "-f", "wav", str(out_wav)], capture_output=True, text=True, timeout=3600)
    return r.returncode == 0 and out_wav.exists() and out_wav.stat().st_size > 1000


class SpeechToText:
    """Interface. ``available`` is False when no local model exists."""
    name = "none"
    available = False

    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]:
        raise NotImplementedError


class FasterWhisperSTT(SpeechToText):
    name = "faster-whisper"

    def __init__(self, model_path: str | None = None):
        self.model_path = model_path or os.environ.get("UATA_WHISPER_MODEL")
        self._model = None
        try:
            import faster_whisper  # noqa: F401
            self.available = bool(self.model_path) and Path(self.model_path).is_dir()
        except ImportError:
            self.available = False

    def transcribe(self, wav: Path, language: str | None = None) -> list[Segment]:
        import math

        from faster_whisper import WhisperModel
        if self._model is None:
            # local_files_only: never download anything
            self._model = WhisperModel(self.model_path, device="cpu", compute_type="int8", local_files_only=True)
        segments, _ = self._model.transcribe(str(wav), language=language, vad_filter=True)
        out = []
        for s in segments:
            conf = math.exp(s.avg_logprob) if s.avg_logprob is not None else None
            out.append(Segment(int(s.start * 1000), int(s.end * 1000), s.text.strip(),
                               round(min(1.0, conf), 3) if conf is not None else None))
        return out


def transcribe_video(video: Path, stt: SpeechToText) -> tuple[list[Segment], str | None]:
    """Run STT if available. Returns (segments, error)."""
    if not stt.available:
        return [], "speech_to_text_model_not_installed"
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "audio.wav"
        if not extract_audio(video, wav):
            return [], "video_has_no_audio"
        return stt.transcribe(wav), None
