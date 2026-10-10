#!/usr/bin/env bash
# ABOUTME: cs -switch and --from-handoff: the verb's refusals and pending-switch file, the
# ABOUTME: launch flag on both engines, and the relaunch under the other engine after the CLI exits.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

HANDOFF=2026-10-07-switch.md

# Stub engines record each call's argv (one per line) and the values of the
# variables a relaunch must not inherit. Behaviour comes from a one-shot plan
# file the test writes before the launch it is meant for: arm a handoff (what
# rotate's steps leave), run cs -switch from inside the run, simulate a
# /clear, exit with a status. A one-shot <engine>.fail-early file holding a
# status makes the next call exit with it before its conversation starts
# (no SessionStart): a resume Claude Code refuses, a Codex that cannot start.
_write_stubs() {
    local stub="$TEST_TMPDIR/bin"
    mkdir -p "$stub" "$CS_STUB_DIR"
    cat > "$CS_STUB_DIR/record" <<'REC'
#!/usr/bin/env bash
# record <engine> args...: argv and selected environment of one call. The
# stub passes its own parent as STUB_PPID: this script's parent is the stub.
engine="$1"; shift
n=$(( $(cat "$CS_STUB_DIR/$engine.calls" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$CS_STUB_DIR/$engine.calls"
printf '%s\n' "$@" > "$CS_STUB_DIR/$engine.args.$n"
{
    printf 'PPID=%s\n' "$STUB_PPID"
    printf 'UMASK=%s\n' "$(umask)"
    for v in CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CS_FRESH_REBIND \
        CS_CLAUDE_SESSION_ID CS_SESSION_NAME CS_SESSION_DIR EDITOR CS_REAL_EDITOR \
        CLAUDE_CODE_TMUX_TRUECOLOR CLAUDE_CODE_TASK_LIST_ID name target mode from; do
        if [ -n "${!v+x}" ]; then printf '%s=%s\n' "$v" "${!v}"; else printf '%s unset\n' "$v"; fi
    done
} > "$CS_STUB_DIR/$engine.env.$n"
REC
    cat > "$CS_STUB_DIR/arm-handoff" <<'ARM'
#!/usr/bin/env bash
# arm-handoff <basename>: the handoff and marker rotate's steps 1-9 leave.
meta="$CS_SESSION_DIR/.cs"
if [ -d "$meta/private" ]; then
    dir="$meta/private/handoffs"; marker="$meta/private/pending-handoff"
else
    dir="$meta/handoffs"; marker="$meta/local/pending-handoff"
fi
mkdir -p "$dir"
printf -- '---\nparent: 11111111-1111-4111-8111-111111111111\ncreated: 2026-10-07T10:00:00Z\npurpose: switch test\nstatus: unconsumed\n---\n\n## 7. Next Step\nContinue the switch test.\n' > "$dir/$1"
printf '%s\n' "$1" > "$marker"
ARM
    cat > "$CS_STUB_DIR/plan" <<'PLAN'
#!/usr/bin/env bash
# plan <engine>: run the one-shot plan for this engine, if any; prints the exit status.
plan="$CS_STUB_DIR/$1.plan"
[ -f "$plan" ] || { echo 0; exit 0; }
. "$plan"
rm -f "$plan"
[ -z "${PLAN_HANDOFF:-}" ] || "$CS_STUB_DIR/arm-handoff" "$PLAN_HANDOFF"
if [ -n "${PLAN_SWITCH+x}" ]; then
    # shellcheck disable=SC2086
    "$CS_BIN" -switch $PLAN_SWITCH > "$CS_STUB_DIR/switch.out" 2>&1 || echo "switch exit $?" >> "$CS_STUB_DIR/switch.out"
fi
if [ -n "${PLAN_RAW_SWITCH:-}" ]; then
    printf '%b' "$PLAN_RAW_SWITCH" > "$CS_SESSION_DIR/.cs/local/pending-switch"
fi
# Anything else the run leaves behind (a file an open step will trip on).
[ -z "${PLAN_CMD:-}" ] || eval "$PLAN_CMD"
if [ -n "${PLAN_CLEAR:-}" ]; then
    if [ "$1" = claude ]; then
        jq -nc --arg id 99999999-9999-4999-8999-999999999999 --arg cwd "$CS_SESSION_DIR" \
            '{session_id:$id,cwd:$cwd,source:"clear",hook_event_name:"SessionStart"}' \
            | CLAUDE_PID=$PPID bash "$CS_TEST_START_HOOK" >/dev/null 2>&1
    else
        jq -nc --arg id 99999999-9999-4999-8999-999999999999 '{session_id:$id,source:"clear"}' \
            | "$CS_BIN" -codex-hook session-start >/dev/null 2>&1
    fi
fi
echo "${PLAN_EXIT:-0}"
PLAN
    cat > "$stub/claude" <<'CLAUDE'
#!/usr/bin/env bash
STUB_PPID=$PPID "$CS_STUB_DIR/record" claude "$@"
if [ -f "$CS_STUB_DIR/claude.fail-early" ]; then
    rc=$(cat "$CS_STUB_DIR/claude.fail-early"); rm -f "$CS_STUB_DIR/claude.fail-early"; exit "$rc"
fi
uuid="" source=startup
while [ "$#" -gt 0 ]; do
    case "$1" in
        --session-id) uuid="$2"; shift 2 ;;
        --resume) uuid="$2"; source=resume; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "$uuid" ]; then
    jq -nc --arg id "$uuid" --arg cwd "$CS_SESSION_DIR" --arg src "$source" \
        '{session_id:$id,cwd:$cwd,source:$src,hook_event_name:"SessionStart"}' \
        | CLAUDE_PID=$$ bash "$CS_TEST_START_HOOK" >/dev/null 2>&1
fi
exit "$("$CS_STUB_DIR/plan" claude)"
CLAUDE
    cat > "$stub/codex" <<'CODEX'
#!/usr/bin/env bash
STUB_PPID=$PPID "$CS_STUB_DIR/record" codex "$@"
if [ -f "$CS_STUB_DIR/codex.fail-early" ]; then
    rc=$(cat "$CS_STUB_DIR/codex.fail-early"); rm -f "$CS_STUB_DIR/codex.fail-early"; exit "$rc"
fi
exit "$("$CS_STUB_DIR/plan" codex)"
CODEX
    cat > "$stub/cs-codex-thread" <<'HELPER'
#!/usr/bin/env bash
n=$(( $(cat "$CS_STUB_DIR/helper.calls" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" > "$CS_STUB_DIR/helper.calls"
printf '%s\n' "$@" > "$CS_STUB_DIR/helper.args.$n"
thread=""
while [ "$#" -gt 0 ]; do
    case "$1" in --thread-id) thread="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$thread" ] || thread=$(printf '00000000-0000-4000-8000-%012d' "$n")
printf '%s\n' "$thread"
HELPER
    # The Claude launch swaps EDITOR for this shim; a relaunch must not keep it.
    mkdir -p "$CS_HOOKS_DIR"
    printf '#!/bin/sh\nexit 0\n' > "$CS_HOOKS_DIR/prompt-rewriter.sh"
    chmod +x "$stub"/* "$CS_STUB_DIR"/* "$CS_HOOKS_DIR/prompt-rewriter.sh"
}

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export HOME="$TEST_TMPDIR/home"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    export CS_TRANSCRIPTS_DIR="$TEST_TMPDIR/claude-projects"
    export CS_HOOKS_DIR="$TEST_TMPDIR/hooks"
    export CS_STUB_DIR="$TEST_TMPDIR/stub"
    export CS_NO_UPDATE_CHECK=1 CS_NO_ITERM2=1 CS_NO_FUNCTION_HOOKS=1
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/bin/claude"
    export CODEX_BIN="$TEST_TMPDIR/bin/codex"
    export CS_CODEX_THREAD_BIN="$TEST_TMPDIR/bin/cs-codex-thread"
    export CS_TEST_START_HOOK="$SCRIPT_DIR/../hooks/session-start.sh"
    export EDITOR=switch-test-editor
    mkdir -p "$HOME" "$CS_SESSIONS_ROOT" "$CS_TRANSCRIPTS_DIR"
    unset XDG_CONFIG_HOME VISUAL CS_REAL_EDITOR CLAUDE_CODE_TMUX_TRUECOLOR CS_ASSUME_TTY
    unset CS_DEFAULT_ENGINE CLAUDE_CODE_SESSION_ID CS_CLAUDE_SESSION_ID CLAUDE_PID
    unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CS_FRESH_REBIND
    unset CS_SESSION_NAME CS_SESSION_DIR CS_SESSION_META_DIR
    umask 022
    _write_stubs
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT CS_TRANSCRIPTS_DIR CS_HOOKS_DIR CS_STUB_DIR CS_NO_UPDATE_CHECK
    unset CS_NO_ITERM2 CS_NO_FUNCTION_HOOKS CLAUDE_CODE_BIN CODEX_BIN CS_CODEX_THREAD_BIN
    unset CS_TEST_START_HOOK CS_ASSUME_TTY CS_SESSION_NAME CS_SESSION_DIR CS_RUN_ID CS_RUN_ENGINE
}

# --- helpers ---

_dir() { printf '%s/%s\n' "$CS_SESSIONS_ROOT" "$1"; }
_plan() {  # engine, VAR=value lines...
    local engine="$1"; shift
    printf '%s\n' "$@" > "$CS_STUB_DIR/$engine.plan"
}
_calls() { cat "$CS_STUB_DIR/$1.calls" 2>/dev/null || echo 0; }
_args() { cat "$CS_STUB_DIR/$1.args.$2" 2>/dev/null; }
_envv() { sed -n "s/^$3=//p" "$CS_STUB_DIR/$1.env.$2" 2>/dev/null; }
_state() { awk -v k="$2:" '$1 == k { print $2; exit }' "$1/.cs/local/state" 2>/dev/null; }
_has() {  # file, literal, message
    grep -qF -- "$2" "$1" 2>/dev/null && return 0
    echo "  FAIL: ${3:-$1 should contain '$2'}"
    [ -f "$1" ] && echo "    file contents: $(head -20 "$1")"
    return 1
}
_lacks() {  # file, literal, message
    grep -qF -- "$2" "$1" 2>/dev/null || return 0
    echo "  FAIL: ${3:-$1 should not contain '$2'}"
    return 1
}
_count() { grep -cF -- "$2" "$1" 2>/dev/null || true; }

_new_claude_session() { "$CS_BIN" "$1" --engine claude </dev/null >/dev/null 2>&1; }
_new_codex_session() { "$CS_BIN" "$1" --engine codex </dev/null >/dev/null 2>&1; }

# A session dir and the environment of a run inside it, without launching:
# what the verb sees from a conversation's shell.
_fake_run() {  # name, engine
    local dir
    dir=$(_dir "$1")
    mkdir -p "$dir/.cs/local"
    export CS_SESSION_NAME="$1" CS_SESSION_DIR="$dir" CS_SESSION_META_DIR="$dir/.cs"
    export CS_RUN_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa CS_RUN_ENGINE="$2"
    printf '{"run_id":"%s","engine":"%s","owner_pid":1}\n' "$CS_RUN_ID" "$2" > "$dir/.cs/local/run-lease.json"
}
_arm() { "$CS_STUB_DIR/arm-handoff" "${1:-$HANDOFF}"; }

# ============================================================================
# The verb
# ============================================================================

test_verb_defaults_to_the_other_engine_and_writes_the_file() {
    local out status=0 file
    _fake_run vs claude
    _arm
    out=$("$CS_BIN" -switch 2>&1) || status=$?
    assert_eq 0 "$status" "switch failed: $out" || return 1
    file="$CS_SESSION_DIR/.cs/local/pending-switch"
    assert_eq "engine=codex
mode=fresh
handoff=$HANDOFF
run=$CS_RUN_ID" "$(cat "$file")" "pending-switch is four key=value lines in order" || return 1
    assert_output_contains "$out" '/exit' "Claude is left with /exit" || return 1
    assert_output_contains "$out" "under\|in a fresh codex conversation" "names the target" || return 1
    assert_output_contains "$out" "$HANDOFF" "names the handoff" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "one line on success" || return 1
    assert_exists "$CS_SESSION_DIR/.cs/local/pending-handoff" "the handoff stays armed" || return 1
}

test_verb_from_codex_targets_claude_and_says_quit() {
    local out status=0
    _fake_run vc codex
    _arm
    out=$("$CS_BIN" -switch claude --resume 2>&1) || status=$?
    assert_eq 0 "$status" "switch failed: $out" || return 1
    _has "$CS_SESSION_DIR/.cs/local/pending-switch" "engine=claude" || return 1
    _has "$CS_SESSION_DIR/.cs/local/pending-switch" "mode=resume" || return 1
    assert_output_contains "$out" '/quit' "Codex is left with /quit" || return 1
}

test_verb_refuses_the_same_engine() {
    local out status=0
    _fake_run vsame claude
    _arm
    out=$("$CS_BIN" -switch claude 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: same-engine switch must refuse"; return 1; }
    assert_output_contains "$out" 'rotate skill' "points at rotate" || return 1
    assert_not_exists "$CS_SESSION_DIR/.cs/local/pending-switch" || return 1
}

test_verb_refusals_name_the_fix_and_write_nothing() {
    local out status dir
    # Outside a session.
    status=0; out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: outside a session must refuse"; return 1; }
    assert_output_contains "$out" 'inside a cs session' || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "one line" || return 1

    _fake_run vr claude
    dir="$CS_SESSION_DIR"
    _arm
    # Unknown engine.
    status=0; out=$("$CS_BIN" -switch wat 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'Unknown engine: wat' || return 1
    # A shell without a run.
    status=0; out=$(env -u CS_RUN_ID "$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'conversation cs launched' || return 1
    # A run id no live lease names.
    status=0; out=$(CS_RUN_ID=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb "$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'No live cs run' || return 1
    # Target CLI not found.
    status=0; out=$(CODEX_BIN="$TEST_TMPDIR/no-codex" "$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'not found; install it' || return 1
    # Target engine not set up by the install.
    mkdir -p "$HOME/.local/bin"
    printf 'claude\n' > "$HOME/.local/bin/.cs-install-engines"
    status=0; out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'CS_INSTALL_ENGINES=claude,codex' || return 1
    rm -f "$HOME/.local/bin/.cs-install-engines"
    assert_not_exists "$dir/.cs/local/pending-switch" "no refusal writes the file" || return 1

    # No armed handoff: none at all, then a consumed one.
    rm -f "$dir/.cs/local/pending-handoff"
    status=0; out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'No rotation handoff is armed' || return 1
    _arm
    sed -i.bak 's/^status: unconsumed$/status: consumed/' "$dir/.cs/handoffs/$HANDOFF" && rm -f "$dir/.cs/handoffs/$HANDOFF.bak"
    status=0; out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'No rotation handoff is armed' || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" "no refusal writes the file" || return 1
}

test_verb_refuses_a_second_switch_and_cancel_keeps_the_handoff() {
    local out status=0 dir
    _fake_run vp claude
    dir="$CS_SESSION_DIR"
    _arm
    "$CS_BIN" -switch codex >/dev/null 2>&1 || { echo "  FAIL: first switch failed"; return 1; }
    out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a second switch must refuse"; return 1; }
    assert_output_contains "$out" 'cs -switch cancel' "names the fix" || return 1
    status=0; out=$("$CS_BIN" -switch --check 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: --check must refuse while a switch is pending"; return 1; }
    out=$("$CS_BIN" -switch cancel 2>&1) || { echo "  FAIL: cancel failed: $out"; return 1; }
    assert_output_contains "$out" 'cancelled' || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" "cancel removes the pending switch" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff")" "cancel leaves the handoff armed" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" || return 1
    out=$("$CS_BIN" -switch cancel 2>&1) || { echo "  FAIL: cancel with nothing pending must succeed"; return 1; }
    assert_output_contains "$out" 'No switch is pending' || return 1
}

test_check_passes_without_a_handoff_and_writes_nothing() {
    local out status=0 before after
    _fake_run vk claude
    before=$(ls -A "$CS_SESSION_DIR/.cs/local")
    out=$("$CS_BIN" -switch --check 2>&1) || status=$?
    assert_eq 0 "$status" "--check skips the armed-handoff refusal: $out" || return 1
    assert_output_contains "$out" 'from claude to codex' || return 1
    after=$(ls -A "$CS_SESSION_DIR/.cs/local")
    assert_eq "$before" "$after" "--check writes nothing" || return 1
    status=0; out=$("$CS_BIN" -switch --check claude 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'rotate skill' || return 1
}

# The capability check needs an adapter that lacks rotation, which neither
# shipped adapter is; the fragments are sourced and Codex's answer replaced.
test_verb_refuses_a_target_without_rotation() {
    local out status=0
    _fake_run vcap claude
    _arm
    out=$(
        for f in "$SCRIPT_DIR"/../lib/[0-9]*-*.sh; do
            # main runs on load; everything else only defines.
            [ "${f##*/}" != 99-main.sh ] || continue
            # shellcheck disable=SC1090
            source "$f"
        done
        _cs_codex_adapter_capabilities() { printf '%s\n' launch exact_resume; }
        cmd_switch codex 2>&1
    ) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a target without rotation must refuse"; return 1; }
    assert_output_contains "$out" 'no rotation support' || return 1
    assert_not_exists "$CS_SESSION_DIR/.cs/local/pending-switch" || return 1
}

test_encrypted_session_keeps_the_switch_in_private_and_refuses_when_locked() {
    local out status=0 dir
    _fake_run venc codex
    dir="$CS_SESSION_DIR"
    mkdir -p "$dir/.cs/private"
    _arm
    out=$("$CS_BIN" -switch claude 2>&1) || status=$?
    assert_eq 0 "$status" "encrypted switch failed: $out" || return 1
    _has "$dir/.cs/private/pending-switch" "engine=claude" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" "nothing in plaintext .cs/local" || return 1
    out=$("$CS_BIN" -switch cancel 2>&1) || return 1
    assert_not_exists "$dir/.cs/private/pending-switch" || return 1
    # Codex's rotation reads .cs/handoffs, never the vault: no switch into it.
    status=0; out=$(CS_RUN_ENGINE=claude "$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: an encrypted switch into codex must refuse"; return 1; }
    assert_output_contains "$out" 'this session is encrypted' || return 1
    assert_output_contains "$out" 'rotate skill' "names the fix" || return 1
    status=0; out=$(CS_RUN_ENGINE=claude "$CS_BIN" -switch --check 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'this session is encrypted' || return 1
    assert_not_exists "$dir/.cs/private/pending-switch" || return 1
    # A locked vault: .cs/private dangles.
    rm -rf "$dir/.cs/private"
    ln -s "$TEST_TMPDIR/vault-not-mounted" "$dir/.cs/private"
    status=0; out=$("$CS_BIN" -switch codex 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a locked vault must refuse"; return 1; }
    assert_output_contains "$out" 'vault is locked' || return 1
    status=0; out=$("$CS_BIN" -switch --check 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'vault is locked' || return 1
}

# ============================================================================
# --from-handoff
# ============================================================================

test_claude_from_handoff_takes_r_without_asking() {
    local out status=0 dir old new
    _new_claude_session fh
    dir=$(_dir fh)
    old=$(_state "$dir" claude_session_id)
    CS_SESSION_DIR="$dir" _arm
    # An attended open with "n" waiting on stdin: were the menu shown, n would
    # start fresh without the handoff.
    out=$(printf 'n' | CS_ASSUME_TTY=1 "$CS_BIN" fh --from-handoff 2>&1) || status=$?
    assert_eq 0 "$status" "--from-handoff failed: $out" || return 1
    assert_output_not_contains "$out" 'Rotation handoff pending' "no menu" || return 1
    assert_output_contains "$out" 'from handoff' "the card says where it starts" || return 1
    assert_output_not_contains "$out" 'from another checkout' "the armed handoff is this checkout's choice" || return 1
    new=$(_state "$dir" claude_session_id)
    [ -n "$new" ] && [ "$new" != "$old" ] || { echo "  FAIL: a fresh conversation must be bound ($old -> $new)"; return 1; }
    _has "$CS_STUB_DIR/claude.args.2" "--session-id" || return 1
    _has "$CS_STUB_DIR/claude.args.2" "$new" || return 1
    _has "$CS_STUB_DIR/claude.args.2" "Continue from the pending rotation handoff: read .cs/handoffs/$HANDOFF first." || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $new" "the fresh conversation consumes it" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" || return 1
}

test_claude_from_handoff_picks_an_unarmed_pending_handoff() {
    local out status=0 dir
    _new_claude_session fh2
    dir=$(_dir fh2)
    CS_SESSION_DIR="$dir" _arm
    rm -f "$dir/.cs/local/pending-handoff"
    out=$("$CS_BIN" fh2 --from-handoff </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "manual fallback failed: $out" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: consumed" || return 1
    # Unarmed, the pick is the scan's newest file, which this checkout's log
    # does not show it wrote: labelled as the menu labels it before r.
    assert_output_contains "$out" "Continuing from handoff: $HANDOFF (from another checkout)" || return 1
}

test_from_handoff_refuses_without_a_handoff_and_conflicts() {
    local out status dir
    _new_claude_session fh3
    dir=$(_dir fh3)
    status=0; out=$("$CS_BIN" fh3 --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: no handoff must refuse"; return 1; }
    assert_output_contains "$out" 'No rotation handoff is pending' || return 1
    assert_output_contains "$out" 'cs fh3 --fresh' "hints at --fresh" || return 1
    assert_eq 1 "$(_calls claude)" "claude is not launched" || return 1
    assert_not_exists "$dir/.cs/session.lock" "the lock is released" || return 1

    status=0; out=$("$CS_BIN" fh3 --from-handoff --fresh </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" '--from-handoff cannot be combined with --fresh' || return 1
    status=0; out=$("$CS_BIN" fh3 --resume --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" '--from-handoff cannot be combined with --resume' || return 1
    status=0; out=$("$CS_BIN" fh3 -finish x --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'cannot be combined with -finish' || return 1
    status=0; out=$("$CS_BIN" nosuch --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'does not exist' || return 1
    assert_not_exists "$(_dir nosuch)" "no session is created" || return 1
    assert_eq 1 "$(_calls claude)" "no conflict launches claude" || return 1
}

test_codex_from_handoff_starts_a_thread_from_the_handoff() {
    local out status=0 dir thread
    _new_codex_session cfh
    dir=$(_dir cfh)
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    CS_SESSION_DIR="$dir" _arm
    out=$(printf 'y' | CS_ASSUME_TTY=1 "$CS_BIN" cfh --from-handoff 2>&1) || status=$?
    assert_eq 0 "$status" "--from-handoff failed: $out" || return 1
    assert_output_not_contains "$out" 'Rotation handoff pending' "no menu" || return 1
    assert_output_not_contains "$out" 'from another checkout' "the armed handoff is this checkout's choice" || return 1
    _lacks "$CS_STUB_DIR/helper.args.2" "--thread-id" "a fresh thread, not a refresh" || return 1
    local new
    new=$(cat "$dir/.cs/local/codex-thread-id")
    [ "$new" != "$thread" ] || { echo "  FAIL: a new thread must be bound"; return 1; }
    assert_eq "--no-daemon
resume
$new
-C
$dir
Continue from the pending rotation handoff: read .cs/handoffs/$HANDOFF first." "$(_args codex 2)" "codex starts on the r path" || return 1
    _has "$dir/.cs/local/codex-instructions.md" "--- Conversation Rotation ---" "the rotation preamble is in the context" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $new" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" || return 1

    status=0; out=$("$CS_BIN" cfh --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'No rotation handoff is pending' || return 1
    assert_eq 2 "$(_calls codex)" "codex is not launched without a handoff" || return 1
}

test_codex_from_handoff_refuses_an_encrypted_session() {
    local out status=0 dir
    _new_codex_session cenc
    dir=$(_dir cenc)
    mkdir -p "$dir/.cs/private"
    [ ! -f "$dir/.cs/local/session.log" ] || mv "$dir/.cs/local/session.log" "$dir/.cs/private/"
    CS_SESSION_DIR="$dir" _arm
    out=$("$CS_BIN" cenc --from-handoff </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: codex must refuse a handoff kept in the vault"; return 1; }
    assert_output_contains "$out" 'does not read handoffs from .cs/private' || return 1
    assert_output_contains "$out" 'cs cenc --engine claude --from-handoff' "names the way that works" || return 1
    assert_eq 1 "$(_calls codex)" "codex is not launched" || return 1
    _has "$dir/.cs/private/handoffs/$HANDOFF" "status: unconsumed" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/private/pending-handoff")" "the handoff stays armed" || return 1
}

# ============================================================================
# The relaunch
# ============================================================================

test_switch_from_claude_relaunches_codex_from_the_handoff() {
    local out status=0 dir claude_id thread
    _new_claude_session sw
    dir=$(_dir sw)
    claude_id=$(_state "$dir" claude_session_id)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    out=$("$CS_BIN" sw </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    _has "$CS_STUB_DIR/switch.out" "Switch armed" "the verb ran inside the run: $(cat "$CS_STUB_DIR/switch.out" 2>/dev/null)" || return 1
    assert_eq 1 "$(_calls codex)" "codex is launched exactly once" || return 1
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    assert_eq "--no-daemon
resume
$thread
-C
$dir
Continue from the pending rotation handoff: read .cs/handoffs/$HANDOFF first." "$(_args codex 1)" "codex starts on the r path" || return 1
    assert_eq 1 "$(_count "$dir/.cs/handoffs/$HANDOFF" 'consumed_by:')" "consumed once" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $thread" || return 1
    assert_eq codex "$(_state "$dir" engine)" "the session now prefers codex" || return 1
    assert_eq "$claude_id" "$(_state "$dir" claude_session_id)" "Claude's binding is untouched" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" || return 1
    assert_output_not_contains "$out" 'earlier run left' "the relaunch found nothing left over" || return 1
    assert_output_contains "$out" 'Switching sw to codex' || return 1
    assert_output_not_contains "$out" 'from another checkout' "the switch's handoff is armed" || return 1
    # The relaunch is a new run of the same terminal process, and none of the
    # finished run's state rides into it.
    local claude_run codex_run
    claude_run=$(_envv claude 2 CS_RUN_ID)
    codex_run=$(_envv codex 1 CS_RUN_ID)
    [ -n "$codex_run" ] && [ "$codex_run" != "$claude_run" ] \
        || { echo "  FAIL: the relaunch must be a new run ($claude_run -> $codex_run)"; return 1; }
    assert_eq codex "$(_envv codex 1 CS_RUN_ENGINE)" || return 1
    assert_eq "$(_envv codex 1 PPID)" "$(_envv codex 1 CS_LEAD_PID)" "the lead is the relaunched cs" || return 1
    assert_eq "$(_envv codex 1 PPID)" "$(_envv codex 1 CS_RUN_OWNER_PID)" "the owner is the relaunched cs" || return 1
    assert_eq "$TEST_TMPDIR/hooks/prompt-rewriter.sh" "$(_envv claude 2 EDITOR)" "(fixture) Claude ran with the rewriter shim" || return 1
    assert_eq switch-test-editor "$(_envv codex 1 EDITOR)" "the relaunch gets the user's EDITOR back" || return 1
    _has "$CS_STUB_DIR/codex.env.1" "CS_REAL_EDITOR unset" || return 1
    _has "$CS_STUB_DIR/codex.env.1" "CLAUDE_CODE_TMUX_TRUECOLOR unset" "Claude-only exports do not ride along" || return 1
    _has "$CS_STUB_DIR/codex.env.1" "CS_FRESH_REBIND unset" || return 1
}

test_switch_from_codex_relaunches_claude_from_the_handoff() {
    local out status=0 dir thread new
    _new_codex_session swc
    dir=$(_dir swc)
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    _plan codex "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH="
    out=$("$CS_BIN" swc </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    _has "$CS_STUB_DIR/switch.out" "/quit" || return 1
    assert_eq 1 "$(_calls claude)" "claude is launched exactly once" || return 1
    new=$(_state "$dir" claude_session_id)
    [ -n "$new" ] || { echo "  FAIL: claude must bind a conversation"; return 1; }
    _has "$CS_STUB_DIR/claude.args.1" "--session-id" || return 1
    _has "$CS_STUB_DIR/claude.args.1" "Continue from the pending rotation handoff: read .cs/handoffs/$HANDOFF first." || return 1
    assert_eq 1 "$(_count "$dir/.cs/handoffs/$HANDOFF" 'consumed_by:')" "consumed once" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $new" || return 1
    assert_eq claude "$(_state "$dir" engine)" || return 1
    assert_eq "$thread" "$(cat "$dir/.cs/local/codex-thread-id")" "Codex's binding is untouched" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" || return 1
    assert_eq 0022 "$(_envv claude 1 UMASK)" "Codex's umask 077 does not ride into the relaunch" || return 1
    [ "$(_envv claude 1 CS_RUN_ID)" != "$(_envv codex 2 CS_RUN_ID)" ] \
        || { echo "  FAIL: the relaunch must be a new run"; return 1; }
}

# C1 -> H1 -> X1 -> H2 -> C2: the relaunched Codex run switches back, and the
# second relaunch starts a fresh Claude conversation from the newer handoff.
test_round_trip_carries_each_engine_s_work_forward() {
    local out status=0 dir c1 x1 c2 back=2026-10-07-switch-back.md
    _new_claude_session rt
    dir=$(_dir rt)
    c1=$(_state "$dir" claude_session_id)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    _plan codex "PLAN_HANDOFF=$back" "PLAN_SWITCH=claude"
    out=$("$CS_BIN" rt </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "round trip failed: $out" || return 1
    assert_eq 1 "$(_calls codex)" "codex runs once" || return 1
    assert_eq 3 "$(_calls claude)" "claude: the open, the first run, the return" || return 1
    x1=$(cat "$dir/.cs/local/codex-thread-id")
    c2=$(_state "$dir" claude_session_id)
    [ -n "$c2" ] && [ "$c2" != "$c1" ] || { echo "  FAIL: the return must be a fresh conversation ($c1 -> $c2)"; return 1; }
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $x1" "codex took the first handoff" || return 1
    _has "$dir/.cs/handoffs/$back" "consumed_by: $c2" "the new claude took the second" || return 1
    _has "$CS_STUB_DIR/claude.args.3" "read .cs/handoffs/$back first" || return 1
    assert_eq claude "$(_state "$dir" engine)" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" || return 1
}

test_failed_cli_exit_does_not_relaunch_and_names_both_ways_back() {
    local out status=0 dir
    _new_claude_session swf
    dir=$(_dir swf)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex" "PLAN_EXIT=3"
    out=$("$CS_BIN" swf </dev/null 2>&1) || status=$?
    assert_eq 3 "$status" "cs ends with the CLI's status" || return 1
    assert_eq 0 "$(_calls codex)" "no relaunch" || return 1
    assert_output_contains "$out" 'cs swf --engine codex --from-handoff' || return 1
    assert_output_contains "$out" 'cs swf --engine claude$' || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" "consumed once, whatever happens" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff")" "the handoff stays armed" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" || return 1
}

test_a_clear_that_took_the_handoff_drops_the_switch() {
    local out status=0 dir
    _new_claude_session swx
    dir=$(_dir swx)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex" "PLAN_CLEAR=1"
    out=$("$CS_BIN" swx </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "run failed: $out" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: 99999999-9999-4999-8999-999999999999" "(fixture) the /clear took it" || return 1
    assert_eq 0 "$(_calls codex)" "no relaunch" || return 1
    assert_output_contains "$out" 'already taken' "one notice" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
}

test_a_switch_another_run_wrote_is_ignored() {
    local out status=0 dir
    _new_claude_session swm
    dir=$(_dir swm)
    CS_SESSION_DIR="$dir" _arm
    _plan claude "PLAN_RAW_SWITCH='engine=codex\nmode=fresh\nhandoff=$HANDOFF\nrun=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\n'"
    out=$("$CS_BIN" swm </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "run failed: $out" || return 1
    assert_eq 0 "$(_calls codex)" "a switch from another run is not taken" || return 1
    _has "$dir/.cs/local/pending-switch" "run=bbbbbbbb" "and is left alone" || return 1
    # The next run starts by dropping it: nothing the next exit could take.
    out=$("$CS_BIN" swm </dev/null 2>&1) || true
    assert_output_contains "$out" 'earlier run left' || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
    assert_eq 0 "$(_calls codex)" || return 1
}

test_resume_mode_from_claude_resumes_codex_with_the_handoff() {
    local out status=0 dir thread
    _new_codex_session rsm
    dir=$(_dir rsm)
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    "$CS_BIN" rsm --engine claude </dev/null >/dev/null 2>&1 || { echo "  FAIL: claude open failed"; return 1; }
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH='codex --resume'"
    out=$("$CS_BIN" rsm </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_eq 2 "$(_calls codex)" "codex is relaunched once" || return 1
    _has "$CS_STUB_DIR/helper.args.2" "--thread-id" "the recorded thread is refreshed" || return 1
    _has "$CS_STUB_DIR/helper.args.2" "$thread" || return 1
    assert_eq "--no-daemon
resume
$thread
-C
$dir
This conversation resumes after the session ran under claude. Read .cs/handoffs/$HANDOFF first: it carries the work done since you last ran here. Then continue from its next step." "$(_args codex 2)" "the handoff is the resume's first message" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $thread" "the resumed thread consumes it" || return 1
    assert_eq 1 "$(_count "$dir/.cs/handoffs/$HANDOFF" 'consumed_by:')" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" "the marker does not outlive the resume" || return 1
    assert_eq "$thread" "$(cat "$dir/.cs/local/codex-thread-id")" || return 1
    assert_eq codex "$(_state "$dir" engine)" || return 1
    _lacks "$dir/.cs/local/codex-instructions.md" "--- Conversation Rotation ---" "a resume is no fresh rotation" || return 1
}

test_resume_mode_from_codex_resumes_claude_with_the_handoff() {
    local out status=0 dir claude_id
    _new_claude_session rsc
    dir=$(_dir rsc)
    claude_id=$(_state "$dir" claude_session_id)
    "$CS_BIN" rsc --engine codex </dev/null >/dev/null 2>&1 || { echo "  FAIL: codex open failed"; return 1; }
    _plan codex "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH='claude --resume'"
    out=$("$CS_BIN" rsc </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_eq 2 "$(_calls claude)" "claude is relaunched once" || return 1
    assert_eq "--name
rsc
--resume
$claude_id
This conversation resumes after the session ran under codex. Read .cs/handoffs/$HANDOFF first: it carries the work done since you last ran here. Then continue from its next step." "$(_args claude 2)" "the handoff is the resume's first message" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $claude_id" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" "the marker does not outlive the resume" || return 1
    assert_output_not_contains "$out" 'Rotation marker disarmed' || return 1
    assert_eq "$claude_id" "$(_state "$dir" claude_session_id)" || return 1
    assert_eq claude "$(_state "$dir" engine)" || return 1
}

test_resume_mode_without_a_recorded_conversation_starts_fresh() {
    local out status=0 dir thread
    _new_claude_session rsf
    dir=$(_dir rsf)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH='codex --resume'"
    out=$("$CS_BIN" rsf </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_output_contains "$out" 'No recorded codex conversation to resume' || return 1
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    _has "$CS_STUB_DIR/codex.args.1" "Continue from the pending rotation handoff: read .cs/handoffs/$HANDOFF first." || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $thread" || return 1
}

test_worktree_session_relaunches_under_its_own_name() {
    local out status=0 base wt
    base=$(create_test_session_with_git wtb)
    "$CS_BIN" wtb@feat --engine claude </dev/null >/dev/null 2>&1 || { echo "  FAIL: worktree open failed"; return 1; }
    wt=$(_dir wtb@feat)
    assert_dir "$wt" || return 1
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    out=$("$CS_BIN" wtb@feat </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_eq 1 "$(_calls codex)" || return 1
    _has "$CS_STUB_DIR/codex.args.1" "$wt" "codex opens the worktree" || return 1
    assert_eq wtb@feat "$(_envv codex 1 CS_SESSION_NAME)" || return 1
    assert_eq codex "$(_state "$wt" engine)" || return 1
    _has "$wt/.cs/handoffs/$HANDOFF" "status: consumed" || return 1
    [ "$(_state "$base" engine)" != codex ] || { echo "  FAIL: the base's preference must not change"; return 1; }
}

test_encrypted_session_relaunch_reads_the_switch_from_private() {
    local out status=0 dir thread new
    _new_codex_session swe
    dir=$(_dir swe)
    # Encrypted: .cs/private holds what .cs/local would (a real directory
    # stands in for the mounted vault).
    mkdir -p "$dir/.cs/private"
    [ ! -f "$dir/.cs/local/session.log" ] || mv "$dir/.cs/local/session.log" "$dir/.cs/private/"
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    _plan codex "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=claude"
    out=$("$CS_BIN" swe </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_eq 1 "$(_calls claude)" "claude is relaunched once" || return 1
    new=$(_state "$dir" claude_session_id)
    _has "$dir/.cs/private/handoffs/$HANDOFF" "consumed_by: $new" || return 1
    _lacks "$CS_STUB_DIR/claude.args.1" "$HANDOFF" "the topic stays out of argv" || return 1
    assert_not_exists "$dir/.cs/private/pending-switch" || return 1
    assert_not_exists "$dir/.cs/private/pending-handoff" || return 1
}

test_relaunch_that_cannot_start_names_both_ways_back() {
    local out status=0 dir
    _new_claude_session swd
    dir=$(_dir swd)
    # The helper fails in the relaunch: Codex never starts.
    cat > "$CS_CODEX_THREAD_BIN" <<'HELPER'
#!/usr/bin/env bash
echo 'simulated app-server failure' >&2
exit 9
HELPER
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    out=$("$CS_BIN" swd </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a failed relaunch must fail"; return 1; }
    assert_eq 0 "$(_calls codex)" || return 1
    assert_output_contains "$out" 'did not start' || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'Reopen with either')" "said once, not by the guard as well" || return 1
    assert_output_contains "$out" 'cs swd --engine codex --from-handoff' || return 1
    assert_output_contains "$out" 'cs swd --engine claude$' || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff")" "the handoff stays armed" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" || return 1
}

# An open step of the relaunch refuses before its run begins (here a pre-open
# hook that is not executable): cs ends through error(), and the guard still
# names both ways back.
test_relaunch_refused_by_an_open_step_names_both_ways_back() {
    local out status=0 dir
    _new_claude_session swo
    dir=$(_dir swo)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex" \
        "PLAN_CMD='printf \"#!/bin/sh\\nexit 0\\n\" > \"\$CS_SESSION_DIR/.cs/local/pre-open\"'"
    out=$("$CS_BIN" swo </dev/null 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a refused relaunch must fail: $out"; return 1; }
    assert_output_contains "$out" 'pre-open is not executable' "(fixture) the open step refused" || return 1
    assert_eq 0 "$(_calls codex)" "codex never starts" || return 1
    assert_output_contains "$out" 'The switch to codex did not start' || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'Reopen with either')" "said once" || return 1
    assert_output_contains "$out" 'cs swo --engine codex --from-handoff' || return 1
    assert_output_contains "$out" 'cs swo --engine claude$' || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff")" "the handoff stays armed" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
}

# A Codex run in an encrypted session writes its session.log to .cs/local, and
# every later open refuses that plaintext file. The switch asks before it
# relaunches, while it can still say what to fix and how to come back.
test_encrypted_leftovers_stop_the_relaunch_before_it_starts() {
    local out status=0 dir
    _new_codex_session swl
    dir=$(_dir swl)
    mkdir -p "$dir/.cs/private"
    [ ! -f "$dir/.cs/local/session.log" ] || mv "$dir/.cs/local/session.log" "$dir/.cs/private/"
    _plan codex "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=claude" \
        "PLAN_CMD='echo started >> \"\$CS_SESSION_DIR/.cs/local/session.log\"'"
    out=$("$CS_BIN" swl </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "the Codex run itself ended well: $out" || return 1
    _has "$CS_STUB_DIR/switch.out" "Switch armed" "(fixture) the switch was armed" || return 1
    assert_eq 0 "$(_calls claude)" "no relaunch" || return 1
    assert_output_contains "$out" 'Not switching to claude: the session would not reopen' || return 1
    assert_output_contains "$out" 'session.log in plaintext' "names what to fix" || return 1
    assert_output_contains "$out" 'cs swl --engine claude --from-handoff' || return 1
    assert_output_contains "$out" 'cs swl --engine codex$' || return 1
    assert_not_exists "$dir/.cs/private/pending-switch" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/private/pending-handoff")" "the handoff stays armed" || return 1
    _has "$dir/.cs/private/handoffs/$HANDOFF" "status: unconsumed" || return 1
}

test_codex_from_handoff_labels_a_handoff_from_another_checkout() {
    local out status=0 dir
    _new_codex_session cfo
    dir=$(_dir cfo)
    CS_SESSION_DIR="$dir" _arm
    rm -f "$dir/.cs/local/pending-handoff"
    out=$("$CS_BIN" cfo --from-handoff </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "--from-handoff failed: $out" || return 1
    assert_output_contains "$out" "Continuing from handoff: $HANDOFF (from another checkout)" || return 1
}

# The relaunch's argv is settled before the user's environment is put back:
# variables named like its locals reach the target CLI and change nothing else.
test_relaunch_ignores_user_variables_named_like_its_locals() {
    local out status=0 dir
    _new_claude_session swv
    dir=$(_dir swv)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    out=$(target=claude name=other mode=resume from=codex "$CS_BIN" swv </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "switch run failed: $out" || return 1
    assert_output_contains "$out" 'Switching swv to codex: a fresh conversation' || return 1
    assert_eq 1 "$(_calls codex)" "codex is launched exactly once" || return 1
    _has "$CS_STUB_DIR/codex.args.1" "$dir" "codex opens swv" || return 1
    assert_eq swv "$(_envv codex 1 CS_SESSION_NAME)" || return 1
    # ("name" is not checked: cs itself assigns one on a direct launch too.)
    assert_eq claude "$(_envv codex 1 target)" "the user's own variables ride along" || return 1
    assert_eq resume "$(_envv codex 1 mode)" || return 1
    assert_eq codex "$(_envv codex 1 from)" || return 1
    assert_eq codex "$(_state "$dir" engine)" || return 1
}

# Claude Code refuses the resume (a pruned transcript) before its
# conversation starts: the handoff the launch spent goes back to armed.
test_resume_relaunch_claude_refuses_puts_the_handoff_back() {
    local out status=0 dir claude_id
    _new_claude_session rrf
    dir=$(_dir rrf)
    claude_id=$(_state "$dir" claude_session_id)
    "$CS_BIN" rrf --engine codex </dev/null >/dev/null 2>&1 || { echo "  FAIL: codex open failed"; return 1; }
    _plan codex "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH='claude --resume'"
    echo 1 > "$CS_STUB_DIR/claude.fail-early"
    out=$("$CS_BIN" rrf </dev/null 2>&1) || status=$?
    assert_eq 1 "$status" "cs ends with the relaunch's status: $out" || return 1
    assert_eq 2 "$(_calls claude)" "(fixture) claude was asked to resume" || return 1
    _has "$CS_STUB_DIR/claude.args.2" "$claude_id" || return 1
    assert_output_contains "$out" 'Could not resume the recorded Claude conversation' "(fixture) the launch's own error" || return 1
    assert_output_contains "$out" "The switch to claude did not start; the handoff $HANDOFF stays armed" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'Reopen with either')" "said once" || return 1
    assert_output_contains "$out" 'cs rrf --engine claude --from-handoff' || return 1
    assert_output_contains "$out" 'cs rrf --engine codex$' || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" "the spend is undone" || return 1
    _lacks "$dir/.cs/handoffs/$HANDOFF" "consumed_by:" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null)" "the handoff is armed again" || return 1
    assert_eq codex "$(_state "$dir" engine)" "the session stays on codex" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
}

# Codex's r path spends the handoff before Codex starts; a Codex that never
# starts its thread gives it back.
test_fresh_relaunch_codex_cannot_start_puts_the_handoff_back() {
    local out status=0 dir
    _new_claude_session rcf
    dir=$(_dir rcf)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    echo 1 > "$CS_STUB_DIR/codex.fail-early"
    out=$("$CS_BIN" rcf </dev/null 2>&1) || status=$?
    assert_eq 1 "$status" "cs ends with the relaunch's status: $out" || return 1
    assert_eq 1 "$(_calls codex)" "(fixture) codex was started once" || return 1
    assert_output_contains "$out" "The switch to codex did not start; the handoff $HANDOFF stays armed" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c 'Reopen with either')" "said once" || return 1
    assert_output_contains "$out" 'cs rcf --engine codex --from-handoff' || return 1
    assert_output_contains "$out" 'cs rcf --engine claude$' || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "status: unconsumed" "the spend is undone" || return 1
    _lacks "$dir/.cs/handoffs/$HANDOFF" "consumed_by:" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null)" "the handoff is armed again" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
}

# The relaunched Codex ran, rotated (a newer handoff armed) and exited with an
# error: nothing is put back and no switch failure is claimed.
test_relaunched_conversation_that_rotated_then_failed_keeps_its_rotation() {
    local out status=0 dir thread later=2026-10-07-later.md
    _new_claude_session rrt
    dir=$(_dir rrt)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    _plan codex "PLAN_HANDOFF=$later" "PLAN_EXIT=1"
    out=$("$CS_BIN" rrt </dev/null 2>&1) || status=$?
    assert_eq 1 "$status" "cs ends with codex's status" || return 1
    assert_eq 1 "$(_calls codex)" || return 1
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    assert_output_not_contains "$out" 'did not start' "codex did start" || return 1
    assert_output_not_contains "$out" 'Reopen with either' || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $thread" "the thread keeps what it took" || return 1
    assert_eq "$later" "$(cat "$dir/.cs/local/pending-handoff" 2>/dev/null)" "the newer rotation stays armed" || return 1
    _has "$dir/.cs/handoffs/$later" "status: unconsumed" || return 1
}

# The relaunched Codex reached its conversation (its SessionStart logged it),
# then exited with an error: the handoff stays spent, with no notice.
test_relaunched_conversation_that_ran_then_failed_keeps_the_handoff_spent() {
    local out status=0 dir thread
    _new_claude_session rrs
    dir=$(_dir rrs)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex"
    _plan codex "PLAN_EXIT=1" \
        "PLAN_CMD='echo \"2026-10-07 10:00:00 - Session started (source: resume, ID: x)\" >> \"\$CS_SESSION_DIR/.cs/local/session.log\"'"
    out=$("$CS_BIN" rrs </dev/null 2>&1) || status=$?
    assert_eq 1 "$status" "cs ends with codex's status" || return 1
    thread=$(cat "$dir/.cs/local/codex-thread-id")
    assert_output_not_contains "$out" 'did not start' "codex did start" || return 1
    _has "$dir/.cs/handoffs/$HANDOFF" "consumed_by: $thread" || return 1
    assert_not_exists "$dir/.cs/local/pending-handoff" "nothing is re-armed" || return 1
}

# The target CLI vanished between cs -switch and the exit: the settle says
# so itself, leaves the handoff armed, and the run ends with the CLI's status.
test_settle_keeps_the_handoff_when_the_target_cli_went_missing() {
    local out status=0 dir
    _new_claude_session swn
    dir=$(_dir swn)
    _plan claude "PLAN_HANDOFF=$HANDOFF" "PLAN_SWITCH=codex" "PLAN_CMD='rm -f \"\$CODEX_BIN\"'"
    out=$("$CS_BIN" swn </dev/null 2>&1) || status=$?
    assert_eq 0 "$status" "claude itself ended well: $out" || return 1
    _has "$CS_STUB_DIR/switch.out" "Switch armed" "(fixture) the switch was armed" || return 1
    assert_output_contains "$out" "Not switching to codex:" || return 1
    assert_output_contains "$out" "not found; the handoff $HANDOFF stays armed" || return 1
    assert_output_contains "$out" 'cs swn --engine codex --from-handoff' || return 1
    assert_output_contains "$out" 'cs swn --engine claude$' || return 1
    assert_eq 0 "$(_calls codex)" "no relaunch" || return 1
    assert_eq "$HANDOFF" "$(cat "$dir/.cs/local/pending-handoff")" "the handoff stays armed" || return 1
    assert_not_exists "$dir/.cs/local/pending-switch" || return 1
}

# A pending-switch naming the engine that is running, or none cs knows, is
# dropped by the settle rather than relaunched.
test_settle_refuses_a_switch_that_names_no_other_engine() {
    local out status=0 dir bad
    _new_claude_session swg
    dir=$(_dir swg)
    for bad in claude wat; do
        status=0
        _plan claude "PLAN_HANDOFF=$HANDOFF" \
            "PLAN_RAW_SWITCH=\"engine=$bad\\nmode=fresh\\nhandoff=$HANDOFF\\nrun=\$CS_RUN_ID\\n\""
        out=$("$CS_BIN" swg </dev/null 2>&1) || status=$?
        assert_eq 0 "$status" "run failed: $out" || return 1
        assert_output_contains "$out" "Not switching: the pending switch names no other engine ($bad)." || return 1
        assert_not_exists "$dir/.cs/local/pending-switch" "consumed once" || return 1
    done
    assert_eq 3 "$(_calls claude)" "the open and two runs; no relaunch" || return 1
    assert_eq 0 "$(_calls codex)" || return 1
}

# Codex writes its session log to .cs/local, which an encrypted session's
# open refuses: the verb says so before the skill writes a handoff.
test_verb_refuses_an_encrypted_session_that_would_not_reopen() {
    local out status=0 dir
    _fake_run vlo codex
    dir="$CS_SESSION_DIR"
    mkdir -p "$dir/.cs/private"
    _arm
    echo '2026-10-07 10:00:00 - Session started (source: resume, ID: x)' > "$dir/.cs/local/session.log"
    out=$("$CS_BIN" -switch claude 2>&1) || status=$?
    [ "$status" -ne 0 ] || { echo "  FAIL: a switch the reopen would refuse must refuse now"; return 1; }
    assert_output_contains "$out" 'cs would not reopen the session' || return 1
    assert_output_contains "$out" 'session.log in plaintext' "names what to fix" || return 1
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "one line" || return 1
    assert_not_exists "$dir/.cs/private/pending-switch" || return 1
    status=0; out=$("$CS_BIN" -switch --check claude 2>&1) || status=$?
    [ "$status" -ne 0 ] && assert_output_contains "$out" 'session.log in plaintext' || return 1
    mv "$dir/.cs/local/session.log" "$dir/.cs/private/session.log"
    out=$("$CS_BIN" -switch --check claude 2>&1) || { echo "  FAIL: moved into the vault, --check must pass: $out"; return 1; }
}

run_test test_verb_defaults_to_the_other_engine_and_writes_the_file
run_test test_verb_from_codex_targets_claude_and_says_quit
run_test test_verb_refuses_the_same_engine
run_test test_verb_refusals_name_the_fix_and_write_nothing
run_test test_verb_refuses_a_second_switch_and_cancel_keeps_the_handoff
run_test test_check_passes_without_a_handoff_and_writes_nothing
run_test test_verb_refuses_a_target_without_rotation
run_test test_encrypted_session_keeps_the_switch_in_private_and_refuses_when_locked
run_test test_claude_from_handoff_takes_r_without_asking
run_test test_claude_from_handoff_picks_an_unarmed_pending_handoff
run_test test_from_handoff_refuses_without_a_handoff_and_conflicts
run_test test_codex_from_handoff_starts_a_thread_from_the_handoff
run_test test_codex_from_handoff_refuses_an_encrypted_session
run_test test_switch_from_claude_relaunches_codex_from_the_handoff
run_test test_switch_from_codex_relaunches_claude_from_the_handoff
run_test test_round_trip_carries_each_engine_s_work_forward
run_test test_failed_cli_exit_does_not_relaunch_and_names_both_ways_back
run_test test_a_clear_that_took_the_handoff_drops_the_switch
run_test test_a_switch_another_run_wrote_is_ignored
run_test test_resume_mode_from_claude_resumes_codex_with_the_handoff
run_test test_resume_mode_from_codex_resumes_claude_with_the_handoff
run_test test_resume_mode_without_a_recorded_conversation_starts_fresh
run_test test_worktree_session_relaunches_under_its_own_name
run_test test_encrypted_session_relaunch_reads_the_switch_from_private
run_test test_relaunch_that_cannot_start_names_both_ways_back
run_test test_relaunch_refused_by_an_open_step_names_both_ways_back
run_test test_encrypted_leftovers_stop_the_relaunch_before_it_starts
run_test test_codex_from_handoff_labels_a_handoff_from_another_checkout
run_test test_relaunch_ignores_user_variables_named_like_its_locals
run_test test_resume_relaunch_claude_refuses_puts_the_handoff_back
run_test test_fresh_relaunch_codex_cannot_start_puts_the_handoff_back
run_test test_relaunched_conversation_that_rotated_then_failed_keeps_its_rotation
run_test test_relaunched_conversation_that_ran_then_failed_keeps_the_handoff_spent
run_test test_settle_keeps_the_handoff_when_the_target_cli_went_missing
run_test test_settle_refuses_a_switch_that_names_no_other_engine
run_test test_verb_refuses_an_encrypted_session_that_would_not_reopen

report_results
