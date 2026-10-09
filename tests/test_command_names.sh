#!/usr/bin/env bash
# ABOUTME: Helper lookup beside the running cs, and statusline cleanup that keeps a foreign status line.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
# The statusline cleanup rewrites settings through cs_write_atomic.
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/70-statusline.sh"

test_codex_finds_the_thread_helper_beside_cs() {
    mkdir -p "$TEST_TMPDIR/install dir"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/install dir/cs-codex-thread"
    chmod +x "$TEST_TMPDIR/install dir/cs-codex-thread"
    CS_BIN="$TEST_TMPDIR/install dir/cs"
    unset CS_CODEX_THREAD_BIN
    assert_eq "$(cd "$TEST_TMPDIR/install dir" && pwd -P)/cs-codex-thread" "$(_codex_thread_helper)"
}

test_statusline_cleanup_removes_cs_and_preserves_foreign() {
    local prefix file="$TEST_TMPDIR/settings.json"
    for prefix in cs; do
        jq -n --arg sl "/bin/$prefix-statusline" --arg sub "/bin/$prefix-subagent-statusline" \
            '{statusLine: {command: $sl}, subagentStatusLine: {command: $sub}, keep: true}' > "$file"
        _strip_statusline_registration "$file" || return 1
        _strip_subagent_statusline_registration "$file" || return 1
        assert_eq true "$(jq -r '.keep and (has("statusLine") | not) and (has("subagentStatusLine") | not)' "$file")" || return 1
    done
    printf '%s\n' '{"statusLine":{"command":"/bin/custom-statusline"},"keep":true}' > "$file"
    local before status=0
    before="$(cat "$file")"
    _strip_statusline_registration "$file" || status=$?
    assert_eq 1 "$status" || return 1
    assert_eq "$before" "$(cat "$file")"
}

run_test test_codex_finds_the_thread_helper_beside_cs
run_test test_statusline_cleanup_removes_cs_and_preserves_foreign
report_results
