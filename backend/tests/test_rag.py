"""Phase 5: document extraction with locations, rule extraction, learning reports,
conflict detection, hybrid bilingual retrieval and RAG inside chart analysis."""
import io

import cv2
import numpy as np
import pytest

from uata.knowledge import extract as kx
from uata.knowledge.retrieval import HashingEmbedder, expand_query
from uata.knowledge.rules import conflicts, extract_rules
from uata.knowledge.textnorm import concepts, normalize
from uata.vision import axis
from uata.vision.synthetic import random_walk_ohlc, render_chart


# ---------------------------------------------------------------- fixtures: real documents
def make_pdf(pages: list[str]) -> bytes:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    for text in pages:
        y = 800
        for line in text.split("\n"):
            c.drawString(50, y, line)
            y -= 16
        c.showPage()
    c.save()
    return buf.getvalue()


def make_docx(paragraphs: list[str], table: list[list[str]] | None = None) -> bytes:
    import docx
    d = docx.Document()
    for p in paragraphs:
        d.add_paragraph(p)
    if table:
        t = d.add_table(rows=len(table), cols=len(table[0]))
        for r, row in enumerate(table):
            for c, val in enumerate(row):
                t.cell(r, c).text = val
    buf = io.BytesIO()
    d.save(buf)
    return buf.getvalue()


def make_xlsx(rows: list[list]) -> bytes:
    import openpyxl
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Trades"
    for r in rows:
        ws.append(r)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def upload(client, name, data, **form):
    return client.post("/knowledge/files", files={"file": (name, io.BytesIO(data))}, data=form)


# ---------------------------------------------------------------- extraction
def test_pdf_extraction_keeps_page_numbers():
    chunks = kx.extract_pdf(make_pdf(["Page one: trend basics.", "Page two: RSI rules.\nWhen RSI is oversold, buy."]))
    assert [c.location for c in chunks] == ["p.1-2"] or {c.location for c in chunks} <= {"p.1", "p.2", "p.1-2"}
    joined = " ".join(c.text for c in chunks)
    assert "trend basics" in joined and "RSI is oversold" in joined


def test_pdf_large_pages_split_with_own_page_location():
    long_page = ("Support and resistance explained. " * 60).strip()
    chunks = kx.extract_pdf(make_pdf(["Short intro.", long_page.replace(". ", ".\n")]))
    assert any(c.location == "p.2" for c in chunks)


def test_scanned_or_broken_pdf_reports_reason():
    with pytest.raises(kx.ExtractionError):
        kx.extract_pdf(b"%PDF-1.4 broken")
    from reportlab.pdfgen import canvas
    buf = io.BytesIO()
    c = canvas.Canvas(buf)
    c.rect(10, 10, 100, 100)  # a page without any text (like a scanned image)
    c.showPage()
    c.save()
    with pytest.raises(kx.ExtractionError, match="no extractable text"):
        kx.extract_pdf(buf.getvalue())


def test_docx_paragraphs_and_tables():
    data = make_docx(["مقدمة عن الشموع اليابانية", "عند ظهور شمعة مطرقة عند الدعم ادخل شراء"],
                     table=[["Indicator", "Value"], ["RSI", "30"]])
    chunks = kx.extract_docx(data)
    text = " ".join(c.text for c in chunks)
    assert "مطرقة" in text and "RSI | 30" in text
    assert chunks[0].location.startswith("¶")


def test_xlsx_rows_with_sheet_and_header():
    rows = [["date", "asset", "result"]] + [[f"2026-11-{i:02d}", "EURUSD", "win" if i % 2 else "loss"]
                                            for i in range(1, 60)]
    chunks = kx.extract_xlsx(make_xlsx(rows))
    assert chunks[0].location == "Trades!r1-r40"
    assert chunks[1].location.startswith("Trades!r41") and chunks[1].text.startswith("date | asset | result")


@pytest.mark.skipif(not axis.ocr_available(), reason="tesseract not installed")
def test_image_ocr_extraction():
    img = np.full((220, 1100, 3), 255, np.uint8)
    cv2.putText(img, "When RSI is oversold at support buy", (20, 90), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 0, 0), 3)
    cv2.putText(img, "Avoid trading during big news", (20, 170), cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 0, 0), 3)
    chunks = kx.extract_image(cv2.imencode(".png", img)[1].tobytes())
    text = " ".join(c.text for c in chunks).lower()
    assert "rsi" in text and "oversold" in text and chunks[0].location == "ocr"


# ---------------------------------------------------------------- normalisation, concepts, rules
def test_arabic_normalisation_and_bilingual_concepts():
    assert normalize("إِذَا الشَّمْعَةُ") == "اذا الشمعه"
    assert {"rsi", "oversold", "support", "act_buy"} <= concepts("إذا كان مؤشر القوة النسبية في التشبع البيعي عند الدعم فاشترِ")
    assert concepts("RSI oversold at support, buy") >= {"rsi", "oversold", "support", "act_buy"}
    assert "rsi" not in concepts("pressure")  # whole-word matching
    q = expand_query("rsi")
    assert "مؤشر القوه النسبيه" in q or "القوه النسبيه" in q


def test_rule_extraction_arabic_english_and_non_rules():
    text = ("إذا وصل مؤشر القوة النسبية إلى التشبع البيعي عند منطقة دعم فادخل شراء لمدة دقيقتين.\n"
            "لا تدخل إذا كان هناك خبر قوي.\n"
            "If price breaks resistance after the candle close, buy for 3 min.\n"
            "The market was quiet today.")
    rules = extract_rules(text, "¶1")
    assert len(rules) == 3
    assert rules[0].actions[0] == "act_buy" and {"rsi", "oversold", "support"} <= set(rules[0].conditions)
    assert rules[0].timeframes == ["دقيقتين"]
    assert rules[1].actions == ["act_avoid"] and rules[1].conditions == ["news"]
    assert "3 min" in rules[2].timeframes[0]


def test_conflict_detection():
    new = extract_rules("When RSI is oversold at support, buy.")[0]
    opposite = [{"item_id": 7, "text": "x", "actions": ["act_sell"], "conditions": ["oversold", "rsi", "support"]}]
    unrelated = [{"item_id": 8, "text": "y", "actions": ["act_sell"], "conditions": ["news"]}]
    same = [{"item_id": 9, "text": "z", "actions": ["act_buy", "act_enter"], "conditions": ["oversold", "rsi"]}]
    assert conflicts(new, opposite)[0]["item_id"] == 7
    assert conflicts(new, unrelated) == [] and conflicts(new, same) == []


# ---------------------------------------------------------------- learning reports through the API
def test_pdf_upload_creates_report_with_rules_pending_until_approved(client):
    pdf = make_pdf(["Reversal strategy", "When RSI is oversold at support and a bullish engulfing appears, buy.\n"
                                         "Avoid trading when big news is expected."])
    src = upload(client, "strategy.pdf", pdf, category="strategies").json()
    assert src["extraction_status"] == "done"
    rules = [i for i in src["items"] if i["item_type"] == "rule"]
    assert len(rules) == 2 and all(i["status"] == "pending_review" for i in src["items"])
    assert all(i["location"] and i["location"].startswith("p.") for i in src["items"])
    rep = src["report"]
    assert rep["status"] == "pending_review" and len(rep["extracted"]["rules"]) == 2
    assert "rsi" in rep["extracted"]["concepts"]
    # not visible to the engine yet
    assert client.get("/knowledge/retrieve", params={"q": "RSI oversold"}).json() == []
    decided = client.post(f"/knowledge/reports/{rep['id']}/decision", json={"decision": "approve"}).json()
    assert decided["status"] == "approved" and decided["items_updated"] == len(src["items"])
    hits = client.get("/knowledge/retrieve", params={"q": "RSI oversold"}).json()
    assert hits and hits[0]["source_title"] == "strategy.pdf" and hits[0]["location"].startswith("p.")


def test_conflicting_new_source_is_flagged_in_report(client):
    first = client.post("/knowledge/notes", json={
        "title": "Rule A", "content": "When RSI is oversold at support, buy."}).json()
    client.post(f"/knowledge/reports/{first['report']['id']}/decision", json={"decision": "approve"})
    second = client.post("/knowledge/notes", json={
        "title": "Rule B", "content": "إذا كان مؤشر القوة النسبية في التشبع البيعي عند الدعم فبع."}).json()
    conf = second["report"]["conflicts"]
    assert len(conf) == 1 and set(conf[0]["shared_conditions"]) >= {"rsi", "oversold", "support"}
    assert conf[0]["new_actions"] == ["act_sell"] and conf[0]["existing_actions"] == ["act_buy"]
    assert "1 conflict" in second["report"]["summary"]
    pending = client.get("/knowledge/reports", params={"status": "pending_review"}).json()
    assert [r["source_title"] for r in pending] == ["Rule B"]


def test_rejecting_report_rejects_items(client):
    src = upload(client, "rules.docx", make_docx(["If the trend is up and price is at support, buy."])).json()
    client.post(f"/knowledge/reports/{src['report']['id']}/decision", json={"decision": "reject"})
    items = client.get(f"/knowledge/sources/{src['id']}").json()["items"]
    assert items and all(i["status"] == "rejected" for i in items)
    assert client.post(f"/knowledge/reports/{src['report']['id']}/decision", json={"decision": "x"}).status_code == 400
    assert client.post("/knowledge/reports/999/decision", json={"decision": "approve"}).status_code == 404


def test_xlsx_and_failed_pdf_via_api(client):
    src = upload(client, "journal.xlsx", make_xlsx([["asset", "note"], ["EURUSD", "hammer at support worked"]])).json()
    assert src["extraction_status"] == "done" and src["items"][0]["location"] == "Trades!r1-r2"
    bad = upload(client, "scan.pdf", b"%PDF-1.4 nothing").json()
    assert bad["extraction_status"] == "failed" and bad["report"] is None


# ---------------------------------------------------------------- retrieval quality
CORPUS = [
    ("RSI", "مؤشر القوة النسبية فوق 70 يعني تشبعاً شرائياً وتحت 30 تشبعاً بيعياً"),
    ("Engulfing", "شمعة الابتلاع الشرائية بعد هبوط تدل على انعكاس محتمل للأعلى"),
    ("Hammer", "The hammer candle after a decline signals possible reversal"),
    ("Support", "مستويات الدعم هي مناطق يتوقف عندها الهبوط بسبب الطلب"),
    ("Resistance", "Resistance is where selling pressure stops a rally"),
    ("Bollinger", "Bollinger bands squeeze precedes volatility expansion"),
    ("MACD", "تقاطع الماكد الصاعد مع خط الإشارة يدعم الشراء"),
    ("News", "تجنب التداول وقت الأخبار الاقتصادية القوية"),
    ("Trend", "Trade in the direction of the trend; higher highs and higher lows define an uptrend"),
    ("Liquidity", "السيولة تتجمع فوق القمم المتساوية وتحت القيعان المتساوية"),
    ("Doji", "الدوجي يدل على تردد السوق"),
    ("Volume", "High volume confirms a breakout"),
]
QUERIES = [
    ("RSI overbought", "RSI"), ("bullish engulfing", "Engulfing"), ("مطرقة بعد هبوط", "Hammer"),
    ("support level", "Support"), ("مقاومة", "Resistance"), ("bollinger squeeze", "Bollinger"),
    ("macd cross", "MACD"), ("news", "News"), ("اتجاه صاعد", "Trend"), ("equal highs liquidity", "Liquidity"),
    ("doji", "Doji"), ("حجم التداول والاختراق", "Volume"),
]


def test_bilingual_retrieval_benchmark(client):
    for title, content in CORPUS:
        n = client.post("/knowledge/notes", json={"title": title, "content": content}).json()
        client.post(f"/knowledge/reports/{n['report']['id']}/decision", json={"decision": "approve"})
    top1 = sum(client.get("/knowledge/retrieve", params={"q": q, "k": 3}).json()[0]["title"] == exp
               for q, exp in QUERIES)
    top3 = sum(exp in [h["title"] for h in client.get("/knowledge/retrieve", params={"q": q, "k": 3}).json()]
               for q, exp in QUERIES)
    # measured in development: 12/12 top-3; enforce a floor so regressions fail the build
    assert top3 >= 11, top3
    assert top1 >= 10, top1


def test_embedder_is_deterministic_and_normalised():
    e = HashingEmbedder()
    a, b = e.embed("شمعة مطرقة عند الدعم"), e.embed("شمعة مطرقة عند الدعم")
    assert np.array_equal(a, b) and abs(np.linalg.norm(a) - 1) < 1e-5
    assert float(e.embed("hammer at support") @ e.embed("مطرقة عند الدعم")) > 0.2  # concept bridge


def test_old_items_are_indexed_on_startup(paths):
    from uata.db.database import Database, utcnow
    from uata.services.knowledge_service import KnowledgeService
    db = Database(paths.db_file)
    db.migrate()
    with db.session() as conn:  # an item written without an embedding (pre-Phase-5 database)
        conn.execute("INSERT INTO knowledge_items(item_type,title,content,status,created_at,updated_at) "
                     "VALUES ('note','Old','RSI legacy note','approved',?,?)", (utcnow(), utcnow()))
    ks = KnowledgeService(db, paths.files_dir)
    assert ks.retrieve("RSI legacy")[0]["title"] == "Old"


# ---------------------------------------------------------------- RAG inside chart analysis
def test_chart_analysis_cites_approved_knowledge_only(client):
    pending = client.post("/knowledge/notes", json={"title": "Pending trend note",
                                                    "content": "uptrend downtrend trend rule pending"}).json()
    approved = client.post("/knowledge/notes", json={
        "title": "Trend rule", "content": "Trade with the trend: in an uptrend look for buys, in a downtrend sells."}).json()
    client.post(f"/knowledge/reports/{approved['report']['id']}/decision", json={"decision": "approve"})
    ohlc = [(1 + i * 0.002, 1 + i * 0.002 + 0.0015, 1 + i * 0.002 - 0.0005, 1 + i * 0.002 + 0.001) for i in range(60)]
    png = cv2.imencode(".png", render_chart(ohlc, style="dark_tv").image)[1].tobytes()
    a = client.post("/analysis/inputs", files={"file": ("c.png", io.BytesIO(png))}).json()["analysis"]
    titles = [k["title"] for k in a["knowledge"]]
    assert "Trend rule" in titles
    assert "Pending trend note" not in titles
    assert a["signal"] == "WAIT"
    assert pending["report"]["status"] == "pending_review"
