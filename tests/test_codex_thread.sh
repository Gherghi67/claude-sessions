#!/usr/bin/env bash
# ABOUTME: Runs the Codex app-server bootstrap protocol tests in the shell gate.
# ABOUTME: Uses fake servers; never launches a model or reads user credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/test_codex_thread.py"
