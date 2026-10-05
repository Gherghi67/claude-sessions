#!/usr/bin/env bash
# ABOUTME: Exercises runtime selection, precedence, and dependency isolation through cs.
# ABOUTME: Uses temporary fake engines and Codex helper to avoid real launches.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1
    export CS_NO_FUNCTION_HOOKS=1
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/claude"
    export CODEX_BIN="$TEST_TMPDIR/bin/codex"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/bin/cs-codex-thread"
    export CS_CLAUDE_LOG="$TEST_TMPDIR/claude.log"
    export CS_CLAUDE_ENV="$TEST_TMPDIR/claude.env"
    export CS_CODEX_LOG="$TEST_TMPDIR/codex.log"
    export CS_HELPER_LOG="$TEST_TMPDIR/helper.log"
    export CS_TEST_START_HOOK="$SCRIPT_DIR/../hooks/session-start.sh"
    mkdir -p "$HOME" "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR" "$TEST_TMPDIR/bin"

    cat > "$CLAUDE_CODE_BIN" <<'CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_CLAUDE_LOG"
env | grep -E '^(CS_SESSION_|CLAUDE_SESSION_)' > "$CS_CLAUDE_ENV"
uuid=""
while [ "$#" -gt 0 ]; do
    case "$1" in --session-id|--resume) uuid="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$uuid" ]; then
    jq -nc --arg session_id "$uuid" --arg cwd "$CS_SESSION_DIR" \
        '{session_id:$session_id,cwd:$cwd,source:"startup"}' \
        | CLAUDE_PID=$$ bash "$CS_TEST_START_HOOK" >/dev/null
fi
exit 0
CLAUDE
    cat > "$CODEX_BIN" <<'CODEX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_CODEX_LOG"
exit 0
CODEX
    cat > "$CS_CODEX_THREAD_BIN" <<'HELPER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CS_HELPER_LOG"
thread_id=12345678-1234-1234-1234-123456789abc
while [ "$#" -gt 0 ]; do
    if [ "$1" = --thread-id ]; then
        thread_id="$2"
        shift 2
    else
        shift
    fi
done
printf '%s\n' "$thread_id"
HELPER
    chmod +x "$CLAUDE_CODE_BIN" "$CODEX_BIN" "$CS_CODEX_THREAD_BIN"
    unset XDG_CONFIG_HOME
    unset CS_DEFAULT_ENGINE CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CS_LEAD_PID CLAUDE_PID
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TRANSCRIPTS_DIR CS_NO_UPDATE_CHECK CS_NO_ITERM2
    unset CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN CODEX_BIN CS_CODEX_THREAD_BIN
    unset CS_CLAUDE_LOG CS_CLAUDE_ENV CS_CODEX_LOG CS_HELPER_LOG CS_DEFAULT_ENGINE
}

_engine_session_dir() {
    printf '%s/%s\n' "$CS_SESSIONS_ROOT" "$1"
}

test_invalid_engine_values_fail_before_session_creation() {
    local output status=0
    output=$("$CS_BIN" invalid-engine --engine 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: missing engine value should fail'; return 1; }
    assert_output_contains "$output" '--engine needs claude or codex' "missing-value diagnostic" || return 1
    assert_not_exists "$(_engine_session_dir invalid-engine)" "missing value must not create a session" || return 1

    status=0
    output=$("$CS_BIN" invalid-engine --engine=wat 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: unknown engine should fail'; return 1; }
    assert_output_contains "$output" '--engine needs claude or codex' "unknown-value diagnostic" || return 1
    assert_not_exists "$(_engine_session_dir invalid-engine)" "invalid value must not create a session" || return 1
}

test_default_launch_remains_claude() {
    local output status=0 session_dir
    output=$("$CS_BIN" old-session 2>&1) || status=$?
    session_dir=$(_engine_session_dir old-session)
    assert_eq 0 "$status" "default launch failed: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "legacy default launches Claude" || return 1
    assert_file_not_exists "$CS_CODEX_LOG" "default launch must not start Codex" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: claude' "Claude preference recorded" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" '^CS_SESSION_NAME=old-session$' "Claude receives neutral session identity" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" "^CS_SESSION_DIR=$session_dir$" "Claude receives neutral workspace" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" "^CS_SESSION_META_DIR=$session_dir/.cs$" "Claude receives neutral metadata" || return 1
    assert_file_contains "$CS_CLAUDE_ENV" '^CLAUDE_SESSION_NAME=old-session$' "Claude retains legacy identity alias" || return 1
}

test_environment_default_selects_codex() {
    local output status=0 session_dir
    export CS_DEFAULT_ENGINE=codex
    # Codex selection must not require the Claude executable to exist.
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/no-claude"
    output=$("$CS_BIN" codex-default 2>&1) || status=$?
    session_dir=$(_engine_session_dir codex-default)
    assert_eq 0 "$status" "Codex default launch failed: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" 'resume 12345678-1234-1234-1234-123456789abc' "environment default launches Codex" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: codex' "Codex preference recorded" || return 1
    assert_file_not_exists "$CS_CLAUDE_LOG" "Codex launch must not invoke Claude" || return 1
}

test_stored_engine_wins_and_explicit_claude_keeps_codex_binding() {
    local output status=0 session_dir binding thread_id
    export CS_DEFAULT_ENGINE=codex
    output=$("$CS_BIN" remembered 2>&1) || status=$?
    session_dir=$(_engine_session_dir remembered)
    binding="$session_dir/.cs/local/codex-thread-id"
    assert_eq 0 "$status" "initial Codex launch failed: $output" || return 1
    thread_id=$(cat "$binding")

    # A saved Codex preference overrides the environment default. Then an
    # explicit Claude launch overrides that choice without deleting Codex's
    # independent native conversation binding.
    export CS_DEFAULT_ENGINE=claude
    output=$("$CS_BIN" remembered 2>&1) || status=$?
    assert_eq 0 "$status" "saved preference launch failed: $output" || return 1
    assert_eq 2 "$(wc -l < "$CS_HELPER_LOG" | tr -d ' ')" "stored Codex preference selected" || return 1

    status=0
    output=$(printf 'n\n' | "$CS_BIN" remembered --engine=claude 2>&1) || status=$?
    assert_eq 0 "$status" "explicit Claude override failed: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "explicit option launches Claude" || return 1
    assert_eq "$thread_id" "$(cat "$binding")" "Claude override preserves Codex binding" || return 1
    assert_file_contains "$session_dir/.cs/local/state" 'engine: claude' "successful explicit choice becomes preference" || return 1
}

test_explicit_codex_works_without_claude_and_claude_without_codex() {
    local output status=0
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/no-claude"
    output=$("$CS_BIN" only-codex --engine codex 2>&1) || status=$?
    assert_eq 0 "$status" "Codex should not require Claude: $output" || return 1
    assert_file_contains "$CS_CODEX_LOG" 'resume 12345678-1234-1234-1234-123456789abc' "Codex launch succeeded" || return 1

    export CODEX_BIN="$TEST_TMPDIR/bin/no-codex"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/claude"
    status=0
    output=$("$CS_BIN" only-claude --engine claude 2>&1) || status=$?
    assert_eq 0 "$status" "Claude should not require Codex: $output" || return 1
    assert_file_contains "$CS_CLAUDE_LOG" 'session-id' "Claude launch succeeded" || return 1
    assert_not_exists "$(_engine_session_dir only-claude)/.cs/local/codex-thread-id" "Claude launch must not bind Codex" || return 1
}

test_codex_finish_is_rejected_before_mutation() {
    local output status=0
    export CS_DEFAULT_ENGINE=codex
    output=$("$CS_BIN" base -finish feature 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo '  FAIL: Codex must reject -finish'; return 1; }
    assert_output_contains "$output" '-finish requires Claude' "clear unsupported-feature error" || return 1
    assert_not_exists "$(_engine_session_dir base)" "unsupported finish must not create a session" || return 1
    assert_file_not_exists "$CS_HELPER_LOG" "unsupported finish must not start the Codex helper" || return 1
}

_assert_codex_only_workspace() {
    assert_not_exists "$1/CLAUDE.local.md" "Codex must not write Claude instructions" || return 1
    assert_not_exists "$1/.claude" "Codex must not configure Claude" || return 1
    assert_file_not_contains "$1/.cs/local/state" 'claude_session_' "Codex must not allocate Claude identity" || return 1
    [ -d "$1/.cs/memory" ] && [ -d "$1/.cs/plans" ] \
        || { echo "  FAIL: portable memory and plans storage is missing"; return 1; }
}

test_codex_create_and_resume_do_not_prepare_claude() {
    local output session_dir
    output=$("$CS_BIN" neutral --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir neutral)
    _assert_codex_only_workspace "$session_dir" || return 1
    output=$("$CS_BIN" neutral 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$session_dir" || return 1
    assert_not_exists "$HOME/.claude" "Codex must not touch native Claude memory"
}

test_codex_adopt_preserves_user_instructions_and_configuration() {
    local project="$TEST_TMPDIR/project" output
    mkdir -p "$project/.claude"
    printf 'User agents\n' > "$project/AGENTS.md"
    printf 'User Claude\n' > "$project/CLAUDE.md"
    printf 'User local Claude\n' > "$project/CLAUDE.local.md"
    printf '{"custom":true}\n' > "$project/.claude/settings.local.json"
    output=$(cd "$project" && "$CS_BIN" -adopt adopted --engine codex 2>&1) || { echo "$output"; return 1; }
    assert_eq 'User agents' "$(cat "$project/AGENTS.md")" || return 1
    assert_eq 'User Claude' "$(cat "$project/CLAUDE.md")" || return 1
    assert_eq 'User local Claude' "$(cat "$project/CLAUDE.local.md")" || return 1
    assert_eq '{"custom":true}' "$(cat "$project/.claude/settings.local.json")" || return 1
    assert_file_not_contains "$project/.cs/local/state" 'claude_session_' || return 1
    output=$("$CS_BIN" adopted 2>&1) || { echo "$output"; return 1; }
    assert_eq 'User local Claude' "$(cat "$project/CLAUDE.local.md")" || return 1
    assert_eq '{"custom":true}' "$(cat "$project/.claude/settings.local.json")"
}

test_codex_worktree_then_claude_prepares_only_on_switch() {
    local output base feature
    output=$("$CS_BIN" tree-base --engine codex 2>&1) || { echo "$output"; return 1; }
    base=$(_engine_session_dir tree-base)
    output=$("$CS_BIN" tree-base@worker --engine codex 2>&1) || { echo "$output"; return 1; }
    feature=$(_engine_session_dir tree-base@worker)
    _assert_codex_only_workspace "$feature" || return 1
    output=$(printf 'n\n' | "$CS_BIN" tree-base@worker --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_exists "$feature/CLAUDE.local.md" || return 1
    assert_file_exists "$feature/.claude/settings.local.json" || return 1
    assert_file_contains "$feature/.cs/local/state" 'claude_session_id:' || return 1
    assert_file_exists "$feature/.cs/local/codex-thread-id" || return 1
    _assert_codex_only_workspace "$base"
}

test_neutral_session_environment_drives_shared_commands() {
    local output session_dir
    output=$("$CS_BIN" ambient --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir ambient)
    output=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CS_SESSION_NAME=ambient CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" \
        "$CS_BIN" -status 'Working with Codex' 2>&1) || { echo "$output"; return 1; }
    assert_eq 'Working with Codex' "$(cat "$session_dir/.cs/local/presence")" || return 1
    printf 'neutral-actor\n' > "$session_dir/.cs/local/identity"
    output=$(env -u CLAUDE_SESSION_NAME -u CLAUDE_SESSION_DIR -u CLAUDE_SESSION_META_DIR \
        CS_SESSION_NAME=ambient CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" \
        "$CS_BIN" -whoami 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'actor: neutral-actor' 
}

test_sole_installed_codex_adapter_is_default() {
    local output
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    mkdir -p "$HOME/.local/bin"
    printf 'codex\n' > "$HOME/.local/bin/.cs-install-engines"
    output=$("$CS_BIN" installed-default 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$(_engine_session_dir installed-default)" || return 1
    unset XDG_CONFIG_HOME
}

test_sole_installed_codex_adapter_is_read_from_the_install_dir() {
    local output
    export XDG_CONFIG_HOME="$TEST_TMPDIR/config"
    # The profile launcher names its own install dir while HOME stays the
    # user's: the stable install's record (claude) must not decide the engine.
    mkdir -p "$HOME/.local/bin" "$TEST_TMPDIR/profile-bin"
    printf 'claude\n' > "$HOME/.local/bin/.cs-install-engines"
    printf 'codex\n' > "$TEST_TMPDIR/profile-bin/.cs-install-engines"
    output=$(CS_INSTALL_DIR="$TEST_TMPDIR/profile-bin" "$CS_BIN" profile-default 2>&1) || { echo "$output"; return 1; }
    _assert_codex_only_workspace "$(_engine_session_dir profile-default)" || return 1
    unset XDG_CONFIG_HOME
}

test_codex_doctor_reports_capability_gaps_without_claude_checks() {
    local output session_dir
    output=$("$CS_BIN" diagnostics --engine codex 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir diagnostics)
    output=$(CS_SESSION_DIR="$session_dir" CS_SESSION_META_DIR="$session_dir/.cs" "$CS_BIN" -doctor 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$output" 'Codex integration capabilities' || return 1
    assert_output_contains "$output" 'usage observations are unavailable' || return 1
    if [[ "$output" == *'settings.json'* || "$output" == *'hooks not registered'* ]]; then
        echo '  FAIL: Codex diagnostics requested Claude configuration'; return 1
    fi
}

test_claude_adoption_preserves_user_local_instructions() {
    local project="$TEST_TMPDIR/claude-project" output
    mkdir -p "$project"
    printf 'User local instructions\n' > "$project/CLAUDE.local.md"
    printf 'User agents\n' > "$project/AGENTS.md"
    output=$(cd "$project" && "$CS_BIN" -adopt claude-adopted --engine claude 2>&1) || { echo "$output"; return 1; }
    assert_file_contains "$project/CLAUDE.local.md" '^User local instructions$' || return 1
    assert_file_contains "$project/CLAUDE.local.md" 'cs:session-protocol' || return 1
    assert_eq 'User agents' "$(cat "$project/AGENTS.md")"
}

test_engine_roundtrip_resumes_each_acknowledged_binding() {
    local output session_dir claude_id codex_id
    output=$("$CS_BIN" roundtrip --engine claude 2>&1) || { echo "$output"; return 1; }
    session_dir=$(_engine_session_dir roundtrip)
    claude_id=$(awk '/^claude_session_id:/ {print $2; exit}' "$session_dir/.cs/local/state")
    output=$("$CS_BIN" roundtrip --engine codex 2>&1) || { echo "$output"; return 1; }
    codex_id=$(cat "$session_dir/.cs/local/codex-thread-id")
    output=$("$CS_BIN" roundtrip --engine claude --resume </dev/null 2>&1) || { echo "$output"; return 1; }
    assert_eq "--name roundtrip --resume $claude_id" "$(tail -1 "$CS_CLAUDE_LOG" | sed 's@ /color.*@@')" "returning Claude resumes its exact ID" || return 1
    output=$("$CS_BIN" roundtrip --engine codex --resume </dev/null 2>&1) || { echo "$output"; return 1; }
    assert_output_contains "$(tail -1 "$CS_HELPER_LOG")" "--thread-id $codex_id" "returning Codex refreshes its exact ID" || return 1
    assert_eq "$claude_id" "$(awk '/^claude_session_id:/ {print $2; exit}' "$session_dir/.cs/local/state")" "engine switches preserve Claude identity" || return 1
    assert_eq "$codex_id" "$(cat "$session_dir/.cs/local/codex-thread-id")" "engine switches preserve Codex identity" || return 1
}

test_launch_intent_flags_validate_before_creation() {
    local output status=0
    output=$("$CS_BIN" missing --fresh --resume 2>&1) || status=$?
    assert_eq 1 "$status" "conflicting intent rejected" || return 1
    assert_output_contains "$output" '--fresh and --resume cannot be combined' || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/missing" "conflicting flags do not create session" || return 1
    status=0
    output=$("$CS_BIN" missing --engine codex --resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing session resume rejected" || return 1
    assert_output_contains "$output" 'does not exist' || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/missing" "resume does not create workspace" || return 1
}

test_resume_missing_binding_does_not_migrate_or_allocate() {
    local output status=0 session_dir="$CS_SESSIONS_ROOT/unbound"
    mkdir -p "$session_dir/.cs/local"
    printf 'engine: codex\n' > "$session_dir/.cs/local/state"
    output=$("$CS_BIN" unbound --engine claude --resume 2>&1) || status=$?
    assert_eq 1 "$status" "missing binding resume rejected" || return 1
    assert_output_contains "$output" 'no recorded claude conversation' || return 1
    assert_file_not_contains "$session_dir/.cs/local/state" 'claude_session_id:' "no migration allocation" || return 1
    assert_not_exists "$session_dir/CLAUDE.local.md" "no native preparation" || return 1
}

echo 'Engine selection tests'
run_test test_engine_roundtrip_resumes_each_acknowledged_binding
run_test test_launch_intent_flags_validate_before_creation
run_test test_resume_missing_binding_does_not_migrate_or_allocate
run_test test_invalid_engine_values_fail_before_session_creation
run_test test_default_launch_remains_claude
run_test test_environment_default_selects_codex
run_test test_stored_engine_wins_and_explicit_claude_keeps_codex_binding
run_test test_explicit_codex_works_without_claude_and_claude_without_codex
run_test test_codex_finish_is_rejected_before_mutation
run_test test_codex_create_and_resume_do_not_prepare_claude
run_test test_codex_adopt_preserves_user_instructions_and_configuration
run_test test_codex_worktree_then_claude_prepares_only_on_switch
run_test test_neutral_session_environment_drives_shared_commands
run_test test_sole_installed_codex_adapter_is_default
run_test test_sole_installed_codex_adapter_is_read_from_the_install_dir
run_test test_codex_doctor_reports_capability_gaps_without_claude_checks
run_test test_claude_adoption_preserves_user_local_instructions
report_results
