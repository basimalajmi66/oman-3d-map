"""Runtime configuration and on-disk layout for the local engine.

All user data lives under a single *data directory* on the device. Nothing is
uploaded anywhere. The location is resolved in this order:

1. ``UATA_DATA_DIR`` environment variable (used by tests and portable installs)
2. The OS-specific application-data folder:
   - Windows: ``%LOCALAPPDATA%\\UniversalAITradingAssistant``
   - macOS:   ``~/Library/Application Support/UniversalAITradingAssistant``
   - Linux / Android (embedded): ``$XDG_DATA_HOME/universal-ai-trading-assistant``
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path

APP_NAME = "UniversalAITradingAssistant"
ENGINE_VERSION = "0.1.0"
API_VERSION = "1"
DEFAULT_HOST = "127.0.0.1"  # never bind to external interfaces by default
DEFAULT_PORT = 8765


def default_data_dir() -> Path:
    env = os.environ.get("UATA_DATA_DIR")
    if env:
        return Path(env).expanduser().resolve()
    if sys.platform.startswith("win"):
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        return base / APP_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "universal-ai-trading-assistant"


@dataclass(frozen=True)
class Paths:
    """Resolved locations of every on-disk artefact."""

    root: Path

    @property
    def db_file(self) -> Path:
        return self.root / "uata.sqlite3"

    @property
    def files_dir(self) -> Path:
        """Content-addressed store for documents, images and videos."""
        return self.root / "files"

    @property
    def backups_dir(self) -> Path:
        return self.root / "backups"

    @property
    def token_file(self) -> Path:
        """Per-launch API token shared only with the local UI via the file system."""
        return self.root / "api_token"

    def ensure(self) -> "Paths":
        for d in (self.root, self.files_dir, self.backups_dir):
            d.mkdir(parents=True, exist_ok=True)
            _restrict_permissions(d, 0o700)
        return self


def _restrict_permissions(path: Path, mode: int) -> None:
    """Best-effort owner-only permissions (no-op where unsupported, e.g. Windows ACLs)."""
    try:
        os.chmod(path, mode)
    except OSError:
        pass
