#!/usr/bin/env bash
# ABOUTME: Shared lease contract: contention, forced successors, hooks, and supervision.
# ABOUTME: Uses a fake adapter and real child processes without native runtimes.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/15-lock.sh"
source "$SCRIPT_DIR/../lib/16-lifecycle.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../hooks/cs-resolve.sh"

cs_interactive() { return 1; }
warn() { printf '%s\n' "$*" >&2; }

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    export CS_TEST_SESSION_DIR="$TEST_TMPDIR/session"
    export CS_TEST_SOURCE_DIR="$SCRIPT_DIR/.."
    export CS_TEST_WORKER="$TEST_TMPDIR/worker"
    mkdir -p "$HOME" "$CS_TEST_SESSION_DIR/.cs/local"
    unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CLAUDE_PID
    cat > "$TEST_TMPDIR/driver" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/lib/15-lock.sh"
source "$CS_TEST_SOURCE_DIR/lib/16-lifecycle.sh"
source "$CS_TEST_SOURCE_DIR/lib/40-state.sh"
cs_interactive() { return 1; }
warn() { printf '%s\n' "$*" >&2; }
_set_local_state() { printf '%s: %s\n' "$2" "$3" >> "$1"; }
cs_engine_call() {
    printf '%s\n' "$CS_RUN_ID" > "$CS_TEST_SESSION_DIR/run-id"
    cs_run_child "$CS_TEST_WORKER"
}
cs_launch_session claude demo "$CS_TEST_SESSION_DIR" false "${CS_TEST_FORCE:-false}" '' auto
DRIVER
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"
CLAUDE_PID=$$
if cs_is_lead; then printf 'lead\n' > "$CS_TEST_SESSION_DIR/lead"; fi
printf '%s\n' "$$" > "$CS_TEST_SESSION_DIR/child-pid"
printf '%s\n' "$CS_RUN_ID" > "$CS_TEST_SESSION_DIR/child-run-id"
[ "${CS_TEST_STAY:-0}" = 1 ] || exit "${CS_TEST_EXIT:-0}"
trap 'exit 0' TERM
while :; do sleep 0.05; done
WORKER
    chmod +x "$TEST_TMPDIR/driver" "$CS_TEST_WORKER"
}

teardown() {
    if [ -s "$CS_TEST_SESSION_DIR/child-pid" ]; then
        kill -TERM "$(cat "$CS_TEST_SESSION_DIR/child-pid")" 2>/dev/null || true
    fi
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
    unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CLAUDE_PID
    unset CS_TEST_STAY CS_TEST_EXIT CS_TEST_FORCE
}

_wait_for_file() {
    local n=0
    while [ "$n" -lt 100 ]; do
        [ ! -s "$1" ] || return 0
        sleep 0.05
        n=$((n + 1))
    done
    printf 'File did not appear: %s\n' "$1" >&2
    return 1
}

_test_lease() {
    export CS_RUN_ID="$1" CS_RUN_ENGINE=claude CS_RUN_OWNER_PID="$$"
    export CS_LEAD_PID="$$" CLAUDE_PID="$$"
    export CS_SESSION_META_DIR="$CS_TEST_SESSION_DIR/.cs"
}

test_shared_exit_status_and_cleanup() {
    local status=0
    CS_TEST_EXIT=17 "$TEST_TMPDIR/driver" || status=$?
    assert_eq 17 "$status" || return 1
    assert_file_contains "$CS_TEST_SESSION_DIR/lead" lead "supervised native child is the lead" || return 1
    assert_eq "$(cat "$CS_TEST_SESSION_DIR/run-id")" "$(cat "$CS_TEST_SESSION_DIR/child-run-id")" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json" || return 1
}

test_terminal_stdin_reaches_child() {
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
IFS= read -r line
printf '%s\n' "$line" > "$CS_TEST_SESSION_DIR/stdin"
WORKER
    printf 'interactive input\n' | "$TEST_TMPDIR/driver"
    assert_file_contains "$CS_TEST_SESSION_DIR/stdin" 'interactive input'
}

test_competing_launch_cannot_steal_lease() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/first.log" 2>&1 &
    local launcher=$! status=0 old_id
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    old_id=$(cat "$CS_TEST_SESSION_DIR/run-id")
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/second.log" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_eq "$launcher" "$(cat "$CS_TEST_SESSION_DIR/.cs/session.lock")" || return 1
    assert_eq "$old_id" "$(jq -r .run_id "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json")" || return 1
    kill -TERM "$launcher"
    wait "$launcher" || true
}

test_force_successor_rejects_old_cleanup_and_binding_writer() {
    local meta="$CS_TEST_SESSION_DIR/.cs" status=0
    _test_lease old-run
    acquire_session_lock "$meta" false demo
    _test_lease successor-run
    acquire_session_lock "$meta" true demo
    _test_lease old-run
    release_session_lock "$meta"
    assert_exists "$meta/session.lock" || return 1
    assert_eq successor-run "$(jq -r .run_id "$meta/local/run-lease.json")" || return 1
    cs_run_with_lease "$meta" touch "$TEST_TMPDIR/stale-write" || status=$?
    [ "$status" -ne 0 ] || return 1
    assert_not_exists "$TEST_TMPDIR/stale-write" || return 1
    _CS_IS_LEAD=''
    if cs_is_lead; then echo 'stale token incorrectly owns the lead'; return 1; fi
    _test_lease successor-run
    release_session_lock "$meta"
    assert_not_exists "$meta/session.lock"
}

test_inherited_token_does_not_make_headless_child_lead() {
    local meta="$CS_TEST_SESSION_DIR/.cs" probe="$TEST_TMPDIR/lead-probe"
    _test_lease current-run
    acquire_session_lock "$meta" false demo
    cat > "$probe" <<'PROBE'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"
# This shell stands in for the Bash tool. Its child stands in for claude -p.
bash -c 'source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"; source "$CS_TEST_SOURCE_DIR/hooks/cs-resolve.sh"; CLAUDE_PID=$$; if cs_is_lead; then exit 1; else exit 0; fi'
PROBE
    bash "$probe" || return 1
    release_session_lock "$meta"
}

test_session_end_keeps_modern_lease_during_clear() {
    local meta="$CS_TEST_SESSION_DIR/.cs"
    _test_lease current-run
    acquire_session_lock "$meta" false demo
    mkdir -p "$TEST_TMPDIR/hooks"
    cp "$SCRIPT_DIR/../hooks/session-end.sh" "$SCRIPT_DIR/../hooks/cs-resolve.sh" "$TEST_TMPDIR/hooks/"
    cp "$SCRIPT_DIR/../lib/02-shared.sh" "$TEST_TMPDIR/hooks/cs-shared.sh"
    printf '{"session_id":"12345678-1234-1234-1234-123456789abc","reason":"clear"}\n' | \
        CLAUDE_SESSION_NAME=demo CLAUDE_SESSION_DIR="$CS_TEST_SESSION_DIR" \
        CLAUDE_SESSION_META_DIR="$meta" bash "$TEST_TMPDIR/hooks/session-end.sh"
    assert_exists "$meta/session.lock" || return 1
    assert_eq current-run "$(jq -r .run_id "$meta/local/run-lease.json")" || return 1
    release_session_lock "$meta"
}

test_term_stops_child_before_releasing_lease() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -TERM "$launcher"
    wait "$launcher" || status=$?
    assert_eq 143 "$status" || return 1
    if kill -0 "$child" 2>/dev/null; then echo 'native child survived TERM cleanup'; return 1; fi
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/local/run-lease.json"
}

test_guard_is_held_across_callback_and_recovers_after_exit() {
    cat > "$TEST_TMPDIR/guard-holder" <<'HOLDER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
callback() { printf 'ready\n' > "$CS_TEST_SESSION_DIR/guard-ready"; sleep 0.4; }
cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" callback
HOLDER
    bash "$TEST_TMPDIR/guard-holder" &
    local holder=$! status=0
    _wait_for_file "$CS_TEST_SESSION_DIR/guard-ready" || return 1
    local guard="$CS_TEST_SESSION_DIR/.cs/local/run-lease.guard"
    if command -v flock >/dev/null 2>&1; then
        flock -n "$guard" true || status=$?
    else
        lockf -s -k -t 0 "$guard" true || status=$?
    fi
    [ "$status" -ne 0 ] || { echo 'second process acquired active guard'; return 1; }
    wait "$holder"
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/after-guard"
    assert_exists "$TEST_TMPDIR/after-guard"
}

test_killed_launcher_keeps_surviving_native_excluded() {
    CS_TEST_STAY=1 "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0 n=0
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -KILL "$launcher"
    wait "$launcher" 2>/dev/null || true
    kill -0 "$child" 2>/dev/null || { echo 'orphan fixture exited unexpectedly'; return 1; }
    session_is_live "$CS_TEST_SESSION_DIR/.cs" || { echo 'orphan native child not counted live'; return 1; }
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/second.log" 2>&1 || status=$?
    assert_eq 1 "$status" "orphan child must block new unforced launch" || return 1
    kill -TERM "$child"
    while kill -0 "$child" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
    if kill -0 "$child" 2>/dev/null; then echo 'orphan worker did not stop'; return 1; fi
    "$TEST_TMPDIR/driver" || return 1
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock"
}

test_term_escalates_when_native_ignores_it() {
    cat > "$CS_TEST_WORKER" <<'WORKER'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$CS_TEST_SESSION_DIR/child-pid"
while :; do sleep 0.05; done
WORKER
    "$TEST_TMPDIR/driver" > "$TEST_TMPDIR/launch.log" 2>&1 &
    local launcher=$! child status=0 started=$SECONDS
    _wait_for_file "$CS_TEST_SESSION_DIR/child-pid" || return 1
    child=$(cat "$CS_TEST_SESSION_DIR/child-pid")
    kill -TERM "$launcher"
    wait "$launcher" || status=$?
    assert_eq 143 "$status" || return 1
    [ "$((SECONDS - started))" -lt 12 ] || { echo 'TERM escalation exceeded bound'; return 1; }
    if kill -0 "$child" 2>/dev/null; then echo 'TERM-ignoring native survived escalation'; return 1; fi
    assert_not_exists "$CS_TEST_SESSION_DIR/.cs/session.lock"
}

test_guard_released_when_holding_shell_is_killed() {
    cat > "$TEST_TMPDIR/guard-holder" <<'HOLDER'
#!/usr/bin/env bash
source "$CS_TEST_SOURCE_DIR/lib/02-shared.sh"
callback() {
    # $$ remains the parent PID in Bash3 subshells. A child's PPID identifies
    # the actual guard holder without requiring a process-table probe.
    sh -c 'echo "$PPID"' > "$CS_TEST_SESSION_DIR/guard-pid"
    exec 8<> "$CS_TEST_SESSION_DIR/guard-fifo"
    IFS= read -r line <&8
}
cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" callback
HOLDER
    mkfifo "$CS_TEST_SESSION_DIR/guard-fifo"
    bash "$TEST_TMPDIR/guard-holder" > "$TEST_TMPDIR/guard.log" 2>&1 &
    local holder=$! guard_pid
    _wait_for_file "$CS_TEST_SESSION_DIR/guard-pid" || return 1
    guard_pid=$(cat "$CS_TEST_SESSION_DIR/guard-pid")
    kill -KILL "$guard_pid"
    wait "$holder" 2>/dev/null || true
    cs_run_guarded "$CS_TEST_SESSION_DIR/.cs" touch "$TEST_TMPDIR/after-kill"
    assert_exists "$TEST_TMPDIR/after-kill"
}

run_test test_shared_exit_status_and_cleanup
run_test test_terminal_stdin_reaches_child
run_test test_competing_launch_cannot_steal_lease
run_test test_force_successor_rejects_old_cleanup_and_binding_writer
run_test test_inherited_token_does_not_make_headless_child_lead
run_test test_session_end_keeps_modern_lease_during_clear
run_test test_term_stops_child_before_releasing_lease
run_test test_guard_is_held_across_callback_and_recovers_after_exit
run_test test_killed_launcher_keeps_surviving_native_excluded
run_test test_term_escalates_when_native_ignores_it
run_test test_guard_released_when_holding_shell_is_killed
report_results
