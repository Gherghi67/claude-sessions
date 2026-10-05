#!/usr/bin/env bash
# ABOUTME: Tests for iTerm2 awareness: the attention dock bounce fired by the
# ABOUTME: hooks through it2attention, and the doctor's integration-surface line

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"

# A session dir + ambient env + a fake it2 toolkit that logs its argv instead
# of emitting terminal escapes. test_lib's setup exports CS_NO_ITERM2=1 for
# every suite; tests that expect a fire unset it explicitly.
_it2_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    mkdir -p "$dir/.cs/local"
    touch "$dir/.cs/local/session.log"
    export CLAUDE_SESSION_NAME="$1"
    export CLAUDE_SESSION_DIR="$dir"
    export CLAUDE_SESSION_META_DIR="$dir/.cs"
    export IT2_LOG="$TEST_TMPDIR/it2.log"
    export CS_IT2_DIR="$TEST_TMPDIR/it2bin"
    export CS_IT2_TTY="$TEST_TMPDIR/tty-sink"
    mkdir -p "$CS_IT2_DIR"
    printf '#!/bin/sh\necho "$@" >> "%s"\n' "$IT2_LOG" > "$CS_IT2_DIR/it2attention"
    chmod +x "$CS_IT2_DIR/it2attention"
}

test_stop_hook_bounces_dock_in_iterm() {
    _it2_session "bounce"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "start" "turn end should start the bounce" || return 1
}

test_no_bounce_outside_iterm() {
    _it2_session "notiterm"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="Apple_Terminal"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: it2attention fired outside iTerm2: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_no_bounce_when_disabled() {
    _it2_session "killed"
    export CS_NO_ITERM2=1
    export TERM_PROGRAM="iTerm.app"
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || true
    if [ -f "$IT2_LOG" ]; then
        echo "  FAIL: CS_NO_ITERM2 must disable the bounce: $(cat "$IT2_LOG")"
        return 1
    fi
}

test_missing_it2_tool_is_silent_and_harmless() {
    _it2_session "notool"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    rm -f "$CS_IT2_DIR/it2attention"
    local ec=0
    echo '{}' | bash "$HOOKS_DIR/narrative-reminder.sh" >/dev/null 2>&1 || ec=$?
    assert_eq "0" "$ec" "hook must not fail when it2 is absent" || return 1
}

test_prompt_hook_stops_the_bounce() {
    _it2_session "stopper"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"prompt":"back at the keyboard"}' | bash "$HOOKS_DIR/scope-prompt.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "a new prompt should stop the bounce" || return 1
}

test_session_start_stops_the_bounce() {
    _it2_session "starter"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    touch "$CLAUDE_SESSION_META_DIR/local/attention"
    echo '{"source":"resume"}' | bash "$HOOKS_DIR/session-start.sh" >/dev/null 2>&1 || true
    [ -f "$IT2_LOG" ] || { echo "  FAIL: it2attention never ran"; return 1; }
    assert_file_contains "$IT2_LOG" "stop" "session start should stop a stale bounce" || return 1
}

test_doctor_reports_iterm2_surface() {
    _it2_session "docsess"
    unset CS_NO_ITERM2
    export TERM_PROGRAM="iTerm.app"
    local out
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "iTerm2" "doctor should mention iTerm2 inside it" || return 1
    assert_output_contains "$out" "attention bounce active" "it2 present reads as active" || return 1

    rm -f "$CS_IT2_DIR/it2attention"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_contains "$out" "shell integration not installed" \
        "missing it2 reads as tab-color-only" || return 1

    export TERM_PROGRAM="Apple_Terminal"
    out=$(cd "$CLAUDE_SESSION_DIR" && "$CS_BIN" -doctor 2>&1) || true
    assert_output_not_contains "$out" "iTerm2" "doctor stays silent outside iTerm2" || return 1
}

# A claude install laid out like the native installer's: bin/claude is a
# symlink to versions/<version>, the stub there prints its argv0 and its
# environment. A fake tmux answers the control-mode query with $FAKE_CC and
# accepts everything else. The ambient env is iTerm2 reached through tmux.
_tab_launch_env() {  # control_mode
    local inst="$TEST_TMPDIR/inst"
    mkdir -p "$inst/versions" "$inst/bin"
    printf '#!/usr/bin/env bash\necho "argv0=$0"\nenv\n' > "$inst/versions/9.9.9"
    chmod +x "$inst/versions/9.9.9"
    ln -sf ../versions/9.9.9 "$inst/bin/claude"
    cat > "$inst/bin/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
case "$*" in
    *client_control_mode*) echo "$FAKE_CC" ;;
esac
exit 0
TMUX_EOF
    chmod +x "$inst/bin/tmux"
    export PATH="$inst/bin:$PATH"
    export CS_TMUX_BIN="$inst/bin/tmux"
    export FAKE_CC="$1"
    export TMUX="/tmp/fake-tmux-socket,1,0"
    export TERM=xterm-256color TERM_PROGRAM=tmux TERM_PROGRAM_VERSION=3.7c
    export LC_TERMINAL=iTerm2 LC_TERMINAL_VERSION=3.7.1
    unset CLAUDE_CODE_BIN CS_NO_ITERM2
}

# The value of NAME in the stub's printed environment, or the argv0 line.
_launched() {  # output name
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

test_launch_under_iterm_cc_shows_loader_and_icon() {
    _tab_launch_env 1
    local out argv0
    out=$("$CS_BIN" tabsess <<< "" 2>&1) || true
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" \
        "claude must see iTerm.app so it sends the progress loader" || return 1
    assert_eq "3.7.1" "$(_launched "$out" TERM_PROGRAM_VERSION)" \
        "the version claude gates the loader on is iTerm's own" || return 1
    argv0=$(_launched "$out" argv0)
    assert_eq "claude" "$(basename "$argv0")" \
        "claude must run under the name iTerm maps to its icon" || return 1
    [ "$argv0" -ef "$TEST_TMPDIR/inst/versions/9.9.9" ] || {
        echo "  FAIL: launched $argv0 is not the installed version file"; return 1; }
    [ ! -L "$argv0" ] || { echo "  FAIL: $argv0 is a symlink, its process name stays the version"; return 1; }
}

run_test test_launch_under_iterm_cc_shows_loader_and_icon
run_test test_stop_hook_bounces_dock_in_iterm
run_test test_no_bounce_outside_iterm
run_test test_no_bounce_when_disabled
run_test test_missing_it2_tool_is_silent_and_harmless
run_test test_prompt_hook_stops_the_bounce
run_test test_session_start_stops_the_bounce
run_test test_doctor_reports_iterm2_surface

report_results
