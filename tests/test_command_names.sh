#!/usr/bin/env bash
# ABOUTME: Command migration: canonical names, sourceable aliases, canonical-only helper lookup.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/70-statusline.sh"

test_legacy_commands_are_source_compatible_aliases() {
    local name target
    for name in cs cs-secrets cs-codex-thread cs-statusline cs-subagent-statusline; do
        target="ags${name#cs}"
        assert_eq "$target" "$(readlink "$SCRIPT_DIR/../bin/$name")" "legacy target $name" || return 1
        [ -x "$SCRIPT_DIR/../bin/$name" ] || return 1
    done
    assert_eq "$("$CS_BIN" -version)" "$("$SCRIPT_DIR/../bin/cs" -version)" || return 1
    local out
    out=$(CS_STATUSLINE_LIB=1 . "$SCRIPT_DIR/../bin/cs-statusline"; _detect_level; printf '%s' "$LEVEL")
    [ -n "$out" ] || return 1
}

test_codex_discovers_canonical_helper_without_legacy_alias() {
    mkdir -p "$TEST_TMPDIR/canonical commands"
    printf '#!/bin/sh\nexit 0\n' > "$TEST_TMPDIR/canonical commands/ags-codex-thread"
    chmod +x "$TEST_TMPDIR/canonical commands/ags-codex-thread"
    CS_BIN="$TEST_TMPDIR/canonical commands/ags"
    unset AGS_BIN CS_CODEX_THREAD_BIN
    assert_eq "$(cd "$TEST_TMPDIR/canonical commands" && pwd -P)/ags-codex-thread" "$(_codex_thread_helper)"
}

test_statusline_cleanup_handles_both_names_and_preserves_foreign() {
    local prefix file="$TEST_TMPDIR/settings.json"
    for prefix in ags cs; do
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

run_test test_legacy_commands_are_source_compatible_aliases
run_test test_codex_discovers_canonical_helper_without_legacy_alias
run_test test_statusline_cleanup_handles_both_names_and_preserves_foreign
report_results
