#!/usr/bin/env bash
# ABOUTME: Verifies acknowledged binding transitions and engine-qualified history.
# ABOUTME: Exercises failed/stale acknowledgements without invoking native engines.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"
source "$SCRIPT_DIR/../lib/54-conversations.sh"

UUID_A=11111111-1111-4111-8111-111111111111
UUID_B=22222222-2222-4222-8222-222222222222

binding_fixture() {
    export CS_SESSION_DIR="$TEST_TMPDIR/session" CS_SESSION_NAME=session
    export CS_SESSION_META_DIR="$CS_SESSION_DIR/.cs"
    export CLAUDE_SESSION_DIR="$CS_SESSION_DIR" CLAUDE_SESSION_NAME=session
    export CLAUDE_SESSION_META_DIR="$CS_SESSION_META_DIR"
    export CS_RUN_ID=run-a CS_RUN_ENGINE=claude CS_RUN_OWNER_PID=$$ CS_LEAD_PID=$$ CLAUDE_PID=$$
    export CS_NO_ROTATION_WAKE=1
    mkdir -p "$CS_SESSION_META_DIR/local"
    printf '%s\n' "$$" > "$CS_SESSION_META_DIR/session.lock"
    jq -nc --arg run_id "$CS_RUN_ID" --argjson owner_pid "$$" \
        '{run_id:$run_id,engine:"claude",owner_pid:$owner_pid}' > "$CS_SESSION_META_DIR/local/run-lease.json"
    cs_binding_write "$CS_SESSION_DIR" claude "$UUID_A"
}

acknowledge() {
    jq -nc --arg id "$1" --arg cwd "$CS_SESSION_DIR" \
        '{session_id:$id,cwd:$cwd,source:"startup"}' \
        | bash "$SCRIPT_DIR/../hooks/session-start.sh" > "$TEST_TMPDIR/hook-output" 2>&1
}

test_stage_preserves_until_acknowledged() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    assert_eq "$UUID_A" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'staging retains old ID' || return 1
    acknowledge "$UUID_B" || return 1
    assert_eq "$UUID_B" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'native acknowledgement commits candidate' || return 1
    assert_not_exists "$CS_SESSION_META_DIR/local/pending-binding-claude.json" 'ack removes pending' || return 1
    local event
    event=$(jq -c 'select(.event == "rotated")' "$CS_SESSION_META_DIR/timeline.jsonl")
    assert_eq explicit-fresh "$(echo "$event" | jq -r .reason)" 'transition retains intent' || return 1
    assert_eq claude "$(echo "$event" | jq -r .engine)" 'lineage qualified by engine' || return 1
    assert_eq run-a "$(echo "$event" | jq -r .run_id)" 'lineage identifies run' || return 1
}

test_wrong_ack_preserves_binding_and_pending() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    acknowledge 33333333-3333-4333-8333-333333333333 || return 1
    assert_eq "$UUID_A" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'wrong acknowledgement rejected' || return 1
    assert_file_exists "$CS_SESSION_META_DIR/local/pending-binding-claude.json" 'pending retained for diagnosis' || return 1
}

test_stale_run_cannot_stage_or_acknowledge() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    # A forced successor took the same workspace while the old native hook was queued.
    jq '.run_id="successor"' "$CS_SESSION_META_DIR/local/run-lease.json" > "$TEST_TMPDIR/lease"
    mv "$TEST_TMPDIR/lease" "$CS_SESSION_META_DIR/local/run-lease.json"
    acknowledge "$UUID_B" || return 1
    assert_eq "$UUID_A" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'stale hook cannot promote' || return 1
    if cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh ""; then
        echo 'FAIL: stale run staged a candidate'; return 1
    fi
}

test_retry_archives_unacknowledged_candidate() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" third-candidate explicit-fresh "" || return 1
    local archived
    archived=$(compgen -G "$CS_SESSION_META_DIR/local/pending-binding-claude.abandoned.*")
    assert_eq "$UUID_B" "$(jq -r .candidate_id "$archived")" 'prior candidate remains recoverable' || return 1
    assert_eq "$UUID_A" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'retry keeps prior acknowledged ID' || return 1
}

test_interrupted_commit_acknowledgement_is_idempotent() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    # Model a process interruption after committing the binding but before
    # writing lineage and retiring its transition record.
    cs_binding_write "$CS_SESSION_DIR" claude "$UUID_B" || return 1
    acknowledge "$UUID_B" || return 1
    assert_eq "$UUID_A" "$(jq -r 'select(.event == "rotated") | .from' "$CS_SESSION_META_DIR/timeline.jsonl")" 'recovered lineage retains predecessor' || return 1
    acknowledge "$UUID_B" || return 1
    assert_eq 1 "$(jq -s '[.[] | select(.event == "rotated")] | length' "$CS_SESSION_META_DIR/timeline.jsonl")" 'repeated ack does not duplicate rotation' || return 1
    assert_not_exists "$CS_SESSION_META_DIR/local/pending-binding-claude.json" 'recovered acknowledgement completes transition' || return 1
}

test_failed_lineage_write_keeps_recovery_record() {
    binding_fixture
    cs_binding_stage "$CS_SESSION_DIR" claude "$UUID_A" "$UUID_B" explicit-fresh "" || return 1
    mkdir "$CS_SESSION_META_DIR/timeline.jsonl"
    acknowledge "$UUID_B" || return 1
    assert_eq "$UUID_B" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'native acknowledgement commits binding' || return 1
    assert_file_exists "$CS_SESSION_META_DIR/local/pending-binding-claude.json" 'failed lineage keeps transition evidence' || return 1
    rmdir "$CS_SESSION_META_DIR/timeline.jsonl"
    acknowledge "$UUID_B" || return 1
    assert_not_exists "$CS_SESSION_META_DIR/local/pending-binding-claude.json" 'retry retires recovered transition' || return 1
    assert_eq "$UUID_A" "$(jq -r 'select(.event == "rotated") | .from' "$CS_SESSION_META_DIR/timeline.jsonl")" 'retry recovers lineage' || return 1
}

test_metadata_update_preserves_concurrent_binding() {
    binding_fixture
    (
        _delayed_binding_write() {
            : > "$TEST_TMPDIR/guard-ready"
            while [ ! -f "$TEST_TMPDIR/allow-write" ]; do sleep 0.02; done
            _cs_set_local_state_unlocked "$CS_SESSION_META_DIR/local/state" claude_session_id "$UUID_B"
        }
        cs_run_guarded "$CS_SESSION_META_DIR" _delayed_binding_write
    ) &
    local binding_pid=$! attempts=0
    while [ ! -f "$TEST_TMPDIR/guard-ready" ] && [ "$attempts" -lt 100 ]; do
        sleep 0.02; attempts=$((attempts + 1))
    done
    if [ ! -f "$TEST_TMPDIR/guard-ready" ]; then
        kill "$binding_pid" 2>/dev/null || true; wait "$binding_pid" 2>/dev/null || true
        echo 'FAIL: binding writer did not acquire guard'; return 1
    fi
    _set_local_state "$CS_SESSION_META_DIR/local/state" claude_session_color blue &
    local metadata_pid=$!
    : > "$TEST_TMPDIR/allow-write"
    wait "$binding_pid" || return 1
    wait "$metadata_pid" || return 1
    assert_eq "$UUID_B" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'metadata writer preserves acknowledged ID' || return 1
    assert_eq blue "$(_read_local_state "$CS_SESSION_META_DIR/local/state" claude_session_color)" 'metadata still updates' || return 1
    _set_local_state_if_absent "$CS_SESSION_META_DIR/local/state" claude_session_id "$UUID_A" || return 1
    assert_eq "$UUID_B" "$(cs_binding_read "$CS_SESSION_DIR" claude)" 'late legacy backfill cannot overwrite binding' || return 1
}

test_history_separates_engines_and_reads_legacy() {
    binding_fixture
    cs_binding_write "$CS_SESSION_DIR" codex "$UUID_A"
    printf '{"ts":"2026-10-01T10:00:00Z","event":"started","session_id":"%s","source":"startup"}\n' "$UUID_A" > "$CS_SESSION_META_DIR/timeline.jsonl"
    _timeline_started "$CS_SESSION_DIR" codex "$UUID_A" startup
    _timeline_started "$CS_SESSION_DIR" codex "$UUID_A" resume
    printf 'torn record\n{"event":"started"}\n' >> "$CS_SESSION_META_DIR/timeline.jsonl"
    local out
    out=$(run_conversations) || return 1
    assert_output_contains "$out" 'claude:11111111  started (startup)' 'legacy records default to Claude' || return 1
    assert_output_contains "$out" 'codex:11111111  started (startup, resumed 1x)' 'Codex resume counted independently' || return 1
    assert_eq 2 "$(printf '%s\n' "$out" | grep -c '\[current\]')" 'each engine has independent current binding' || return 1
}

run_test test_stage_preserves_until_acknowledged
run_test test_wrong_ack_preserves_binding_and_pending
run_test test_stale_run_cannot_stage_or_acknowledge
run_test test_retry_archives_unacknowledged_candidate
run_test test_interrupted_commit_acknowledgement_is_idempotent
run_test test_failed_lineage_write_keeps_recovery_record
run_test test_metadata_update_preserves_concurrent_binding
run_test test_history_separates_engines_and_reads_legacy
report_results
