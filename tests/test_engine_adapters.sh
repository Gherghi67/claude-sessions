#!/usr/bin/env bash
# ABOUTME: Tests the engine registry, direct adapter dispatch, and neutral session context.
# ABOUTME: A fake adapter verifies the shared contract without native runtimes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/24-engine-adapters.sh"
source "$SCRIPT_DIR/../lib/75-launch.sh"
source "$SCRIPT_DIR/../lib/76-codex.sh"
source "$SCRIPT_DIR/../lib/02-shared.sh"

source "$SCRIPT_DIR/../lib/34-narrative-storage.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/45-migrate.sh"

_cs_fixture_adapter_prepare_workspace() {
    printf '%s\n' "$@" > "$CS_ADAPTER_ARGS"
    return "${CS_ADAPTER_STATUS:-0}"
}

_cs_fixture_adapter_dependencies() {
    printf '%s\n' fixture-native-runtime
}

_cs_fixture_adapter_capabilities() {
    printf '%s\n' launch startup_context
}

_cs_fixture_adapter_launch() {
    printf '%s\n' "$@" > "$CS_ADAPTER_ARGS"
    return "${CS_ADAPTER_STATUS:-0}"
}

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_ADAPTER_ARGS="$TEST_TMPDIR/adapter-args"
    export CS_ADAPTER_STATUS=37
    CS_ENGINE_IDS+=(fixture missing)
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_ADAPTER_ARGS CS_ADAPTER_STATUS
    CS_ENGINE_IDS=(claude codex)
}

# A session directory with both engines bound, as a launch leaves it.
_engine_verb_session() {
    local dir="$TEST_TMPDIR/session"
    mkdir -p "$dir/.cs/local"
    printf 'engine: claude\nclaude_session_id: 11111111-2222-4333-8444-555555555555\n' > "$dir/.cs/local/state"
    printf 'thread-abc\n' > "$dir/.cs/local/codex-thread-id"
    printf '%s\n' "$dir"
}

# A skill's shell inherits the run's engine; the verb names it, the native
# conversation that engine is bound to, and the engine's capabilities.
test_engine_verb_reports_the_running_engine() {
    local dir output
    dir=$(_engine_verb_session)
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=codex "$CS_BIN" -engine 2>&1) \
        || { echo "  FAIL: cs -engine failed: $output"; return 1; }
    assert_output_contains "$output" "engine: codex" "the run's engine wins over the saved one" || return 1
    assert_output_contains "$output" "conversation: thread-abc" "Codex reads its own binding" || return 1
    assert_output_contains "$output" "capabilities: launch exact_resume startup_context" \
        "capabilities come from the adapter" || return 1
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=claude "$CS_BIN" -engine 2>&1) || return 1
    assert_output_contains "$output" "conversation: 11111111-2222-4333-8444-555555555555" \
        "Claude reads claude_session_id" || return 1
    assert_output_contains "$output" "rotation" "Claude lists rotation" || return 1
}

test_engine_verb_falls_back_to_the_saved_engine() {
    local dir output
    dir=$(_engine_verb_session)
    printf 'engine: codex\n' > "$dir/.cs/local/state"
    output=$(env -u CS_RUN_ENGINE CS_SESSION_DIR="$dir" "$CS_BIN" -engine 2>&1) \
        || { echo "  FAIL: cs -engine failed: $output"; return 1; }
    assert_output_contains "$output" "engine: codex" "outside a run the saved preference answers" || return 1
}

test_engine_verb_supports_answers_by_exit_status() {
    local dir output status
    dir=$(_engine_verb_session)
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=claude "$CS_BIN" -engine supports rotation 2>&1) \
        || { echo "  FAIL: Claude must support rotation: $output"; return 1; }
    assert_eq "" "$output" "a supported capability prints nothing" || return 1
    status=0
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=codex "$CS_BIN" -engine supports spawn_brief 2>&1) || status=$?
    assert_eq 1 "$status" "an unsupported capability exits 1" || return 1
    assert_output_contains "$output" "spawn_brief is not supported under codex" "and names both" || return 1
    status=0
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=claude "$CS_BIN" -engine supports 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a missing capability name must be refused"; return 1; }
    assert_output_contains "$output" "Usage: cs -engine supports <capability>" || return 1
}

# Codex runs a skill's commands in a sandbox that can refuse every file write,
# temp files included, and macOS's /bin/bash 3.2 writes each here-string to a
# temp file. The probe a skill runs before an adapter feature has to answer
# without one: it once read no capabilities there and called all of them
# unsupported.
test_engine_verb_supports_answers_without_temp_files() {
    command -v sandbox-exec >/dev/null 2>&1 \
        || { echo "    SKIP (sandbox-exec is macOS-only)"; return 77; }
    local dir output status=0
    dir=$(_engine_verb_session)
    # Every write refused, as in Codex's read-only sandbox. Denying only the
    # temp directories is not enough: bash 3.2 falls back to /var/tmp.
    local policy='(version 1)(allow default)(deny file-write*)(allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper"))'
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=claude \
        sandbox-exec -p "$policy" /bin/bash "$CS_BIN" -engine supports rotation 2>&1) \
        || { echo "  FAIL: with temp files refused, Claude must still support rotation: $output"; return 1; }
    assert_eq "" "$output" "a supported capability prints nothing, warnings included" || return 1
    output=$(CS_SESSION_DIR="$dir" CS_RUN_ENGINE=codex \
        sandbox-exec -p "$policy" /bin/bash "$CS_BIN" -engine supports spawn_brief 2>&1) || status=$?
    assert_eq 1 "$status" "an unsupported capability still exits 1" || return 1
    assert_eq "spawn_brief is not supported under codex in cs" "$output" "with only its own line" || return 1
}

test_engine_verb_refuses_outside_a_session() {
    local output status=0
    output=$(env -u CS_RUN_ENGINE -u CS_SESSION_DIR -u CLAUDE_SESSION_DIR "$CS_BIN" -engine 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: cs -engine outside a session must fail"; return 1; }
    assert_output_contains "$output" "Not in a cs session" || return 1
}

test_builtin_registry_and_safe_names() {
    cs_engine_known claude || { echo '  FAIL: Claude is not registered'; return 1; }
    cs_engine_known codex || { echo '  FAIL: Codex is not registered'; return 1; }
    if cs_engine_known '../claude' || cs_engine_known absent || cs_engine_known 'bad-name'; then
        echo '  FAIL: unregistered or unsafe engine name was accepted'
        return 1
    fi
}

test_fake_adapter_forwards_exact_arguments_and_status() {
    local status=0
    cs_engine_call fixture launch 'two words' '' '*.txt' --tail || status=$?
    assert_eq 37 "$status" 'adapter exit status must be preserved' || return 1
    assert_eq 4 "$(wc -l < "$CS_ADAPTER_ARGS" | tr -d ' ')" 'argument count' || return 1
    assert_eq 'two words' "$(sed -n '1p' "$CS_ADAPTER_ARGS")" 'spaced argument boundary' || return 1
    assert_eq '' "$(sed -n '2p' "$CS_ADAPTER_ARGS")" 'empty argument boundary' || return 1
    assert_eq '*.txt' "$(sed -n '3p' "$CS_ADAPTER_ARGS")" 'glob remains literal' || return 1
    assert_eq --tail "$(sed -n '4p' "$CS_ADAPTER_ARGS")" 'option-like argument preserved' || return 1
}

test_unknown_engine_and_operation_fail_without_invocation() {
    local output status=0
    output=$(cs_engine_call absent launch side-effect 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: unknown engine was accepted'; return 1; }
    assert_output_contains "$output" 'Unknown engine' 'unknown engine diagnostic' || return 1
    assert_not_exists "$CS_ADAPTER_ARGS" 'unknown engine must not invoke fixture' || return 1

    status=0
    output=$(cs_engine_call fixture run side-effect 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: unsupported operation was accepted'; return 1; }
    assert_output_contains "$output" 'Unknown adapter operation' 'unknown operation diagnostic' || return 1
    assert_not_exists "$CS_ADAPTER_ARGS" 'unknown operation must not invoke fixture' || return 1
}

test_missing_handler_fails_without_side_effect() {
    local output status=0
    output=$(cs_engine_call fixture nonexistent 2>&1) || status=$?
    # nonexistent is rejected at the operation boundary before handler lookup.
    [ "$status" -ne 0 ] || { echo '  FAIL: unsupported operation was accepted'; return 1; }
    assert_not_exists "$CS_ADAPTER_ARGS" 'unsupported operation must not invoke fixture' || return 1

    # A supported operation with no implementation reaches the missing-handler path.
    status=0
    output=$(cs_engine_call missing launch side-effect 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: missing handler was accepted'; return 1; }
    assert_output_contains "$output" 'has no launch adapter operation' 'missing handler diagnostic' || return 1
    assert_not_exists "$CS_ADAPTER_ARGS" 'missing handler must not invoke fixture' || return 1
}

test_capabilities_are_exact_and_runtime_independent() {
    cs_engine_supports claude exact_resume || { echo '  FAIL: Claude exact resume capability missing'; return 1; }
    cs_engine_supports claude feature_finish || { echo '  FAIL: Claude feature finish capability missing'; return 1; }
    cs_engine_supports codex startup_context || { echo '  FAIL: Codex startup context capability missing'; return 1; }
    cs_engine_supports codex feature_finish || { echo '  FAIL: Codex feature finish capability missing'; return 1; }
    # The session-manager features skills check before relying on an adapter.
    # Claude hosts all four through its hooks and launch path. Codex hosts
    # rotation (its SessionStart hook and the launch prompt's r); the rest it
    # must decline rather than let a skill half-run.
    local capability
    for capability in rotation spawn_brief memory_index mail_delivery; do
        cs_engine_supports claude "$capability" \
            || { echo "  FAIL: Claude must declare $capability"; return 1; }
    done
    cs_engine_supports codex rotation || { echo "  FAIL: Codex must declare rotation"; return 1; }
    for capability in spawn_brief memory_index mail_delivery; do
        if cs_engine_supports codex "$capability"; then
            echo "  FAIL: Codex must not claim $capability before its adapter hosts it"
            return 1
        fi
    done
    cs_engine_supports fixture startup_context || { echo '  FAIL: fixture capability missing'; return 1; }
    if cs_engine_supports fixture startup; then
        echo '  FAIL: capability check must match a complete line'
        return 1
    fi
}

test_fake_dependencies_do_not_require_native_runtimes() {
    local dependencies status=0
    dependencies=$(cs_engine_call fixture dependencies) || status=$?
    assert_eq 0 "$status" 'fake dependency probe status' || return 1
    assert_eq fixture-native-runtime "$dependencies" 'fake dependency result' || return 1
}

test_shared_context_exports_neutral_and_legacy_names() {
    cs_export_session_context 'a session' '/tmp/session path'
    assert_eq 'a session' "$CS_SESSION_NAME" 'neutral session name' || return 1
    assert_eq '/tmp/session path' "$CS_SESSION_DIR" 'neutral directory' || return 1
    assert_eq '/tmp/session path/.cs' "$CS_SESSION_META_DIR" 'neutral metadata directory' || return 1
    assert_eq "$CS_SESSION_NAME" "$CLAUDE_SESSION_NAME" 'legacy name alias' || return 1
    assert_eq "$CS_SESSION_DIR" "$CLAUDE_SESSION_DIR" 'legacy directory alias' || return 1
    assert_eq "$CS_SESSION_META_DIR" "$CLAUDE_SESSION_META_DIR" 'legacy metadata alias' || return 1
}

echo 'Engine adapter contract tests'
test_fake_adapter_prepares_portable_workspace_without_native_helpers() {
    local workspace="$TEST_TMPDIR/workspace" status=0
    mkdir -p "$workspace"
    printf 'User Claude\n' > "$workspace/CLAUDE.md"
    printf 'User agents\n' > "$workspace/AGENTS.md"
    export CS_ADAPTER_STATUS=0
    create_session_structure "$workspace" fixture || status=$?
    assert_eq 0 "$status" 'core workspace must not need native helper functions' || return 1
    assert_eq "$workspace" "$(sed -n '1p' "$CS_ADAPTER_ARGS")" || return 1
    assert_eq create "$(sed -n '2p' "$CS_ADAPTER_ARGS")" || return 1
    assert_file_exists "$workspace/.cs/README.md" || return 1
    [ -d "$workspace/.cs/plans" ] && [ -d "$workspace/.cs/memory" ] || return 1
    assert_not_exists "$workspace/CLAUDE.local.md" || return 1
    assert_not_exists "$workspace/.claude" || return 1
    assert_eq 'User Claude' "$(cat "$workspace/CLAUDE.md")" || return 1
    assert_eq 'User agents' "$(cat "$workspace/AGENTS.md")" || return 1
    export CS_ADAPTER_STATUS=39
    status=0
    cs_engine_call fixture prepare_workspace "$workspace" migrate || status=$?
    assert_eq 39 "$status" 'workspace adapter errors must propagate'
}

test_neutral_context_refreshes_shared_secret_namespace() {
    export CS_SECRETS_SESSION=stale-parent
    cs_export_session_context 'base@worker' '/tmp/feature'
    assert_eq base "$CS_SECRETS_SESSION" || return 1
    cs_export_session_context 'independent' '/tmp/independent'
    assert_eq independent "$CS_SECRETS_SESSION"
}

run_test test_builtin_registry_and_safe_names
run_test test_fake_adapter_forwards_exact_arguments_and_status
run_test test_unknown_engine_and_operation_fail_without_invocation
run_test test_missing_handler_fails_without_side_effect
run_test test_capabilities_are_exact_and_runtime_independent
run_test test_engine_verb_reports_the_running_engine
run_test test_engine_verb_falls_back_to_the_saved_engine
run_test test_engine_verb_supports_answers_by_exit_status
run_test test_engine_verb_supports_answers_without_temp_files
run_test test_engine_verb_refuses_outside_a_session
run_test test_fake_dependencies_do_not_require_native_runtimes
run_test test_shared_context_exports_neutral_and_legacy_names
run_test test_fake_adapter_prepares_portable_workspace_without_native_helpers
run_test test_neutral_context_refreshes_shared_secret_namespace
report_results
