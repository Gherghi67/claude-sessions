#!/usr/bin/env bash
# ABOUTME: PostToolUseFailure hook that logs failed tool calls for debugging
# ABOUTME: Writes tool name, error, and timestamp to the session log (.cs/local or .cs/private)

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Test before sourcing rather than catching a failed source with ||: under
# bash 3.2, cs's floor, a `.` of a missing file kills a non-interactive shell
# outright and the || never runs. A partial install would then abort the hook
# before its own decline, silently. When the library is absent the fallback
# is the env-only check this guard replaced, so the hook behaves as it used to.
_cs_lib="$(dirname "$0")/cs-resolve.sh"
# cs-shared.sh is build.sh's copy of lib/02-shared.sh: it names the directory
# the log lives in. Same guard, same reasons.
_cs_shared="$(dirname "$0")/cs-shared.sh"
# shellcheck source=cs-resolve.sh
# Parse-check before sourcing: a truncated or corrupt library is readable,
# and sourcing it aborts the hook at the syntax error, before the fallback
# below is even defined. One fork against several the hook already makes.
# errexit is suspended across the source, not just around it: a library that
# parses clean and fails when RUN (an inserted `=======` conflict marker is a
# valid-looking command) fails INSIDE the sourced file, where set -e fires
# before any outer || can catch it. Exit 2 out of a PreToolUse hook is
# Claude Code's blocking code. Whatever the source defined before failing
# still stands; the check below decides whether it is usable.
case $- in *e*) _cs_had_e=1 ;; *) _cs_had_e=0 ;; esac
set +e
[ -r "$_cs_lib" ] && "${BASH:-/bin/bash}" -n "$_cs_lib" 2>/dev/null && . "$_cs_lib"
# shellcheck source=cs-shared.sh
[ -r "$_cs_shared" ] && "${BASH:-/bin/bash}" -n "$_cs_shared" 2>/dev/null && . "$_cs_shared"
if [ "$_cs_had_e" = 1 ]; then set -e; fi
if ! command -v cs_resolve_session >/dev/null 2>&1; then
    cs_resolve_session() {
        [ -n "${CLAUDE_SESSION_NAME:-}" ] && [ -n "${CLAUDE_SESSION_DIR:-}" ]
    }
fi
# Without the library there is no telling whether the session keeps its log in
# a vault, so nothing is logged rather than risk writing it in plaintext.
if ! command -v cs_private_dir >/dev/null 2>&1; then
    cs_private_dir() { return 1; }
fi
# Nor is the failure count written without the library's writer.
if ! command -v cs_write_atomic >/dev/null 2>&1; then
    cs_write_atomic() { return 1; }
fi
# Only run in cs sessions
cs_resolve_session "$INPUT" || exit 0

SESSION_DIR="${CLAUDE_SESSION_DIR:-}"
META_DIR="${CLAUDE_SESSION_META_DIR:-$SESSION_DIR/.cs}"

if [ -z "$SESSION_DIR" ] || [ ! -d "$SESSION_DIR" ]; then
    exit 0
fi

LOG_DIR=$(cs_private_dir "$META_DIR") || exit 0
[ -d "$LOG_DIR" ] || exit 0
LOG_FILE="$LOG_DIR/session.log"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
ERROR=$(echo "$INPUT" | jq -r '.error // "no error message"')

# Truncate error to first line and 200 chars to keep logs readable
# || true protects against SIGPIPE from head closing input early
ERROR_SHORT=$(echo "$ERROR" | head -1 | cut -c1-200 || true)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Tool failure: $TOOL_NAME - $ERROR_SHORT" >> "$LOG_FILE"

# Count failures for the queue circuit breaker. Reset per task by the drain
# (Stop hook); absent or non-numeric reads as 0. Best-effort — this hook
# stays silent and non-blocking no matter what. Two failures landing at once
# can count as one: the breaker is a soft threshold, and a lock on the
# tool-failure path would cost more than the missed increment. Not a defect
# to fix.
{
    FAILS_FILE="$LOG_DIR/failures"
    CUR=$(cat "$FAILS_FILE" 2>/dev/null | tr -d '[:space:]')
    case "$CUR" in ''|*[!0-9]*) CUR=0;; esac
    cs_write_atomic "$FAILS_FILE" printf '%s\n' $((CUR + 1))
} 2>/dev/null || true

exit 0
