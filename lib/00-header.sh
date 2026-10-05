#!/usr/bin/env bash
# ABOUTME: agent-sessions: provider-neutral session manager with git-synced isolated workspaces
# ABOUTME: Creates isolated session workspaces with automatic documentation and file organization

set -euo pipefail

# Configuration
VERSION="2026.10.3"
SESSIONS_ROOT="${CS_SESSIONS_ROOT:-$HOME/.claude-sessions}"
CLAUDE_CODE_BIN="${CLAUDE_CODE_BIN:-claude}"
CODEX_BIN="${CODEX_BIN:-codex}"

REPO_URL="https://github.com/hex/claude-sessions"
RELEASES_BASE="https://github.com/hex/claude-sessions/releases"
CHANGELOG_RAW_URL="https://raw.githubusercontent.com/hex/claude-sessions/main/CHANGELOG.md"

# Deployed-hooks directory; CS_HOOKS_DIR overrides it for tests.
HOOKS_DEPLOY_DIR="${CS_HOOKS_DIR:-$HOME/.claude/hooks/cs}"

# Deployed executables, cs's own configuration and cs's caches. The profile
# launcher points these into its tree while leaving HOME alone; the defaults
# are where a plain install.sh puts them. Exported so the hooks, statusline
# and mods a launch spawns read the same places. Each use site spells its own
# plain-HOME default too: tests source single fragments without this header.
export CS_INSTALL_DIR="${CS_INSTALL_DIR:-$HOME/.local/bin}"
export CS_CONFIG_DIR="${CS_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/cs}"
export CS_CACHE_DIR="${CS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/cs}"
