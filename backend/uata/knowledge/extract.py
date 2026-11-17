"""Local text extraction with exact locations.

Every extracted chunk keeps where it came from (page, paragraph range, sheet and
rows, or "image OCR"), so each piece of knowledge can be traced to its source.
Nothing is sent anywhere.
"""

from __future__ import annotations

import io
import re
from dataclasses import dataclass
from pathlib import Path

CHUNK_CHARS = 1200


@dataclass
class Chunk:
    text: str
    location: str      # e.g. "p.3", "¶12-18", "Sheet1!r2-r40", "ocr"


class ExtractionError(Exception):
    pass


def _pack(paragraphs: list[tuple[str, str]], size: int = CHUNK_CHARS) -> list[Chunk]:
    """Pack (text, location) paragraphs into chunks, merging locations ("p.3-4")."""
    out: list[Chunk] = []
    buf, locs = "", []
    for text, loc in paragraphs:
        text = text.strip()
        if not text:
            continue
        while len(text) > size:  # hard split very long paragraphs at a sentence boundary if possible
            cut = max(text.rfind(". ", 0, size), text.rfind("۔", 0, size), text.rfind("\n", 0, size))
            cut = cut + 1 if cut > size // 2 else size
            if buf:
                out.append(Chunk(buf, _merge(locs)))
                buf, locs = "", []
            out.append(Chunk(text[:cut].strip(), loc))
            text = text[cut:].strip()
        if buf and len(buf) + 2 + len(text) > size:
            out.append(Chunk(buf, _merge(locs)))
            buf, locs = "", []
        buf = f"{buf}\n\n{text}" if buf else text
        locs.append(loc)
    if buf:
        out.append(Chunk(buf, _merge(locs)))
    return out


def _merge(locs: list[str]) -> str:
    uniq = list(dict.fromkeys(locs))
    if len(uniq) == 1:
        return uniq[0]
    m1, m2 = re.match(r"(\D+)(\d+)$", uniq[0]), re.match(r"(\D+)(\d+)$", uniq[-1])
    if m1 and m2 and m1.group(1) == m2.group(1):
        return f"{m1.group(1)}{m1.group(2)}-{m2.group(2)}"
    return f"{uniq[0]}…{uniq[-1]}"


def extract_txt(data: bytes) -> list[Chunk]:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as e:
        raise ExtractionError("text file is not UTF-8") from e
    paras = [p for p in re.split(r"\n\s*\n", text)]
    return _pack([(p, f"¶{i + 1}") for i, p in enumerate(paras)])


def extract_pdf(data: bytes) -> list[Chunk]:
    from pypdf import PdfReader
    try:
        reader = PdfReader(io.BytesIO(data))
        if reader.is_encrypted:
            raise ExtractionError("PDF is password protected")
        pages = [(page.extract_text() or "", f"p.{i + 1}") for i, page in enumerate(reader.pages)]
    except ExtractionError:
        raise
    except Exception as e:
        raise ExtractionError(f"PDF could not be read: {e}") from e
    if not any(t.strip() for t, _ in pages):
        raise ExtractionError("PDF has no extractable text (scanned images; OCR of PDFs is not supported yet)")
    return _pack(pages)


def extract_docx(data: bytes) -> list[Chunk]:
    import docx
    try:
        d = docx.Document(io.BytesIO(data))
    except Exception as e:
        raise ExtractionError(f"Word file could not be read: {e}") from e
    paras = [(p.text, f"¶{i + 1}") for i, p in enumerate(d.paragraphs)]
    for t_i, table in enumerate(d.tables):
        for r_i, row in enumerate(table.rows):
            cells = [c.text.strip() for c in row.cells]
            if any(cells):
                paras.append((" | ".join(cells), f"table{t_i + 1}.r{r_i + 1}"))
    return _pack(paras)


def extract_xlsx(data: bytes) -> list[Chunk]:
    import openpyxl
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as e:
        raise ExtractionError(f"Excel file could not be read: {e}") from e
    out: list[Chunk] = []
    for ws in wb.worksheets:
        rows = []
        for r_i, row in enumerate(ws.iter_rows(values_only=True), start=1):
            vals = ["" if v is None else str(v) for v in row]
            if any(v.strip() for v in vals):
                rows.append((r_i, " | ".join(vals)))
        # group ~40 rows per chunk, keeping the header row with each chunk
        header = rows[0][1] if rows else ""
        for start in range(0, len(rows), 40):
            part = rows[start:start + 40]
            body = "\n".join(t for _, t in part)
            if start > 0 and header:
                body = header + "\n" + body
            out.append(Chunk(body, f"{ws.title}!r{part[0][0]}-r{part[-1][0]}"))
    wb.close()
    return out


def extract_image(data: bytes) -> list[Chunk]:
    """OCR text in an image (local Tesseract, Arabic + English when available)."""
    import cv2
    import numpy as np

    from uata.vision import axis
    if not axis.ocr_available():
        raise ExtractionError("OCR (Tesseract) is not installed")
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ExtractionError("image could not be decoded")
    langs = axis.pytesseract.get_languages(config="")
    lang = "+".join(l_ for l_ in ("ara", "eng") if l_ in langs) or "eng"
    text = axis.pytesseract.image_to_string(img, lang=lang)
    text = re.sub(r"[ \t]+", " ", text).strip()
    if len(text) < 15:
        return []
    return _pack([(text, "ocr")])


EXTRACTORS = {"txt": extract_txt, "pdf": extract_pdf, "docx": extract_docx, "xlsx": extract_xlsx,
              "image": extract_image}


def extract(kind: str, path: Path) -> list[Chunk]:
    fn = EXTRACTORS.get(kind)
    if fn is None:
        raise ExtractionError(f"extraction for '{kind}' is not supported yet")
    return fn(Path(path).read_bytes())
