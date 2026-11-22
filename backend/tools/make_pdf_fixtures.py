"""Build the PDF fixtures for the phone's PDF reader tests (committed under app/test/fixtures/pdf).

* lo_mixed.pdf   — a Word document (Arabic + English, 2 pages, a table) exported by LibreOffice
* rl_simple.pdf  — reportlab with standard Helvetica (WinAnsi encoding), 2 pages, compressed
* objstm.pdf     — hand-made PDF 1.5: page/font objects inside a compressed object stream + xref stream
* scanned.pdf    — a page with no text (only an image) → must be reported as "no extractable text"
* encrypted.pdf  — password protected → must be refused
Run: python tools/make_pdf_fixtures.py <out_dir>
"""
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

import docx
from reportlab.lib.pagesizes import A4
from reportlab.pdfgen import canvas

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

AR1 = "إذا كان مؤشر القوة النسبية في منطقة التشبع البيعي عند الدعم فادخل صفقة شراء لمدة دقيقتين."
AR2 = "لا تدخل أي صفقة عند صدور الأخبار المهمة."
EN1 = "When RSI is overbought near resistance, sell for 3 minutes."

# 1) Word → PDF with LibreOffice
d = docx.Document()
d.add_heading("Trading rules — قواعد التداول", 1)
d.add_paragraph(AR1)
d.add_paragraph(EN1)
d.add_page_break()
d.add_paragraph(AR2)
t = d.add_table(rows=2, cols=2)
t.cell(0, 0).text, t.cell(0, 1).text = "Condition", "Action"
t.cell(1, 0).text, t.cell(1, 1).text = "MACD cross up in an uptrend", "buy"
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "lo_mixed.docx"
    d.save(src)
    subprocess.run(["soffice", "--headless", "--convert-to", "pdf", "--outdir", tmp, str(src)], check=True,
                   capture_output=True)
    (out / "lo_mixed.pdf").write_bytes((Path(tmp) / "lo_mixed.pdf").read_bytes())

# 2) reportlab, standard font
c = canvas.Canvas(str(out / "rl_simple.pdf"), pagesize=A4, pageCompression=1)
c.setFont("Helvetica", 12)
c.drawString(72, 760, "Support and resistance basics")
c.drawString(72, 740, "When the price breaks out above resistance with strong momentum, buy.")
c.drawString(72, 720, "Café, naïve — special characters: 30% & “quotes”.")
c.showPage()
c.setFont("Helvetica", 12)
c.drawString(72, 760, "If the candle closes below support, exit the trade.")
c.save()

# 3) PDF 1.5 with an object stream and a cross-reference stream (no classic xref table)
content = zlib.compress(b"BT /F1 14 Tf 72 720 Td (Object streams: when MACD crosses down in a downtrend, sell.) Tj ET")
objs_in_stream = {
    3: b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    5: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
}
header, body, off = [], b"", 0
for num, o in objs_in_stream.items():
    header.append(f"{num} {off}")
    body += o + b" "
    off = len(body)
hdr = (" ".join(header) + " ").encode()
objstm = zlib.compress(hdr + body)
pdf = bytearray(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
def add(num, data):
    offsets[num] = len(pdf)
    pdf.extend(f"{num} 0 obj\n".encode() + data + b"\nendobj\n")
add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
add(2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
add(4, f"<< /Length {len(content)} /Filter /FlateDecode >>\nstream\n".encode() + content + b"\nendstream")
add(6, f"<< /Type /ObjStm /N 2 /First {len(hdr)} /Length {len(objstm)} /Filter /FlateDecode >>\nstream\n".encode()
    + objstm + b"\nendstream")
xref_off = len(pdf)
rows = [b"\x00\x00\x00\x00\xff"]  # obj 0
for num in range(1, 8):
    if num in (3, 5):
        rows.append(b"\x02" + (6).to_bytes(2, "big") + (list(objs_in_stream).index(num)).to_bytes(2, "big"))
    elif num == 7:
        rows.append(b"\x01" + xref_off.to_bytes(2, "big") + b"\x00\x00")
    else:
        rows.append(b"\x01" + offsets[num].to_bytes(2, "big") + b"\x00\x00")
xs = zlib.compress(b"".join(rows))
pdf.extend(f"7 0 obj\n<< /Type /XRef /Size 8 /W [1 2 2] /Root 1 0 R /Length {len(xs)} /Filter /FlateDecode >>\nstream\n".encode()
           + xs + b"\nendstream\nendobj\n" + f"startxref\n{xref_off}\n%%EOF\n".encode())
(out / "objstm.pdf").write_bytes(bytes(pdf))

# 4) scanned page (image only)
c = canvas.Canvas(str(out / "scanned.pdf"), pagesize=A4)
c.rect(72, 600, 200, 100, fill=1)
c.showPage()
c.save()

# 4b) a scanned rule book: pages that are only pictures of text (JPEG on page 1, PNG/Flate on page 2)
from PIL import Image, ImageDraw, ImageFont
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 34)
pics = []
for k, lines in enumerate([
        ["Trading rules (scanned)", "When RSI is oversold near support, buy for 2 minutes."],
        ["إذا كان السعر عند المقاومة مع تشبع شرائي فادخل بيع", "Do not trade during important news."]]):
    img = Image.new("RGB", (1400, 260), "white")
    d = ImageDraw.Draw(img)
    for j, line in enumerate(lines):
        d.text((40, 40 + 100 * j), line, fill="black", font=font)
    path = Path(tempfile.gettempdir()) / f"uata_scan_{k}.{'jpg' if k == 0 else 'png'}"
    img.save(path, quality=92) if k == 0 else img.save(path)
    pics.append(path)
c = canvas.Canvas(str(out / "scanned_text.pdf"), pagesize=A4)
for path in pics:
    c.drawImage(str(path), 40, 600, width=515, height=96)
    c.showPage()
c.save()

# 5) encrypted
c = canvas.Canvas(str(out / "encrypted.pdf"), pagesize=A4, encrypt="secret-pass")
c.drawString(72, 760, "secret rules")
c.save()
print("ok", sorted(p.name for p in out.iterdir()))
