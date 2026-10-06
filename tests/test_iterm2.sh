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

# Claude Code reads iTerm.app plus a TERM outside screen*/tmux* as tmux -CC.
# In plain tmux with such a TERM that would be false, so claude keeps tmux's
# name there; with a tmux TERM the reading cannot misfire and the loader works.
test_plain_tmux_keeps_tmux_name_unless_term_is_tmux() {
    _tab_launch_env 0
    local out
    out=$("$CS_BIN" plaintmux <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" \
        "plain tmux with an xterm TERM must not look like tmux -CC to claude" || return 1
    export TERM=tmux-256color
    out=$("$CS_BIN" plaintmux <<< "" 2>&1) || true
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" \
        "plain tmux with a tmux TERM gets the loader" || return 1
}

test_outside_iterm_launch_is_untouched() {
    _tab_launch_env 1
    unset LC_TERMINAL
    local out
    out=$("$CS_BIN" notiterm <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" "no iTerm2, no rename" || return 1
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "no iTerm2, claude runs as found on PATH" || return 1
}

test_iterm_integrations_off_leaves_launch_untouched() {
    _tab_launch_env 1
    export CS_NO_ITERM2=1
    local out
    out=$("$CS_BIN" itermoff <<< "" 2>&1) || true
    assert_eq "tmux" "$(_launched "$out" TERM_PROGRAM)" "CS_NO_ITERM2 keeps tmux's name" || return 1
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "CS_NO_ITERM2 runs claude as found on PATH" || return 1
}

# After a claude update the link still names the old version's file; the next
# launch must run the version bin/claude now points at.
test_link_follows_a_claude_update() {
    _tab_launch_env 1
    "$CS_BIN" before-update <<< "" > /dev/null 2>&1 || true
    printf '#!/usr/bin/env bash\necho "argv0=$0"\necho "version=10.0.0"\n' > "$TEST_TMPDIR/inst/versions/10.0.0"
    chmod +x "$TEST_TMPDIR/inst/versions/10.0.0"
    ln -sf ../versions/10.0.0 "$TEST_TMPDIR/inst/bin/claude"
    local out
    out=$("$CS_BIN" after-update <<< "" 2>&1) || true
    assert_eq "10.0.0" "$(_launched "$out" version)" "the updated claude must run" || return 1
    assert_eq "claude" "$(basename "$(_launched "$out" argv0)")" "still under the name claude" || return 1
}

# Each version gets its own link, so a launch that resolved one version runs
# that version even if another launch links a newer one before it execs.
# A link outlives its version only until the installer removes that file.
test_each_version_has_its_own_link() {
    _tab_launch_env 1
    local inst="$TEST_TMPDIR/inst" out old new
    out=$("$CS_BIN" v-old <<< "" 2>&1) || true
    old=$(_launched "$out" argv0)
    printf '#!/usr/bin/env bash\necho "argv0=$0"\n' > "$inst/versions/10.0.0"
    chmod +x "$inst/versions/10.0.0"
    ln -sf ../versions/10.0.0 "$inst/bin/claude"
    out=$("$CS_BIN" v-new <<< "" 2>&1) || true
    new=$(_launched "$out" argv0)
    [ "$old" != "$new" ] || { echo "  FAIL: both versions ran from one path: $old"; return 1; }
    [ "$old" -ef "$inst/versions/9.9.9" ] || {
        echo "  FAIL: linking 10.0.0 changed what $old runs"; return 1; }
    # A launch may still be waiting to exec a link it picked moments ago, so a
    # link whose version is gone stays until nothing has picked it for a day.
    rm "$inst/versions/9.9.9"
    "$CS_BIN" v-recent <<< "" > /dev/null 2>&1 || true
    [ -e "$old" ] || { echo "  FAIL: $old went while a launch may still need it"; return 1; }
    touch -t 202001010000 "$(dirname "$old")"
    "$CS_BIN" v-pruned <<< "" > /dev/null 2>&1 || true
    [ ! -e "$old" ] || { echo "  FAIL: $old kept a removed version alive"; return 1; }
}

# The launch sites expand CLAUDE_CODE_BIN unquoted (it may carry arguments),
# so a link path with a space in it would be split; such a HOME gets no link.
test_home_with_a_space_runs_claude_as_found() {
    _tab_launch_env 1
    export HOME="$TEST_TMPDIR/a home"
    mkdir -p "$HOME"
    local out
    out=$("$CS_BIN" spacehome <<< "" 2>&1) || true
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "a HOME with a space must not break the launch" || return 1
}

# The icon is cosmetic: a launch that cannot make the link runs claude anyway.
test_unlinkable_claude_still_launches() {
    _tab_launch_env 1
    mkdir -p "$HOME/.local/share"
    : > "$HOME/.local/share/cs"
    local out
    out=$("$CS_BIN" nolink <<< "" 2>&1) || true
    assert_eq "$TEST_TMPDIR/inst/bin/claude" "$(_launched "$out" argv0)" \
        "with no place for the link, claude runs as found on PATH" || return 1
    assert_eq "iTerm.app" "$(_launched "$out" TERM_PROGRAM)" "the loader does not need the link" || return 1
}

# The links live under CS_DATA_DIR, which the ags profile points at its own
# home: the profile never runs from, or prunes, the stable install's links.
test_links_live_under_cs_data_dir() {
    _tab_launch_env 1
    local CS_DATA_DIR="$TEST_TMPDIR/profile-data"; export CS_DATA_DIR
    local out
    out=$("$CS_BIN" datadir <<< "" 2>&1) || true
    assert_eq "$CS_DATA_DIR/claude/9.9.9/claude" "$(_launched "$out" argv0)" \
        "the link is made under CS_DATA_DIR" || return 1
    assert_not_exists "$HOME/.local/share/cs/claude" "nothing is linked under the default data dir"
}

test_user_chosen_claude_binary_is_run_as_given() {
    _tab_launch_env 1
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/inst/versions/9.9.9"
    local out
    out=$("$CS_BIN" ownbin <<< "" 2>&1) || true
    assert_eq "$TEST_TMPDIR/inst/versions/9.9.9" "$(_launched "$out" argv0)" \
        "a CLAUDE_CODE_BIN the user set is never swapped for the link" || return 1
}

# An npm install resolves claude to a cli.js that loads files beside it; run
# from a hard link elsewhere it would lose them. Only the native installer's
# self-contained versions/<version> file is linked.
test_npm_shaped_claude_is_not_linked() {
    _tab_launch_env 1
    local inst="$TEST_TMPDIR/inst"
    mkdir -p "$inst/lib/node_modules/claude-code"
    cp "$inst/versions/9.9.9" "$inst/lib/node_modules/claude-code/cli.js"
    ln -sf ../lib/node_modules/claude-code/cli.js "$inst/bin/claude"
    local out
    out=$("$CS_BIN" npmclaude <<< "" 2>&1) || true
    assert_eq "$inst/bin/claude" "$(_launched "$out" argv0)" \
        "a claude that is not a versions/<version> file runs as found on PATH" || return 1
}

run_test test_launch_under_iterm_cc_shows_loader_and_icon
run_test test_npm_shaped_claude_is_not_linked
run_test test_plain_tmux_keeps_tmux_name_unless_term_is_tmux
run_test test_outside_iterm_launch_is_untouched
run_test test_iterm_integrations_off_leaves_launch_untouched
run_test test_link_follows_a_claude_update
run_test test_each_version_has_its_own_link
run_test test_home_with_a_space_runs_claude_as_found
run_test test_unlinkable_claude_still_launches
run_test test_links_live_under_cs_data_dir
run_test test_user_chosen_claude_binary_is_run_as_given
run_test test_stop_hook_bounces_dock_in_iterm
run_test test_no_bounce_outside_iterm
run_test test_no_bounce_when_disabled
run_test test_missing_it2_tool_is_silent_and_harmless
run_test test_prompt_hook_stops_the_bounce
run_test test_session_start_stops_the_bounce
run_test test_doctor_reports_iterm2_surface

report_results
