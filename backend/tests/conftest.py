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


class FakeCapturer:
    """Stands in for the OS screenshot API in tests."""

    def __init__(self):
        self.image = None
        self.calls = []
        self.fail = None

    def grab(self, region):
        from uata.vision.capture import CaptureUnavailable
        self.calls.append(region)
        if self.fail:
            raise CaptureUnavailable(self.fail)
        if self.image is None:
            from uata.vision.synthetic import random_walk_ohlc, render_chart
            self.image = render_chart(random_walk_ohlc(50, seed=11), style="dark_tv").image
        return self.image


@pytest.fixture
def capturer():
    return FakeCapturer()


@pytest.fixture
def app(paths, capturer):
    application = create_app(paths, token=TOKEN, capturer=capturer)
    yield application
    # stop background work so it cannot leak CPU into later tests
    svc = application.state.services
    svc.watcher.stop()
    svc.companion.stop()
    for sid in list(svc.videos._queue) + ([svc.videos._running] if svc.videos._running else []):
        svc.videos.wait(sid, 120)


@pytest.fixture
def client(app) -> TestClient:
    c = TestClient(app)
    c.headers.update({"X-UATA-Token": TOKEN})
    return c


@pytest.fixture
def services(app):
    return app.state.services
