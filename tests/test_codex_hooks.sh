#!/usr/bin/env bash
# ABOUTME: Tests `cs -codex-hook session-start`, the SessionStart hook cs registers for Codex.
# ABOUTME: Feeds Codex-shaped stdin JSON under a faked run lease; no Codex process runs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

OLD_THREAD=11111111-1111-4111-8111-111111111111
NEW_THREAD=22222222-2222-4222-8222-222222222222
HANDOFF=2026-10-05-continue-the-plan.md

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/local" "$SESSION/.cs/handoffs"
    printf 'engine: codex\n' > "$SESSION/.cs/local/state"
    printf '%s\n' "$OLD_THREAD" > "$SESSION/.cs/local/codex-thread-id"
    # The run lease a supervised cs launch holds: the hook may rebind only
    # for the run that owns the session.
    printf '%s\n' "$$" > "$SESSION/.cs/session.lock"
    jq -n --arg owner "$$" '{run_id: "run-1", engine: "codex", owner_pid: ($owner | tonumber)}' \
        > "$SESSION/.cs/local/run-lease.json"
    export CS_ACTOR=tester
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_ACTOR
}

_handoff() {  # status
    printf -- '---\nparent: %s\ncreated: 2026-10-05T10:00:00Z\npurpose: continue the plan\nstatus: %s\n---\n\n## 1. Next Step\nstatus: unconsumed is quoted here on purpose.\n' \
        "$OLD_THREAD" "$1" > "$SESSION/.cs/handoffs/$HANDOFF"
}

_arm() { printf '%s\n' "$HANDOFF" > "$SESSION/.cs/local/pending-handoff"; }

# Runs the hook the way Codex does: JSON on stdin, inside the launch's env.
_hook() {  # source, [run_id]
    printf '{"session_id":"%s","source":"%s","cwd":"%s","hook_event_name":"SessionStart"}' \
        "$NEW_THREAD" "$1" "$SESSION" \
        | env CS_RUN_ENGINE=codex CS_RUN_ID="${2:-run-1}" CS_RUN_OWNER_PID="$$" \
            CS_SESSION_DIR="$SESSION" CS_SESSION_NAME=demo "$CS_BIN" -codex-hook session-start
}

test_clear_with_an_armed_handoff_rebinds_and_loads_it() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook clear) || { echo "  FAIL: hook exited non-zero"; return 1; }
    assert_eq "$NEW_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" \
        "the next cs launch must resume the conversation /clear opened" || return 1
    printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null \
        || { echo "  FAIL: not a SessionStart hook output: $out"; return 1; }
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "Read .cs/handoffs/$HANDOFF FIRST" "the new conversation is pointed at the handoff" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "narrative.tester.md" "and at its actor's narrative" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.systemMessage')" "Rotation loaded from $HANDOFF" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: consumed$" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^consumed_by: $NEW_THREAD$" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed is quoted here" \
        "only the frontmatter's status line flips" || return 1
    assert_not_exists "$SESSION/.cs/local/pending-handoff" "the marker is spent" || return 1
    jq -e --arg from "$OLD_THREAD" --arg to "$NEW_THREAD" --arg h "$HANDOFF" \
        'select(.event == "rotated") | .engine == "codex" and .from == $from and .to == $to
         and .reason == "handoff" and .handoff == $h and .run_id == "run-1"' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no rotated event with the lineage"; return 1; }
    jq -e --arg id "$NEW_THREAD" 'select(.event == "started") | .engine == "codex" and .session_id == $id and .source == "clear"' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: no started event"; return 1; }
    assert_file_contains "$SESSION/.cs/local/session.log" "Session started (source: clear, ID: $NEW_THREAD)" \
        "the rotate skill finds this conversation's handoffs by this line" || return 1
}

test_clear_without_a_handoff_rebinds_as_a_clean_break() {
    local out
    out=$(_hook clear) || return 1
    assert_eq "$NEW_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_output_contains "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" \
        "--- Fresh Conversation ---" || return 1
    printf '%s' "$out" | jq -e 'has("systemMessage") | not' >/dev/null \
        || { echo "  FAIL: nothing to announce without a rotation"; return 1; }
    jq -e 'select(.event == "rotated") | .reason == "rebind" and (has("handoff") | not)' \
        "$SESSION/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: rebind lineage missing"; return 1; }
}

# A marker naming a spent handoff is stale: the clear is a clean break and the
# marker goes, so no later /clear trips over it.
test_a_stale_marker_is_dropped() {
    _handoff consumed
    _arm
    local out
    out=$(_hook clear) || return 1
    assert_output_contains "$out" "Fresh Conversation" || return 1
    assert_not_exists "$SESSION/.cs/local/pending-handoff" || return 1
}

# Every cs launch reaches Codex as a resume (cs creates the thread first),
# and the launch owns that binding and any rotation it starts. The hook only
# records that the conversation ran here.
test_resume_changes_nothing_but_the_log() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook resume) || return 1
    assert_eq "" "$out" "nothing to inject on a launch" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" "an armed rotation waits for /clear" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed$" || return 1
    assert_file_contains "$SESSION/.cs/local/session.log" "Session started (source: resume, ID: $NEW_THREAD)" || return 1
}

# Only the run that owns the session may move its binding or spend its
# rotation: another Codex process in the same directory is not the launch.
test_a_run_without_the_lease_rebinds_nothing() {
    _handoff unconsumed
    _arm
    local out
    out=$(_hook clear run-other) || return 1
    assert_eq "" "$out" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" || return 1
    assert_file_contains "$SESSION/.cs/handoffs/$HANDOFF" "^status: unconsumed$" || return 1
}

# Not even a stale marker is the outsider's to clear.
test_a_run_without_the_lease_leaves_a_stale_marker() {
    _handoff consumed
    _arm
    _hook clear run-other >/dev/null || return 1
    assert_file_exists "$SESSION/.cs/local/pending-handoff" "only the owning run tidies the session" || return 1
}

# A plain codex run, or a Claude conversation's environment, is not a cs
# Codex launch: the hook stays silent and touches nothing.
test_outside_a_cs_codex_run_the_hook_is_inert() {
    local out status=0
    out=$(printf '{"session_id":"%s","source":"clear"}' "$NEW_THREAD" \
        | env -u CS_RUN_ENGINE -u CS_SESSION_DIR "$CS_BIN" -codex-hook session-start) || status=$?
    assert_eq 0 "$status" || return 1
    assert_eq "" "$out" || return 1
    out=$(printf 'not json' | env CS_RUN_ENGINE=codex CS_SESSION_DIR="$SESSION" "$CS_BIN" -codex-hook session-start) || status=$?
    assert_eq 0 "$status" "a hook must never fail a turn" || return 1
    assert_eq "" "$out" || return 1
    assert_eq "$OLD_THREAD" "$(cat "$SESSION/.cs/local/codex-thread-id")" || return 1
    assert_not_exists "$SESSION/.cs/local/session.log" || return 1
}

test_unknown_hook_event_is_a_usage_error() {
    local status=0 out
    out=$("$CS_BIN" -codex-hook stop </dev/null 2>&1) || status=$?
    assert_eq 2 "$status" || return 1
    assert_output_contains "$out" "Usage: cs -codex-hook session-start" || return 1
}

run_test test_clear_with_an_armed_handoff_rebinds_and_loads_it
run_test test_clear_without_a_handoff_rebinds_as_a_clean_break
run_test test_a_stale_marker_is_dropped
run_test test_resume_changes_nothing_but_the_log
run_test test_a_run_without_the_lease_rebinds_nothing
run_test test_a_run_without_the_lease_leaves_a_stale_marker
run_test test_outside_a_cs_codex_run_the_hook_is_inert
run_test test_unknown_hook_event_is_a_usage_error

report_results
