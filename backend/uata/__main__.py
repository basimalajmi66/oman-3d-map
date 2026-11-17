"""Start the local engine: ``python -m uata [--port 8765] [--data-dir PATH]``."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from uata.config import DEFAULT_HOST, DEFAULT_PORT, Paths, default_data_dir


def main() -> None:
    parser = argparse.ArgumentParser(prog="uata-engine", description=__doc__)
    parser.add_argument("--port", type=int, default=int(os.environ.get("UATA_PORT", DEFAULT_PORT)))
    parser.add_argument("--data-dir", type=Path, default=None)
    args = parser.parse_args()

    import uvicorn

    from uata.api.app import create_app

    paths = Paths(args.data_dir.resolve() if args.data_dir else default_data_dir())
    app = create_app(paths)
    print(f"UATA engine: data dir = {paths.root}")
    # Loopback only: the engine is never reachable from the network.
    uvicorn.run(app, host=DEFAULT_HOST, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
