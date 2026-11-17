"""FastAPI application: the local HTTP interface between the Flutter UI and the engine.

Security model
--------------
* Binds to 127.0.0.1 only (see ``__main__``).
* Every endpoint except ``/health`` requires the ``X-UATA-Token`` header. The token
  is random per launch and written to ``<data dir>/api_token`` with owner-only
  permissions, so only local processes of the same user (the UI) can call the API.
  This also blocks web pages in a browser from driving the engine (no CORS is
  enabled and they cannot read the token).
* There is no endpoint that places, sends or executes a trade. None will be added.
"""

from __future__ import annotations

import secrets
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field, ValidationError

from uata.config import API_VERSION, ENGINE_VERSION, Paths, _restrict_permissions
from uata.db.database import Database
from uata.services.backup_service import BackupError, BackupService
from uata.services.control_service import ControlService, PermissionRequired
from uata.services.knowledge_service import Duplicate, KnowledgeService, NotFound
from uata.services.records_service import RecordsService
from uata.services.settings_service import SettingsService

WIPE_CONFIRMATION = "DELETE ALL MY DATA"


@dataclass
class Services:
    paths: Paths
    db: Database
    settings: SettingsService
    control: ControlService
    knowledge: KnowledgeService
    records: RecordsService
    backup: BackupService


def build_services(paths: Paths) -> Services:
    paths.ensure()
    db = Database(paths.db_file)
    db.migrate()
    _restrict_permissions(paths.db_file, 0o600)
    return Services(paths, db, SettingsService(db), ControlService(db),
                    KnowledgeService(db, paths.files_dir), RecordsService(db), BackupService(db, paths))


# ---------------------------------------------------------------- request bodies
class NoteIn(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    content: str = Field(min_length=1, max_length=200_000)
    category: str | None = None
    tags: list[str] = []
    item_type: str = "note"


class UrlIn(BaseModel):
    url: str
    title: str | None = None
    notes: str | None = None


class DecisionIn(BaseModel):
    decision: str


class LinkIn(BaseModel):
    to_item_id: int
    relation: str = "related"


class StartIn(BaseModel):
    input_mode: str = "upload"
    asset: str | None = None


class BackupIn(BaseModel):
    passphrase: str


class WipeIn(BaseModel):
    confirm: str
    include_backups: bool = False


class ResultIn(BaseModel):
    signal_id: int | None = None
    account_type: str
    asset: str
    timeframe_sec: int
    strategy_id: int | None = None
    signal_type: str
    signal_time: str
    duration_sec: int
    outcome: str
    pnl: float | None = None
    market_condition: str | None = None
    notes: str | None = None


def create_app(paths: Paths, token: str | None = None) -> FastAPI:
    svc = build_services(paths)
    token = token or secrets.token_urlsafe(32)
    paths.token_file.write_text(token, encoding="utf-8")
    _restrict_permissions(paths.token_file, 0o600)

    app = FastAPI(title="Universal AI Trading Assistant — Local Engine", version=ENGINE_VERSION)
    app.state.services = svc

    def auth(x_uata_token: str | None = Header(default=None)) -> None:
        if x_uata_token is None or not secrets.compare_digest(x_uata_token, token):
            raise HTTPException(401, "missing or invalid X-UATA-Token")

    @app.exception_handler(ValidationError)
    async def _validation(_, exc: ValidationError):  # pydantic errors from services
        return JSONResponse(status_code=422, content={"detail": exc.errors(include_url=False,
                                                                            include_context=False)})

    @app.exception_handler(ValueError)
    async def _value(_, exc: ValueError):
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    @app.exception_handler(NotFound)
    async def _nf(_, exc: NotFound):
        return JSONResponse(status_code=404, content={"detail": f"not found: {exc}"})

    # ------------------------------------------------------------ health
    @app.get("/health")
    def health() -> dict[str, Any]:
        return {"ok": True, "engine_version": ENGINE_VERSION, "api_version": API_VERSION}

    a = [Depends(auth)]

    # ------------------------------------------------------------ settings
    @app.get("/settings", dependencies=a)
    def get_settings():
        return svc.settings.get().model_dump()

    @app.patch("/settings", dependencies=a)
    def patch_settings(patch: dict[str, Any]):
        return svc.settings.update(patch).model_dump()

    @app.post("/settings/reset", dependencies=a)
    def reset_settings():
        return svc.settings.reset().model_dump()

    # ------------------------------------------------------------ analysis control
    @app.get("/analysis/status", dependencies=a)
    def analysis_status():
        return svc.control.status()

    @app.post("/analysis/start", dependencies=a)
    def analysis_start(body: StartIn):
        s = svc.settings.get()
        try:
            svc.control.start(body.input_mode, s.candle_timeframe_sec, body.asset, s.screen_capture_allowed)
        except PermissionRequired as e:
            raise HTTPException(403, str(e)) from None
        return svc.control.status()

    @app.post("/analysis/stop", dependencies=a)
    def analysis_stop():
        svc.control.stop()
        return svc.control.status()

    @app.post("/analysis/emergency-stop", dependencies=a)
    def emergency_stop():
        """Kill switch: stop everything and revoke continuous analysis + screen capture."""
        svc.control.stop(reason="emergency_stop", emergency=True)
        svc.settings.update({"continuous_analysis": False, "screen_capture_allowed": False})
        return svc.control.status()

    # ------------------------------------------------------------ knowledge
    @app.get("/knowledge/sources", dependencies=a)
    def list_sources(kind: str | None = None, category: str | None = None,
                     limit: int = Query(100, le=500), offset: int = 0):
        return svc.knowledge.list_sources(kind, category, limit, offset)

    @app.get("/knowledge/sources/{source_id}", dependencies=a)
    def get_source(source_id: int):
        return svc.knowledge.get_source(source_id)

    @app.patch("/knowledge/sources/{source_id}", dependencies=a)
    def patch_source(source_id: int, patch: dict[str, Any]):
        return svc.knowledge.update_source(source_id, patch)

    @app.delete("/knowledge/sources/{source_id}", dependencies=a)
    def delete_source(source_id: int):
        svc.knowledge.delete_source(source_id)
        return {"deleted": source_id}

    @app.get("/knowledge/sources/{source_id}/file", dependencies=a)
    def download_source(source_id: int):
        src = svc.knowledge.get_source(source_id)
        return FileResponse(svc.knowledge.file_path(source_id), filename=src.get("original_name"))

    @app.post("/knowledge/notes", dependencies=a, status_code=201)
    def add_note(body: NoteIn):
        return svc.knowledge.add_note(body.title, body.content, body.category, body.tags, body.item_type)

    @app.post("/knowledge/urls", dependencies=a, status_code=201)
    def add_url(body: UrlIn):
        return svc.knowledge.add_url(body.url, body.title, body.notes)

    @app.post("/knowledge/files", dependencies=a, status_code=201)
    def add_file(file: UploadFile = File(...), title: str | None = Form(None),
                 category: str | None = Form(None), tags: str | None = Form(None)):
        tag_list = [t.strip() for t in (tags or "").split(",") if t.strip()]
        try:
            return svc.knowledge.add_file(file.filename or "upload.bin", file.file, title, category, tag_list)
        except Duplicate as e:
            raise HTTPException(409, {"message": str(e), "source_id": e.source_id}) from None

    @app.get("/knowledge/items", dependencies=a)
    def list_items(status: str | None = None, limit: int = Query(200, le=1000)):
        return svc.knowledge.list_items(status, limit)

    @app.patch("/knowledge/items/{item_id}", dependencies=a)
    def patch_item(item_id: int, patch: dict[str, Any]):
        return svc.knowledge.update_item(item_id, patch)

    @app.post("/knowledge/items/{item_id}/decision", dependencies=a)
    def decide_item(item_id: int, body: DecisionIn):
        return svc.knowledge.decide_item(item_id, body.decision)

    @app.post("/knowledge/items/{item_id}/links", dependencies=a, status_code=201)
    def link_item(item_id: int, body: LinkIn):
        svc.knowledge.link_items(item_id, body.to_item_id, body.relation)
        return {"linked": True}

    @app.get("/knowledge/search", dependencies=a)
    def search(q: str, approved_only: bool = False, limit: int = Query(20, le=100)):
        return svc.knowledge.search(q, approved_only, limit)

    # ------------------------------------------------------------ signals & results
    @app.get("/signals", dependencies=a)
    def list_signals(limit: int = Query(100, le=1000), offset: int = 0, signal: str | None = None):
        return svc.records.list_signals(limit, offset, signal)

    @app.get("/results", dependencies=a)
    def list_results(account_type: str | None = None):
        return svc.records.list_results(account_type)

    @app.post("/results", dependencies=a, status_code=201)
    def add_result(body: ResultIn):
        return svc.records.add_result(body.model_dump())

    @app.delete("/results/{result_id}", dependencies=a)
    def delete_result(result_id: int):
        if not svc.records.delete_result(result_id):
            raise HTTPException(404, "result not found")
        return {"deleted": result_id}

    @app.get("/stats/summary", dependencies=a)
    def stats_summary():
        return svc.records.summary()

    # ------------------------------------------------------------ backup & privacy
    @app.get("/backups", dependencies=a)
    def list_backups():
        return svc.backup.list_backups()

    @app.post("/backups", dependencies=a, status_code=201)
    def create_backup(body: BackupIn):
        try:
            path = svc.backup.create(body.passphrase)
        except BackupError as e:
            raise HTTPException(400, str(e)) from None
        return {"name": path.name, "size_bytes": path.stat().st_size}

    @app.get("/backups/{name}", dependencies=a)
    def download_backup(name: str):
        p = (paths.backups_dir / Path(name).name)
        if p.suffix != ".uatabak" or not p.exists():
            raise HTTPException(404, "backup not found")
        return FileResponse(p, filename=p.name, media_type="application/octet-stream")

    @app.post("/backups/restore", dependencies=a)
    def restore_backup(file: UploadFile = File(...), passphrase: str = Form(...)):
        svc.control.stop(reason="restore")
        with tempfile.NamedTemporaryFile(dir=paths.root, suffix=".uatabak", delete=False) as tmp:
            shutil.copyfileobj(file.file, tmp)
            tmp_path = Path(tmp.name)
        try:
            return svc.backup.restore(tmp_path, passphrase)
        except BackupError as e:
            raise HTTPException(400, str(e)) from None
        finally:
            tmp_path.unlink(missing_ok=True)

    @app.post("/privacy/wipe", dependencies=a)
    def wipe(body: WipeIn):
        if body.confirm != WIPE_CONFIRMATION:
            raise HTTPException(400, f"confirmation text must be exactly: {WIPE_CONFIRMATION}")
        svc.control.stop(reason="wipe", emergency=True)
        svc.backup.wipe_all(body.include_backups)
        return {"wiped": True}

    return app
