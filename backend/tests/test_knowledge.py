import io

from uata.services.knowledge_service import chunk_text, fts_query


def test_add_note_is_pending_until_approved(client):
    src = client.post("/knowledge/notes", json={
        "title": "ارتداد من الدعم", "content": "عند ملامسة السعر لمستوى دعم قوي مع شمعة ابتلاعية صاعدة",
        "category": "price_action", "tags": ["support"], "item_type": "rule"}).json()
    item = src["items"][0]
    assert item["status"] == "pending_review"
    # visible in normal search, invisible to the engine until approved
    assert len(client.get("/knowledge/search", params={"q": "ابتلاعية"}).json()) == 1
    assert client.get("/knowledge/search", params={"q": "ابتلاعية", "approved_only": True}).json() == []
    client.post(f"/knowledge/items/{item['id']}/decision", json={"decision": "approve"})
    hits = client.get("/knowledge/search", params={"q": "ابتلاعية", "approved_only": True}).json()
    assert len(hits) == 1 and hits[0]["source_title"] == "ارتداد من الدعم"


def test_editing_content_requires_reapproval(client):
    item = client.post("/knowledge/notes", json={"title": "t", "content": "RSI above 70"}).json()["items"][0]
    client.post(f"/knowledge/items/{item['id']}/decision", json={"decision": "approve"})
    edited = client.patch(f"/knowledge/items/{item['id']}", json={"content": "RSI above 80"}).json()
    assert edited["status"] == "pending_review"
    # metadata-only edits keep approval
    client.post(f"/knowledge/items/{item['id']}/decision", json={"decision": "approve"})
    assert client.patch(f"/knowledge/items/{item['id']}", json={"category": "x"}).json()["status"] == "approved"


def test_reject_and_bad_decision(client):
    item = client.post("/knowledge/notes", json={"title": "t", "content": "c"}).json()["items"][0]
    assert client.post(f"/knowledge/items/{item['id']}/decision", json={"decision": "reject"}).json()["status"] \
        == "rejected"
    assert client.post(f"/knowledge/items/{item['id']}/decision", json={"decision": "maybe"}).status_code == 400
    assert client.post("/knowledge/items/9999/decision", json={"decision": "approve"}).status_code == 404


def test_upload_text_file_extracts_and_chunks(client, paths):
    body = ("MACD crossover strategy.\n\n" + "Momentum paragraph. " * 120).encode()
    r = client.post("/knowledge/files", files={"file": ("strategy.txt", io.BytesIO(body), "text/plain")},
                    data={"category": "momentum", "tags": "macd, momentum"})
    assert r.status_code == 201
    src = r.json()
    assert src["kind"] == "txt" and src["extraction_status"] == "done"
    assert src["tags"] == ["macd", "momentum"]
    assert len(src["items"]) >= 2 and all(i["status"] == "pending_review" for i in src["items"])
    assert (paths.files_dir / src["stored_path"]).read_bytes() == body
    assert client.get(f"/knowledge/sources/{src['id']}/file").content == body


def test_upload_binary_formats_are_stored_and_flagged(client):
    r = client.post("/knowledge/files", files={"file": ("book.pdf", io.BytesIO(b"%PDF-1.4 fake"), "application/pdf")})
    src = r.json()
    # a broken PDF is stored but marked failed, with the reason (nothing silently ignored)
    assert src["kind"] == "pdf" and src["extraction_status"] == "failed" and src["items"] == []
    assert src["notes"].startswith("extraction:")
    v = client.post("/knowledge/files", files={"file": ("lesson.mp4", io.BytesIO(b"\x00\x00\x00\x18ftypmp42"))}).json()
    assert v["kind"] == "video" and v["extraction_status"] == "pending"  # Phase 6: analysed in the background


def test_duplicate_upload_detected(client):
    f = {"file": ("a.txt", io.BytesIO(b"same content"), "text/plain")}
    first = client.post("/knowledge/files", files=f).json()
    r = client.post("/knowledge/files", files={"file": ("b.txt", io.BytesIO(b"same content"), "text/plain")})
    assert r.status_code == 409 and r.json()["detail"]["source_id"] == first["id"]


def test_empty_upload_rejected(client):
    assert client.post("/knowledge/files", files={"file": ("e.txt", io.BytesIO(b""), "text/plain")}).status_code == 400


def test_path_traversal_filename_is_neutralised(client, paths):
    r = client.post("/knowledge/files", files={"file": ("../../evil.txt", io.BytesIO(b"x1"), "text/plain")})
    src = r.json()
    assert src["original_name"] == "evil.txt"
    assert (paths.files_dir / src["stored_path"]).resolve().is_relative_to(paths.files_dir.resolve())


def test_delete_source_removes_file_and_items(client, paths):
    src = client.post("/knowledge/files", files={"file": ("d.txt", io.BytesIO(b"delete me"), "text/plain")}).json()
    stored = paths.files_dir / src["stored_path"]
    assert stored.exists()
    assert client.delete(f"/knowledge/sources/{src['id']}").status_code == 200
    assert not stored.exists()
    assert client.get(f"/knowledge/sources/{src['id']}").status_code == 404
    assert client.get("/knowledge/search", params={"q": "delete"}).json() == []


def test_update_source_and_list_filters(client):
    a = client.post("/knowledge/notes", json={"title": "A", "content": "x", "category": "c1"}).json()
    client.post("/knowledge/notes", json={"title": "B", "content": "y", "category": "c2"})
    client.post("/knowledge/urls", json={"url": "https://example.com/lesson", "title": "Lesson"})
    assert len(client.get("/knowledge/sources").json()) == 3
    assert [s["title"] for s in client.get("/knowledge/sources", params={"category": "c1"}).json()] == ["A"]
    assert len(client.get("/knowledge/sources", params={"kind": "url"}).json()) == 1
    upd = client.patch(f"/knowledge/sources/{a['id']}", json={"title": "A2", "tags": ["t"]}).json()
    assert upd["title"] == "A2" and upd["tags"] == ["t"]
    assert client.patch(f"/knowledge/sources/{a['id']}", json={"sha256": "x"}).status_code == 400


def test_url_validation(client):
    assert client.post("/knowledge/urls", json={"url": "javascript:alert(1)"}).status_code == 400


def test_links(client):
    a = client.post("/knowledge/notes", json={"title": "A", "content": "x"}).json()["items"][0]
    b = client.post("/knowledge/notes", json={"title": "B", "content": "y"}).json()["items"][0]
    assert client.post(f"/knowledge/items/{a['id']}/links",
                       json={"to_item_id": b["id"], "relation": "contradicts"}).status_code == 201


def test_search_handles_hostile_query(client):
    client.post("/knowledge/notes", json={"title": "t", "content": "bollinger squeeze"})
    for q in ['"', "AND OR NOT", "*", "boll* NEAR(", "'; DROP TABLE x;--"]:
        assert client.get("/knowledge/search", params={"q": q}).status_code == 200
    assert len(client.get("/knowledge/search", params={"q": "boll"}).json()) == 1  # prefix match


def test_chunk_text_and_fts_query_helpers():
    assert chunk_text("") == []
    chunks = chunk_text("a" * 4000, size=1500)
    assert [len(c) for c in chunks] == [1500, 1500, 1000]
    assert chunk_text("p1\n\np2") == ["p1\n\np2"]
    assert fts_query("!!!") is None
    assert fts_query('rsi "70"') == '"rsi"* "70"*'
