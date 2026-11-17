"""Persist and validate user settings."""

from __future__ import annotations

import json
from typing import Any

from uata.core.settings_model import Settings
from uata.db.database import Database, audit, utcnow

_KEY = "user_settings"


class SettingsService:
    def __init__(self, db: Database):
        self.db = db

    def get(self) -> Settings:
        with self.db.session() as conn:
            row = conn.execute("SELECT value_json FROM settings WHERE key=?", (_KEY,)).fetchone()
        if row is None:
            return Settings()
        stored = json.loads(row[0])
        try:
            return Settings.model_validate(stored)
        except ValueError:
            # Stored settings from an older/newer version: keep valid keys only.
            base = Settings().model_dump()
            base.update({k: v for k, v in stored.items() if k in base})
            return Settings.model_validate(base)

    def update(self, patch: dict[str, Any]) -> Settings:
        """Apply a partial update. Raises ``pydantic.ValidationError`` on bad input."""
        current = self.get().model_dump()
        if "indicators" in patch and isinstance(patch["indicators"], dict):
            patch = {**patch, "indicators": {**current["indicators"], **patch["indicators"]}}
        merged = Settings.model_validate({**current, **patch})
        self._save(merged, changed=sorted(patch))
        return merged

    def reset(self) -> Settings:
        s = Settings()
        self._save(s, changed=["*reset*"])
        return s

    def _save(self, s: Settings, changed: list[str]) -> None:
        with self.db.session() as conn:
            conn.execute(
                "INSERT INTO settings(key, value_json, updated_at) VALUES (?,?,?) "
                "ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
                (_KEY, s.model_dump_json(), utcnow()),
            )
            audit(conn, "user", "settings.update", keys=changed)
