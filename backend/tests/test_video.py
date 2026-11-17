"""Phase 6: educational video analysis with exact timestamps."""
import io
import subprocess

import pytest

from uata.video import transcript as tr
from uata.video.analyzer import VideoAnalyzer, fmt_ts
from uata.video.synthetic import SRT, write_video
from uata.video.transcript import FasterWhisperSTT, Segment, SpeechToText, parse_subtitles
from uata.vision import axis

needs_ocr = pytest.mark.skipif(not axis.ocr_available(), reason="tesseract not installed")


@pytest.fixture(scope="module")
def video(tmp_path_factory):
    return write_video(tmp_path_factory.mktemp("v") / "lesson.mp4")


# ---------------------------------------------------------------- subtitles
def test_parse_srt_and_vtt():
    segs = parse_subtitles(SRT)
    assert [s.start_ms for s in segs] == [500, 4000, 10500, 16500]
    assert segs[1].text.startswith("إذا كان مؤشر")
    vtt = "WEBVTT\n\n00:01.000 --> 00:03.500 align:start\n<i>Buy at support</i>\n\n01:02:03.250 --> 01:02:05.000\nExit\n"
    v = parse_subtitles(vtt)
    assert (v[0].start_ms, v[0].end_ms, v[0].text) == (1000, 3500, "Buy at support")
    assert v[1].start_ms == 3723250
    with pytest.raises(ValueError):
        parse_subtitles("not subtitles at all")


def test_fmt_ts():
    assert fmt_ts(4000) == "00:04" and fmt_ts(3723000) == "1:02:03"


# ---------------------------------------------------------------- analyzer
@needs_ocr
def test_analysis_with_subtitles_timestamps_charts_and_rules(video):
    a = VideoAnalyzer().analyze(video, parse_subtitles(SRT), "subtitles").to_dict()
    assert 20000 <= a["duration_ms"] <= 21500
    screen = [t for t in a["timeline"] if t["kind"] == "screen_text"]
    assert [t["time"] for t in screen] == ["00:00", "00:04", "00:16"]  # each slide, at its exact start
    assert "oversold" in screen[1]["text"] and screen[1]["clarity"] > 0.8
    # the chart scene 10–16 s is recognised as a chart (not OCR text) and described
    assert len(a["charts"]) == 1
    c = a["charts"][0]
    assert c["start_ms"] == 10000 and c["end_ms"] >= 15000 and c["trend"] == "up" and c["candles"] >= 50
    rules = {(r["location"], r["kind"]): r for r in a["rules"]}
    assert rules[("00:04", "screen_text")]["actions"] == ["act_buy"]
    assert rules[("00:04", "screen_text")]["timeframes"] == ["2 min"]
    assert rules[("00:04", "speech")]["timeframes"] == ["دقيقتين"]  # Arabic subtitle
    assert rules[("00:16", "screen_text")]["actions"] == ["act_avoid"]  # "do not enter" ≠ entry
    assert rules[("00:16", "speech")]["actions"] == ["act_exit"]
    st = a["strategy"]
    assert st["status"] == "draft" and st["indicators"] == ["rsi"]
    assert [x["time"] for x in st["no_entry_conditions"]] == ["00:16"]
    assert [x["time"] for x in st["exit_conditions"]] == ["00:16"]
    assert all(x["time"] == "00:04" for x in st["entry_conditions"])
    assert a["transcript_source"] == "subtitles" and a["warnings"] == []
    assert a["summary"] and all("time" in s for s in a["summary"])


@needs_ocr
def test_without_transcript_screen_text_still_used_and_reported(video):
    a = VideoAnalyzer().analyze(video, None, "none", "speech_to_text_model_not_installed").to_dict()
    assert "speech_to_text_model_not_installed" in a["warnings"]
    assert {r["kind"] for r in a["rules"]} == {"screen_text"}


def test_corrupt_video_rejected(tmp_path):
    bad = tmp_path / "bad.mp4"
    bad.write_bytes(b"\x00\x00\x00\x18ftypmp42 not really")
    with pytest.raises(ValueError):
        VideoAnalyzer().analyze(bad)


# ---------------------------------------------------------------- speech-to-text plug
def test_faster_whisper_without_model_is_unavailable_and_never_downloads(tmp_path, monkeypatch):
    monkeypatch.delenv("UATA_WHISPER_MODEL", raising=False)
    assert FasterWhisperSTT().available is False
    assert FasterWhisperSTT(str(tmp_path / "missing")).available is False
    segs, err = tr.transcribe_video(tmp_path / "x.mp4", FasterWhisperSTT())
    assert segs == [] and err == "speech_to_text_model_not_installed"


class FakeSTT(SpeechToText):
    name, available = "fake", True

    def __init__(self):
        self.calls = []

    def transcribe(self, wav, language=None):
        self.calls.append(wav.stat().st_size)
        return [Segment(4000, 9000, "When RSI is oversold at support, buy.", 0.9)]


def test_stt_receives_extracted_audio(video, tmp_path):
    exe = tr.ffmpeg_exe()
    with_audio = tmp_path / "with_audio.mp4"
    subprocess.run([exe, "-y", "-v", "error", "-i", str(video), "-f", "lavfi", "-i", "sine=frequency=440:duration=21",
                    "-c:v", "copy", "-c:a", "aac", "-shortest", str(with_audio)], check=True)
    stt = FakeSTT()
    segs, err = tr.transcribe_video(with_audio, stt)
    assert err is None and segs[0].confidence == 0.9 and stt.calls[0] > 100_000  # ~21 s of 16 kHz audio
    segs, err = tr.transcribe_video(video, stt)  # video without an audio track
    assert segs == [] and err == "video_has_no_audio"


# ---------------------------------------------------------------- API: library, report, strategy draft
def _upload(client, video_path, with_subs=True):
    files = {"file": ("lesson.mp4", video_path.read_bytes())}
    if with_subs:
        files["subtitles"] = ("lesson.srt", SRT.encode())
    return client.post("/knowledge/files", files=files).json()


@needs_ocr
def test_video_upload_flow_pending_until_approved(client, services, video):
    src = _upload(client, video)
    assert src["kind"] == "video" and src["extraction_status"] == "pending"
    services.videos.wait(src["id"])
    page = client.get(f"/videos/{src['id']}").json()
    assert page["status"] == "done" and page["progress"] == 1 and page["transcript_source"] == "subtitles"
    assert page["title"] == "lesson.mp4" and page["summary"] and page["has_subtitles"]
    # every rule carries its exact time, clarity and approval status
    assert all(r["video_timestamp_ms"] is not None and r["location"] for r in page["rules"])
    assert {r["location"] for r in page["rules"]} == {"00:04", "00:16"}
    assert all(r["status"] == "pending_review" for r in page["items"])
    assert any(i["item_type"] == "example" and "trend up" in i["content"] for i in page["items"])
    assert page["strategy"]["status"] == "draft" and page["strategy"]["source_id"] == src["id"]
    assert page["report"]["status"] == "pending_review" and "chart scene" in page["report"]["summary"]
    assert client.get("/knowledge/retrieve", params={"q": "RSI oversold"}).json() == []
    client.post(f"/knowledge/reports/{page['report']['id']}/decision", json={"decision": "approve"})
    hits = client.get("/knowledge/retrieve", params={"q": "RSI oversold support buy"}).json()
    assert hits and hits[0]["source_title"] == "lesson.mp4" and hits[0]["location"] == "00:04"
    # approving knowledge does NOT approve the strategy: it stays a draft until tested (Phase 7)
    assert client.get(f"/videos/{src['id']}").json()["strategy"]["status"] == "draft"
    listed = client.get("/videos").json()
    assert listed[0]["source_id"] == src["id"] and listed[0]["report_status"] == "approved"


@needs_ocr
def test_reanalysis_keeps_approved_and_replaces_pending(client, services, video):
    src = _upload(client, video, with_subs=False)
    services.videos.wait(src["id"])
    p1 = client.get(f"/videos/{src['id']}").json()
    assert p1["transcript_source"] == "none" and "speech_to_text_model_not_installed" in p1["warnings"]
    keep = p1["rules"][0]["id"]
    client.post(f"/knowledge/items/{keep}/decision", json={"decision": "approve"})
    r = client.post(f"/videos/{src['id']}/subtitles", files={"file": ("s.srt", SRT.encode())})
    assert r.status_code == 200
    services.videos.wait(src["id"])
    p2 = client.get(f"/videos/{src['id']}").json()
    assert p2["transcript_source"] == "subtitles"
    ids = {i["id"] for i in p2["items"]}
    assert keep in ids  # approved knowledge survives re-analysis
    assert {r_["kind"] for r_ in p2["timeline"]} == {"speech", "screen_text"}


def test_invalid_subtitles_and_missing_video(client, video):
    bad = client.post("/knowledge/files", files={"file": ("x.mp4", video.read_bytes()),
                                                 "subtitles": ("x.srt", b"garbage")})
    assert bad.status_code == 400
    assert client.get("/videos/999").status_code == 404
    assert client.post("/videos/999/reanalyze").status_code == 404


def test_corrupt_video_upload_fails_with_reason(client, services):
    src = client.post("/knowledge/files", files={"file": ("broken.mp4", b"\x00\x00\x00\x18ftypmp42xx")}).json()
    services.videos.wait(src["id"])
    page = client.get(f"/videos/{src['id']}").json()
    assert page["status"] == "failed" and page["error"]
    assert client.get(f"/knowledge/sources/{src['id']}").json()["extraction_status"] == "failed"


def test_jobs_are_serialised_and_rerun_requests_honoured(services, video, client):
    """Upload then immediately add subtitles: both requests run one after the other, never concurrently."""
    src = client.post("/knowledge/files", files={"file": ("lesson.mp4", video.read_bytes())}).json()
    r = client.post(f"/videos/{src['id']}/subtitles", files={"file": ("s.srt", SRT.encode())})
    assert r.status_code == 200
    assert services.videos.wait(src["id"], 60)
    page = client.get(f"/videos/{src['id']}").json()
    assert page["status"] == "done" and page["transcript_source"] == "subtitles"
    assert len([r_ for r_ in client.get("/knowledge/reports").json() if r_["source_id"] == src["id"]]) >= 1
