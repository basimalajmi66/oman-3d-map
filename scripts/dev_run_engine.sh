#!/usr/bin/env bash
# Start the local engine for development (Linux/macOS). Data goes to ./backend/.uata_data
set -euo pipefail
cd "$(dirname "$0")/../backend"
python3 -m uata --data-dir .uata_data "$@"
