#!/usr/bin/env bash
# Stop the booth display server on this machine.
set -uo pipefail
PORT="${E2_PORT:-8500}"
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null && echo "Stopped server on port ${PORT}." || echo "Nothing listening on port ${PORT}."
else
  pkill -f "uvicorn viz.server:app" && echo "Stopped." || echo "Nothing to stop."
fi
