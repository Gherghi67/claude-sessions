#!/usr/bin/env bash
# ABOUTME: Tests for cs -encrypt: the refusals, the vault it builds for an existing session,
# ABOUTME: and how it stops. hdiutil, uname and mount are PATH stubs that log every call.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

# PATH stubs: uname answers $FAKE_UNAME; hdiutil logs its argv, one call per
# line, and fails the verb named in $FAKE_HDIUTIL_FAIL.
_stubs() {
    local d="$TEST_TMPDIR/stub"
    mkdir -p "$d"
    cat > "$d/uname" <<'EOF'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
EOF
    cat > "$d/hdiutil" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_HDIUTIL_LOG"
[ "$1" = "${FAKE_HDIUTIL_FAIL:-}" ] && { echo "hdiutil: $1 failed - stub" >&2; exit 1; }
exit 0
EOF
    chmod +x "$d/uname" "$d/hdiutil"
    export PATH="$d:$PATH"
    export FAKE_HDIUTIL_LOG="$TEST_TMPDIR/hdiutil.log"
    : > "$FAKE_HDIUTIL_LOG"
}

_encrypt() {  # name -> runs cs -encrypt as a human at a terminal would
    CS_ASSUME_TTY=1 "$CS_BIN" -encrypt "$@" </dev/null
}

_vault_path() {  # name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# A refusal writes nothing: no hdiutil call, no vault links, no pre-open.
_assert_nothing_written() {  # name
    local s="$CS_SESSIONS_ROOT/$1/.cs"
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
    local l
    for l in memory plans claude-config private; do
        [ ! -L "$s/$l" ] || { echo "  FAIL: .cs/$l became a link"; return 1; }
    done
    [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: pre-open written"; return 1; }
    [ ! -e "$(_vault_path "$1")" ] || { echo "  FAIL: container created"; return 1; }
}

test_encrypt_refuses_off_macos() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$(FAKE_UNAME=Linux _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs -encrypt needs macOS (hdiutil); Linux is not supported yet." "names the platform" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_without_a_terminal() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$("$CS_BIN" -encrypt enc </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "cs -encrypt asks for the vault password; run it from a terminal." "says why" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_a_live_session() {
    _stubs
    create_test_session enc >/dev/null
    sleep 300 &
    local live_pid=$! out rc=0
    echo "$live_pid" > "$CS_SESSIONS_ROOT/enc/.cs/session.lock"
    out=$(_encrypt enc 2>&1) || rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: the session is running; close it, then encrypt." "names the live session" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_refuses_an_unknown_session() {
    _stubs
    local out rc=0
    out=$(_encrypt ghost-town 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "No such session: ghost-town" "names the missing session" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_an_adopted_session() {
    _stubs
    mkdir -p "$TEST_TMPDIR/project/.cs/memory" "$TEST_TMPDIR/project/.cs/local"
    ln -s "$TEST_TMPDIR/project" "$CS_SESSIONS_ROOT/adopted"
    local out rc=0
    out=$(_encrypt adopted 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "adopted: an adopted session cannot be encrypted" "names the adopted session" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_a_feature_worktree_name() {
    _stubs
    local out rc=0
    out=$(_encrypt enc@task 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc@task: encrypt the base session, not a feature worktree" "names the worktree" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_when_any_vault_link_exists() {
    _stubs
    local l
    for l in memory plans claude-config private; do
        rm -rf "${CS_SESSIONS_ROOT:?}/enc"
        create_test_session enc >/dev/null
        rm -rf "$CS_SESSIONS_ROOT/enc/.cs/$l"
        ln -s "$TEST_TMPDIR/elsewhere/$l" "$CS_SESSIONS_ROOT/enc/.cs/$l"
        local out rc=0
        out=$(_encrypt enc 2>&1) || rc=$?
        assert_eq "1" "$rc" "non-zero exit with .cs/$l linked" || return 1
        assert_output_contains "$out" "enc: .cs/$l is already a link; the session is encrypted, or half set up by hand." "names .cs/$l" || return 1
        assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called ($l)" || return 1
    done
}

test_encrypt_refuses_an_existing_pre_open() {
    _stubs
    create_test_session enc >/dev/null
    printf '#!/bin/sh\necho mine\n' > "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open"
    local before out rc=0
    before=$(cat "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open")
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: .cs/local/pre-open already exists; cs -encrypt writes its own. Move yours aside first." "names the hook" || return 1
    assert_eq "$before" "$(cat "$CS_SESSIONS_ROOT/enc/.cs/local/pre-open")" "pre-open unchanged" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

test_encrypt_refuses_an_existing_container() {
    _stubs
    create_test_session enc >/dev/null
    mkdir -p "$(_vault_path enc)"
    local out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: $(_vault_path enc) already exists; cs -encrypt will not reuse or overwrite it." "names the container" || return 1
    assert_eq "" "$(cat "$FAKE_HDIUTIL_LOG")" "hdiutil never called" || return 1
}

run_test test_encrypt_refuses_off_macos
run_test test_encrypt_refuses_without_a_terminal
run_test test_encrypt_refuses_a_live_session
run_test test_encrypt_refuses_an_unknown_session
run_test test_encrypt_refuses_an_adopted_session
run_test test_encrypt_refuses_a_feature_worktree_name
run_test test_encrypt_refuses_when_any_vault_link_exists
run_test test_encrypt_refuses_an_existing_pre_open
run_test test_encrypt_refuses_an_existing_container
report_results
