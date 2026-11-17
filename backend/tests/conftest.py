import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from uata.api.app import create_app  # noqa: E402
from uata.config import Paths  # noqa: E402

TOKEN = "test-token-123"


@pytest.fixture
def paths(tmp_path) -> Paths:
    return Paths(tmp_path / "data").ensure()


@pytest.fixture
def app(paths):
    return create_app(paths, token=TOKEN)


@pytest.fixture
def client(app) -> TestClient:
    c = TestClient(app)
    c.headers.update({"X-UATA-Token": TOKEN})
    return c


@pytest.fixture
def services(app):
    return app.state.services
