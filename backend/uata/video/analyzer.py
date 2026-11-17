"""Educational-video analysis (local): frames, on-screen text, charts, speech, rules — all timestamped.

Pipeline
--------
1. Sample frames every ``sample_sec`` with OpenCV; keep a frame when the scene changed
   (colour-histogram distance) or every ``keep_every_sec`` regardless.
2. Each kept frame:
   * the chart reader decides whether it shows a readable candlestick chart; if so the
     technical analyzer describes it (trend, patterns, factors) → an *example* tied to
     the timestamp;
   * otherwise OCR (Arabic + English) reads on-screen text with its confidence.
   Consecutive frames with the same text are merged into one time range.
3. Speech: subtitles (exact) or local STT when a model exists (see ``transcript.py``).
4. All timed texts → rule extraction (entry / no-entry / exit) with the exact time,
   concepts, an extractive summary and a *draft* strategy.

Nothing is approved here: results go to a learning report awaiting the user.
"""

from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

from uata.analysis.engine import analyze_reading
from uata.knowledge.rules import extract_rules
from uata.knowledge.textnorm import concepts, normalize
from uata.video.transcript import Segment
from uata.vision import axis
from uata.vision.reader import ChartReader

ANALYZER_VERSION = "1.0"


def fmt_ts(ms: int) -> str:
    s = ms // 1000
    return f"{s // 3600:d}:{s // 60 % 60:02d}:{s % 60:02d}" if s >= 3600 else f"{s // 60:02d}:{s % 60:02d}"


@dataclass
class TimedText:
    start_ms: int
    end_ms: int
    text: str
    kind: str            # speech | screen_text
    clarity: float | None

    def to_dict(self) -> dict:
        return {"start_ms": self.start_ms, "end_ms": self.end_ms, "time": fmt_ts(self.start_ms), "text": self.text,
                "kind": self.kind, "clarity": self.clarity}


@dataclass
class VideoAnalysis:
    duration_ms: int
    fps: float
    frames_sampled: int
    frames_kept: int
    transcript_source: str           # subtitles | speech_to_text | none
    transcript_note: str | None
    timeline: list[dict] = field(default_factory=list)
    charts: list[dict] = field(default_factory=list)
    rules: list[dict] = field(default_factory=list)
    concepts: list[str] = field(default_factory=list)
    summary: list[dict] = field(default_factory=list)
    strategy: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {**self.__dict__, "analyzer_version": ANALYZER_VERSION}


def _hist(img: np.ndarray) -> np.ndarray:
    small = cv2.resize(img, (160, 90))
    h = cv2.calcHist([cv2.cvtColor(small, cv2.COLOR_BGR2HSV)], [0, 1], None, [16, 8], [0, 180, 0, 256])
    return cv2.normalize(h, h).flatten()


def _thumb(img: np.ndarray) -> np.ndarray:
    return cv2.resize(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), (320, 180), interpolation=cv2.INTER_AREA)


def _content_changed(a: np.ndarray, b: np.ndarray, frac: float = 0.004) -> bool:
    """Detects new text on an otherwise identical slide (colour histograms miss this)."""
    return float((cv2.absdiff(a, b) > 40).mean()) > frac


def _ocr(img: np.ndarray) -> tuple[str, float | None]:
    if not axis.ocr_available():
        return "", None
    t = axis.pytesseract
    langs = t.get_languages(config="")
    lang = "+".join(l_ for l_ in ("ara", "eng") if l_ in langs) or "eng"
    grey = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    if grey.shape[1] < 1000:
        grey = cv2.resize(grey, None, fx=2, fy=2, interpolation=cv2.INTER_CUBIC)
    d = t.image_to_data(grey, lang=lang, output_type=t.Output.DICT, config="--psm 3")
    words, confs = [], []
    line_key, lines = None, []
    for txt, conf, b, p, ln in zip(d["text"], d["conf"], d["block_num"], d["par_num"], d["line_num"]):
        c = float(conf)
        if not txt.strip() or c < 40:
            continue
        key = (b, p, ln)
        if key != line_key:
            if words:
                lines.append(" ".join(words))
            words, line_key = [], key
        words.append(txt.strip())
        confs.append(c)
    if words:
        lines.append(" ".join(words))
    text = "\n".join(l_ for l_ in lines if len(l_) >= 3)
    return text, (round(float(np.mean(confs)) / 100, 3) if confs else None)


def _similar(a: str, b: str) -> bool:
    ta, tb = set(re.findall(r"\w+", normalize(a))), set(re.findall(r"\w+", normalize(b)))
    if not ta or not tb:
        return False
    return len(ta & tb) / len(ta | tb) >= 0.7


class VideoAnalyzer:
    def __init__(self, sample_sec: float = 1.0, keep_every_sec: float = 10.0, scene_threshold: float = 0.25,
                 reader: ChartReader | None = None, max_duration_sec: int = 4 * 3600):
        self.sample_sec = sample_sec
        self.keep_every_sec = keep_every_sec
        self.scene_threshold = scene_threshold
        self.reader = reader or ChartReader(min_quality=0.55)
        self.max_duration_sec = max_duration_sec

    def analyze(self, path: Path, transcript: list[Segment] | None = None, transcript_source: str = "none",
                transcript_note: str | None = None, progress=None) -> VideoAnalysis:
        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            raise ValueError("video could not be opened (unsupported codec or corrupt file)")
        fps = cap.get(cv2.CAP_PROP_FPS) or 0.0
        n_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        if fps <= 0 or n_frames <= 0:
            cap.release()
            raise ValueError("video has no readable frames")
        duration_ms = int(n_frames / fps * 1000)
        if duration_ms > self.max_duration_sec * 1000:
            cap.release()
            raise ValueError("video is longer than the supported maximum (4 h)")

        step = max(1, int(round(fps * self.sample_sec)))
        prev_h, prev_t, last_kept_ms = None, None, -10 ** 9
        sampled = kept = 0
        screen: list[TimedText] = []
        charts: list[dict] = []
        warnings: list[str] = []
        idx = 0
        while True:
            ok = cap.grab()
            if not ok:
                break
            if idx % step == 0:
                ok, frame = cap.retrieve()
                if not ok:
                    break
                t_ms = int(idx / fps * 1000)
                sampled += 1
                h, th = _hist(frame), _thumb(frame)
                changed = (prev_h is None
                           or cv2.compareHist(prev_h, h, cv2.HISTCMP_BHATTACHARYYA) > self.scene_threshold
                           or _content_changed(prev_t, th))
                if changed or t_ms - last_kept_ms >= self.keep_every_sec * 1000:
                    kept += 1
                    last_kept_ms = t_ms
                    self._frame(frame, t_ms, screen, charts)
                else:
                    # unchanged scene: extend the current text/chart range
                    if screen and screen[-1].end_ms >= t_ms - int(self.sample_sec * 1000) - 50:
                        screen[-1].end_ms = t_ms
                    if charts and charts[-1]["end_ms"] >= t_ms - int(self.sample_sec * 1000) - 50:
                        charts[-1]["end_ms"] = t_ms
                prev_h, prev_t = h, th
                if progress:
                    progress(min(0.95, t_ms / max(1, duration_ms)))
            idx += 1
        cap.release()
        if sampled == 0:
            raise ValueError("no frames could be decoded")

        speech = [TimedText(s.start_ms, s.end_ms, s.text, "speech", s.confidence) for s in (transcript or [])]
        timeline = sorted(speech + screen, key=lambda t: (t.start_ms, t.kind))
        if not speech:
            warnings.append(transcript_note or "no_speech_transcript")
        if not axis.ocr_available():
            warnings.append("ocr_not_installed")

        rules, all_concepts = [], Counter()
        for t in timeline:
            all_concepts.update(c for c in concepts(t.text) if not c.startswith("act_"))
            # OCR returns visual lines: a sentence can wrap across them on a slide
            text = t.text.replace("\n", " ") if t.kind == "screen_text" else t.text
            for r in extract_rules(text, fmt_ts(t.start_ms)):
                d = r.to_dict()
                d.update(start_ms=t.start_ms, kind=t.kind, clarity=t.clarity)
                rules.append(d)
        for c in charts:
            all_concepts.update(c.get("concepts", []))

        summary = self._summary(timeline)
        strategy = self._strategy(path.stem, rules, charts, all_concepts)
        return VideoAnalysis(duration_ms, round(fps, 3), sampled, kept, transcript_source, transcript_note,
                             [t.to_dict() for t in timeline], charts, rules,
                             [c for c, _ in all_concepts.most_common()], summary, strategy, warnings)

    # ------------------------------------------------------------ per frame
    def _frame(self, frame: np.ndarray, t_ms: int, screen: list[TimedText], charts: list[dict]) -> None:
        reading = self.reader.read(frame).to_dict()
        if reading["usable"]:
            tech = analyze_reading(reading)
            s = reading["summary"]
            desc = {
                "start_ms": t_ms, "end_ms": t_ms, "time": fmt_ts(t_ms),
                "candles": s["candles"], "data_quality": reading["data_quality"],
                "prices_read": s["prices_read"], "timeframe_label": s["timeframe_label"],
                "trend": tech.get("trend", {}).get("direction") if tech.get("available") else None,
                "market_condition": tech.get("market_condition"),
                "patterns": [p["name"] for p in tech.get("patterns", [])] if tech.get("available") else [],
                "factors": {f["name"]: f["direction"] for f in tech.get("factors", [])
                            if f["direction"] != "neutral"} if tech.get("available") else {},
            }
            desc["concepts"] = [c for c in ({"up": "uptrend", "down": "downtrend"}.get(desc["trend"] or ""),) if c]
            if charts and charts[-1]["end_ms"] >= t_ms - int(self.sample_sec * 1000) - 50 \
                    and charts[-1]["trend"] == desc["trend"] and charts[-1]["patterns"] == desc["patterns"]:
                charts[-1]["end_ms"] = t_ms
            else:
                charts.append(desc)
            return
        text, conf = _ocr(frame)
        if not text:
            return
        if screen and _similar(screen[-1].text, text):
            screen[-1].end_ms = t_ms
            if len(text) > len(screen[-1].text):
                screen[-1].text, screen[-1].clarity = text, conf
        else:
            screen.append(TimedText(t_ms, t_ms, text, "screen_text", conf))

    # ------------------------------------------------------------ synthesis
    @staticmethod
    def _summary(timeline: list[TimedText], n: int = 6) -> list[dict]:
        """Extractive summary: the most concept-dense passages, kept in time order."""
        scored = []
        for t in timeline:
            cs = concepts(t.text)
            if len(t.text) < 15:
                continue
            score = len(cs) * 2 + sum(1 for c in cs if c.startswith("act_")) * 2 + min(len(t.text), 200) / 200
            scored.append((score, t))
        best = sorted(scored, key=lambda x: -x[0])[:n]
        return [{"time": fmt_ts(t.start_ms), "start_ms": t.start_ms, "text": t.text[:300], "kind": t.kind}
                for _, t in sorted(best, key=lambda x: x[1].start_ms)]

    @staticmethod
    def _strategy(name: str, rules: list[dict], charts: list[dict], cs: Counter) -> dict:
        def pick(acts):
            return [{"text": r["text"], "time": r["location"], "start_ms": r["start_ms"], "clarity": r["clarity"]}
                    for r in rules if set(r["actions"]) & acts]
        return {
            "name": name,
            "entry_conditions": pick({"act_buy", "act_sell", "act_enter"}),
            "no_entry_conditions": pick({"act_avoid"}),
            "exit_conditions": pick({"act_exit"}),
            "indicators": [c for c in cs if c in {"rsi", "macd", "bollinger", "atr", "moving_average", "volume"}],
            "timeframes": sorted({tf for r in rules for tf in r.get("timeframes", [])}),
            "chart_examples": [{"time": c["time"], "trend": c["trend"], "patterns": c["patterns"]} for c in charts][:20],
            "status": "draft",  # never approved before testing (Phase 7) and the user's approval
        }
