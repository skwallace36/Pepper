#!/usr/bin/env bash
# Quick health check for the Pepper MCP server.
# Verifies that the server can start and register all tools.
# Usage: scripts/check-mcp.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="$ROOT/.venv/bin/python3"

if [[ ! -x "$PYTHON" ]]; then
    echo "FAIL  Python not found at $PYTHON" >&2
    echo "      Run: make setup  (or python3 -m venv .venv && pip install -e .)" >&2
    exit 1
fi

exec "$PYTHON" "$ROOT/tools/pepper-mcp" --check
