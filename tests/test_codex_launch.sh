#!/usr/bin/env bash
# ABOUTME: Exercises Codex thread binding, refresh, launch, and shared lock cleanup.
# ABOUTME: Uses isolated fake executables so no real Codex thread is created.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/15-lock.sh"
source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
source "$SCRIPT_DIR/../lib/24-engine-adapters.sh"
source "$SCRIPT_DIR/../lib/36-context.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/77-codex-hooks.sh"

_set_local_state() {  # state key value
    printf '%s: %s\n' "$2" "$3" >> "$1"
}
cs_interactive() { return 1; }
# The launch prompt's palette; empty keeps escape codes out of asserted output.
DIM='' NC='' BOLD='' WHITE='' GREEN='' GOLD='' COMMENT='' ORANGE=''
warn() { printf 'Warning: %s\n' "$1" >&2; }
cs_actor_slug() { printf '%s\n' "${CS_ACTOR:-test-actor}"; }

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    export CS_TEST_SESSION_DIR="$TEST_TMPDIR/session with spaces"
    mkdir -p "$CS_TEST_SESSION_DIR/.cs/local"
    export CS_CODEX_LOG="$TEST_TMPDIR/codex-args"
    export CS_CODEX_ENV="$TEST_TMPDIR/codex-env"
    export CS_HELPER_ARGS="$TEST_TMPDIR/helper-args"
    export CS_HELPER_COUNT="$TEST_TMPDIR/helper-count"
    export CS_THREAD_ID=12345678-1234-1234-1234-123456789abc
    export CS_HELPER_EXIT=0 CS_CODEX_EXIT=0
    export CODEX_BIN="$TEST_TMPDIR/codex with spaces"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/cs-codex-thread"
    export CS_BIN="$SCRIPT_DIR/../bin/cs"
    cat > "$CODEX_BIN" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CS_CODEX_LOG"
env | grep -E '^(CS_SESSION_|CS_ACTOR=|CLAUDE_SESSION_|CLAUDE_CODE_SESSION_ID=|CS_CLAUDE_SESSION_ID=|CS_LEAD_PID=|CLAUDE_PID=)' > "$CS_CODEX_ENV" || true
exit "$CS_CODEX_EXIT"
CODEX
    cat > "$CS_CODEX_THREAD_BIN" <<'HELPER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CS_HELPER_ARGS"
printf 'called\n' >> "$CS_HELPER_COUNT"
[ "$CS_HELPER_EXIT" -eq 0 ] || { echo 'simulated app-server failure' >&2; exit "$CS_HELPER_EXIT"; }
printf '%s\n' "$CS_THREAD_ID"
HELPER
    chmod +x "$CODEX_BIN" "$CS_CODEX_THREAD_BIN"
    unset CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID CODEX_HOME
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CODEX_BIN CS_CODEX_THREAD_BIN CS_TEST_SESSION_DIR CS_CODEX_LOG
    unset CS_CODEX_ENV CS_HELPER_ARGS CS_HELPER_COUNT CS_THREAD_ID
    unset CS_HELPER_EXIT CS_CODEX_EXIT
}

test_new_thread_binding_and_context() {
    local output status=0 binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "first launch failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "new thread binding" || return 1
    assert_eq "--no-daemon" "$(sed -n '1p' "$CS_CODEX_LOG")" "CLI owns thread writer lifetime" || return 1
    assert_eq "resume" "$(sed -n '2p' "$CS_CODEX_LOG")" "CLI resumes exact thread" || return 1
    assert_eq "$CS_THREAD_ID" "$(sed -n '3p' "$CS_CODEX_LOG")" "CLI thread ID" || return 1
    assert_eq "-C" "$(sed -n '4p' "$CS_CODEX_LOG")" "CLI cwd switch" || return 1
    assert_eq "$CS_TEST_SESSION_DIR" "$(sed -n '5p' "$CS_CODEX_LOG")" "CLI cwd with spaces" || return 1
    assert_eq 6 "$(wc -l < "$CS_HELPER_ARGS" | tr -d ' ')" "helper takes three named arguments" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'This context does not request work' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'narrative.test-actor.md' || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'Agent-sessions executable:' || return 1
    assert_output_contains "$output" 'autosave, and task queue integration are unavailable' "feature scope notice" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/state" 'engine: codex' || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" "lock released after CLI exit" || return 1
    assert_output_contains "$(cat "$CS_CODEX_ENV")" 'CS_SESSION_NAME=demo' "neutral identity exported" || return 1
    assert_output_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_SESSION_NAME=demo' "legacy resolver alias exported" || return 1
}

test_resume_refreshes_exact_thread() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf '%s\n' "$CS_THREAD_ID" > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "resume failed: $output" || return 1
    assert_eq "--thread-id" "$(sed -n '7p' "$CS_HELPER_ARGS")" "refresh parameter" || return 1
    assert_eq "$CS_THREAD_ID" "$(sed -n '8p' "$CS_HELPER_ARGS")" "refresh exact ID" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "binding retained" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_failed_refresh_never_starts_fresh() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf '%s\n' "$CS_THREAD_ID" > "$binding"
    export CS_HELPER_EXIT=12
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 12 "$status" "failed refresh preserves helper failure status" || return 1
    assert_output_contains "$output" 'Could not refresh Codex thread' "actionable error" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$binding")" "binding unchanged" || return 1
    assert_not_exists "$CS_CODEX_LOG" "CLI must not launch on refresh failure" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_malformed_binding_rejected_without_helper() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf 'not-a-thread\n' > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 1 "$status" "malformed binding must reject" || return 1
    assert_output_contains "$output" 'Invalid Codex thread binding' "diagnostic" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

# Codex refuses a CODEX_HOME that does not exist, and its app-server then dies
# before the helper can say why. The launch names the directory instead.
test_missing_codex_home_is_named_before_the_helper() {
    local output status=0
    export CODEX_HOME="$TEST_TMPDIR/no such codex home"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    unset CODEX_HOME
    assert_eq 1 "$status" "a missing CODEX_HOME must stop the launch" || return 1
    assert_output_contains "$output" "CODEX_HOME points to $TEST_TMPDIR/no such codex home" "names the directory" || return 1
    assert_output_contains "$output" "codex login" "says what to do next" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_mismatched_refresh_rejected() {
    local binding="$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id" output status=0
    printf 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\n' > "$binding"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 1 "$status" "mismatched helper result must reject" || return 1
    assert_output_contains "$output" 'for bound thread' "diagnostic" || return 1
    assert_not_exists "$CS_CODEX_LOG" "no CLI call" || return 1
    assert_eq aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa "$(cat "$binding")" "binding unchanged" || return 1
}

test_cli_status_and_lock_cleanup() {
    local status=0
    export CS_CODEX_EXIT=27
    launch_codex demo "$CS_TEST_SESSION_DIR" true false > /dev/null 2>&1 || status=$?
    assert_eq 27 "$status" "preserve Codex exit status" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" "cleanup after CLI failure" || return 1
}

test_claude_runtime_binding_isolation() {
    local output status=0
    export CLAUDE_CODE_SESSION_ID=claude-uuid CS_CLAUDE_SESSION_ID=claude-uuid
    export CS_LEAD_PID=999 CLAUDE_PID=999
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "launch failed: $output" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_CODE_SESSION_ID=' "no Claude runtime ID" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CS_CLAUDE_SESSION_ID=' "no CS Claude binding" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CS_LEAD_PID=999' "inherited lead marker replaced by run controller" || return 1
    assert_output_not_contains "$(cat "$CS_CODEX_ENV")" 'CLAUDE_PID=' "no Claude PID" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/claude_session_id" || return 1
}

test_unsupported_finish_before_helper() {
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false feature 2>&1) || status=$?
    assert_eq 1 "$status" "finish unsupported" || return 1
    assert_output_contains "$output" 'only for Claude sessions' "clear diagnostic" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no helper call" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
}

test_live_lock_blocks_launch() {
    local output status=0 lock="$CS_TEST_SESSION_DIR/.cs/session.lock"
    sleep 20 &
    local holder=$!
    printf '%s\n' "$holder" > "$lock"
    RED='' NC='' DIM=''
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_eq 1 "$status" "live lock must reject" || return 1
    assert_output_contains "$output" 'already open' "shared lock diagnostic" || return 1
    assert_eq "$holder" "$(cat "$lock")" "rejected launch keeps owner lock" || return 1
    assert_not_exists "$CS_HELPER_COUNT" "helper not called when locked" || return 1
}

test_helper_resolved_beside_cs() {
    local output status=0
    mkdir -p "$TEST_TMPDIR/installed bin"
    cp "$CS_CODEX_THREAD_BIN" "$TEST_TMPDIR/installed bin/cs-codex-thread"
    export CS_BIN="$TEST_TMPDIR/installed bin/cs"
    unset CS_CODEX_THREAD_BIN
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" true false 2>&1) || status=$?
    assert_eq 0 "$status" "sibling helper lookup failed: $output" || return 1
    assert_eq 1 "$(wc -l < "$CS_HELPER_COUNT" | tr -d ' ')" "helper called once" || return 1
}

test_unarchive_and_actor_override() {
    local output status=0
    printf 'archived\n' > "$CS_TEST_SESSION_DIR/.cs/archived"
    export CS_ACTOR=custom-actor
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "archived launch failed: $output" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/archived" "opening unarchives session" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" 'narrative.custom-actor.md' || return 1
    assert_file_contains "$CS_CODEX_ENV" 'CS_ACTOR=custom-actor' "explicit actor preserved" || return 1
    unset CS_ACTOR
}

test_termination_releases_lock_and_stops_codex() {
    local launcher_script="$TEST_TMPDIR/launch.sh" child_file="$TEST_TMPDIR/codex-child"
    local lock="$CS_TEST_SESSION_DIR/.cs/session.lock" launcher child='' status=0 n
    export CS_TEST_LIB_DIR="$SCRIPT_DIR" CS_CODEX_CHILD_PID="$child_file"
    cat > "$CODEX_BIN" <<'SLEEP_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$CS_CODEX_CHILD_PID"
exec sleep 30
SLEEP_CODEX
    chmod +x "$CODEX_BIN"
    cat > "$launcher_script" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
source "$CS_TEST_LIB_DIR/../lib/02-shared.sh"
source "$CS_TEST_LIB_DIR/../lib/15-lock.sh"
source "$CS_TEST_LIB_DIR/../lib/16-lifecycle.sh"
source "$CS_TEST_LIB_DIR/../lib/24-engine-adapters.sh"
source "$CS_TEST_LIB_DIR/../lib/36-context.sh"
source "$CS_TEST_LIB_DIR/../lib/40-state.sh"
source "$CS_TEST_LIB_DIR/../lib/41-bindings.sh"
source "$CS_TEST_LIB_DIR/../lib/76-codex.sh"
_set_local_state() { printf '%s: %s\n' "$2" "$3" >> "$1"; }
cs_actor_slug() { printf 'test-actor\n'; }
cs_interactive() { return 1; }
warn() { printf 'Warning: %s\n' "$1" >&2; }
launch_codex demo "$CS_TEST_SESSION_DIR" true false
LAUNCHER
    /bin/bash "$launcher_script" > "$TEST_TMPDIR/launcher-output" 2>&1 &
    launcher=$!
    for ((n = 0; n < 100; n++)); do
        [ -f "$lock" ] && [ -f "$child_file" ] && break
        sleep 0.1
    done
    if [ ! -f "$lock" ] || [ ! -f "$child_file" ]; then
        kill "$launcher" 2>/dev/null || true
        wait "$launcher" 2>/dev/null || true
        echo "  FAIL: Codex child did not start: $(cat "$TEST_TMPDIR/launcher-output")"
        return 1
    fi
    child=$(cat "$child_file")
    assert_eq "$launcher" "$(cat "$lock")" "lock belongs to launch shell" || return 1
    kill -TERM "$launcher"
    wait "$launcher" 2>/dev/null || status=$?
    if [ "$status" -ne 143 ]; then
        kill "$child" 2>/dev/null || true
        assert_eq 143 "$status" "TERM exit status" || return 1
    fi
    assert_not_exists "$lock" "TERM releases lock" || return 1
    if kill -0 "$child" 2>/dev/null; then
        kill "$child" 2>/dev/null || true
        echo '  FAIL: Codex child survived launcher termination'
        return 1
    fi
}

test_explicit_fresh_replaces_only_codex_binding() {
    local old_id=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa output status=0
    printf '%s\n' "$old_id" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    printf 'claude_session_id: claude-old\n' > "$CS_TEST_SESSION_DIR/.cs/local/state"
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 0 "$status" "fresh failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" || return 1
    assert_output_not_contains "$(cat "$CS_HELPER_ARGS")" '--thread-id' "fresh creates a native conversation" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/state" 'claude_session_id: claude-old' || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-binding-codex.json" "acknowledged transition cleared" || return 1
    local event
    event=$(jq -c 'select(.event == "rotated")' "$CS_TEST_SESSION_DIR/.cs/timeline.jsonl")
    assert_output_contains "$event" '"engine":"codex"' "qualified lineage" || return 1
    assert_output_contains "$event" "\"from\":\"$old_id\"" "prior binding recorded" || return 1
}

test_failed_fresh_preserves_codex_binding() {
    local old_id=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa output status=0
    printf '%s\n' "$old_id" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    export CS_HELPER_EXIT=12
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 12 "$status" "failed create preserves helper failure status" || return 1
    assert_eq "$old_id" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" "prior conversation recoverable" || return 1
    assert_not_exists "$CS_CODEX_LOG" "invalid preparation prevents native launch" || return 1
}

test_resume_without_binding_does_not_create() {
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing resume must reject" || return 1
    assert_output_contains "$output" 'no recorded Codex conversation' || return 1
    assert_not_exists "$CS_HELPER_COUNT" "no native create on resume" || return 1
}

# A bound Codex thread and a handoff the rotate skill wrote and armed.
ROTATION_OLD_THREAD=99999999-9999-4999-8999-999999999999
ROTATION_HANDOFF=2026-10-05-next-step.md
_rotation_fixture() {  # handoff status
    printf '%s\n' "$ROTATION_OLD_THREAD" > "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id"
    mkdir -p "$CS_TEST_SESSION_DIR/.cs/handoffs"
    printf -- '---\nparent: %s\ncreated: 2026-10-05T10:00:00Z\npurpose: next step\nstatus: %s\n---\n\n## 1. Next Step\n' \
        "$ROTATION_OLD_THREAD" "$1" > "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    printf '%s\n' "$ROTATION_HANDOFF" > "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff"
}

# Launch interactively, answering the prompt with one key.
_launch_answering() {  # key, [intent]
    cs_interactive() { return 0; }
    launch_codex demo "$CS_TEST_SESSION_DIR" false false "" "${2:-auto}" <<< "$1"
}

# r at launch is Codex's other way into a rotation (the first is /clear): a
# fresh thread whose launch context carries the handoff, started with a kick
# so it acts without waiting for a message.
test_r_starts_a_thread_from_the_rotation_handoff() {
    _rotation_fixture unconsumed
    local output status=0 h="$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF"
    output=$(_launch_answering r 2>&1) || status=$?
    assert_eq 0 "$status" "r launch failed: $output" || return 1
    assert_output_contains "$output" "Rotation handoff pending:" || return 1
    assert_output_contains "$output" "from handoff" "the prompt offers r" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" "bound to the new thread" || return 1
    assert_output_not_contains "$(cat "$CS_HELPER_ARGS")" '--thread-id' "r creates a thread" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" "Read .cs/handoffs/$ROTATION_HANDOFF FIRST" \
        "the new thread's context names the handoff" || return 1
    assert_eq "Continue from the pending rotation handoff: read .cs/handoffs/$ROTATION_HANDOFF first." \
        "$(sed -n '6p' "$CS_CODEX_LOG")" "codex resume gets the kick as its starting prompt" || return 1
    assert_file_contains "$h" "^status: consumed$" || return 1
    assert_file_contains "$h" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    jq -e --arg from "$ROTATION_OLD_THREAD" --arg to "$CS_THREAD_ID" --arg h "$ROTATION_HANDOFF" \
        'select(.event == "rotated") | .engine == "codex" and .from == $from and .to == $to
         and .reason == "handoff" and .handoff == $h' \
        "$CS_TEST_SESSION_DIR/.cs/timeline.jsonl" >/dev/null || { echo "  FAIL: rotated lineage missing"; return 1; }
}

# n starts fresh without the handoff, and must disarm the marker, or an
# unrelated /clear later would load a handoff the user just passed on.
test_n_starts_fresh_and_leaves_the_handoff_pending() {
    _rotation_fixture unconsumed
    local output status=0
    output=$(_launch_answering n 2>&1) || status=$?
    assert_eq 0 "$status" "n launch failed: $output" || return 1
    assert_eq "$CS_THREAD_ID" "$(cat "$CS_TEST_SESSION_DIR/.cs/local/codex-thread-id")" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" "n disarms" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: unconsumed$" || return 1
    assert_file_not_contains "$CS_TEST_SESSION_DIR/.cs/local/codex-instructions.md" "Conversation Rotation" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

test_d_discards_the_handoff_then_resumes() {
    _rotation_fixture unconsumed
    export CS_THREAD_ID="$ROTATION_OLD_THREAD"
    local output status=0
    output=$(_launch_answering d 2>&1) || status=$?
    assert_eq 0 "$status" "d launch failed: $output" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: discarded$" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_eq "$ROTATION_OLD_THREAD" "$(sed -n '3p' "$CS_CODEX_LOG")" "resumes the bound thread" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

# Claude's fresh launch consumes an armed marker at SessionStart; an explicit
# Codex --fresh does the same through the launch.
test_explicit_fresh_continues_an_armed_rotation() {
    _rotation_fixture unconsumed
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false "" fresh 2>&1) || status=$?
    assert_eq 0 "$status" "fresh launch failed: $output" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^consumed_by: $CS_THREAD_ID$" || return 1
    assert_output_contains "$(sed -n '6p' "$CS_CODEX_LOG")" "$ROTATION_HANDOFF" "kicked from the handoff" || return 1
}

# Unattended or explicit resume never takes the rotation, so the marker goes.
test_resume_disarms_an_armed_rotation() {
    _rotation_fixture unconsumed
    export CS_THREAD_ID="$ROTATION_OLD_THREAD"
    local output status=0
    output=$(launch_codex demo "$CS_TEST_SESSION_DIR" false false 2>&1) || status=$?
    assert_eq 0 "$status" "resume failed: $output" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/pending-handoff" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/.cs/handoffs/$ROTATION_HANDOFF" "^status: unconsumed$" || return 1
    assert_eq 5 "$(wc -l < "$CS_CODEX_LOG" | tr -d ' ')" "no kick" || return 1
}

echo 'Codex launch tests'
run_test test_explicit_fresh_replaces_only_codex_binding
run_test test_failed_fresh_preserves_codex_binding
run_test test_resume_without_binding_does_not_create
run_test test_r_starts_a_thread_from_the_rotation_handoff
run_test test_n_starts_fresh_and_leaves_the_handoff_pending
run_test test_d_discards_the_handoff_then_resumes
run_test test_explicit_fresh_continues_an_armed_rotation
run_test test_resume_disarms_an_armed_rotation
run_test test_new_thread_binding_and_context
run_test test_resume_refreshes_exact_thread
run_test test_failed_refresh_never_starts_fresh
run_test test_malformed_binding_rejected_without_helper
run_test test_missing_codex_home_is_named_before_the_helper
run_test test_mismatched_refresh_rejected
run_test test_cli_status_and_lock_cleanup
run_test test_claude_runtime_binding_isolation
run_test test_unsupported_finish_before_helper
run_test test_live_lock_blocks_launch
run_test test_helper_resolved_beside_cs
run_test test_unarchive_and_actor_override
run_test test_termination_releases_lock_and_stops_codex
report_results
