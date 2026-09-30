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
# create makes the container, the one side effect cs relies on.
if [ "$1" = "create" ]; then eval "last=\${$#}"; mkdir -p "$last"; fi
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

# A closed session holding one of everything the vault takes, plus files that stay.
_populated_session() {  # name
    local s="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$s/memory" "$s/plans" "$s/local/mail/inbox" "$s/handoffs" "$s/checkpoints" "$s/narrative-archive"
    printf -- '---\nstatus: active\ntags: []\n---\n\n## Objective\ntest\n' > "$s/README.md"
    echo "narrative" > "$s/memory/narrative.alice.md"
    echo "plan" > "$s/plans/p.md"
    echo "log" > "$s/local/session.log"
    echo "msg" > "$s/local/mail/inbox/1.json"
    echo "h.md" > "$s/local/pending-handoff"
    echo "handoff" > "$s/handoffs/h.md"
    echo "cp" > "$s/checkpoints/c.md"
    echo "old" > "$s/narrative-archive/a.md"
    echo "claude_session_id=x" > "$s/local/state"
    echo "42" > "$s/local/context-pct"
}

test_encrypt_builds_the_vault_and_detaches() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "0" "$rc" "exit 0 (output: $out)" || return 1
    local v="$s/vault-mnt" l
    for l in memory plans claude-config private; do
        [ -L "$s/$l" ] || { echo "  FAIL: .cs/$l is not a link"; return 1; }
        assert_eq "vault-mnt/$l" "$(readlink "$s/$l")" ".cs/$l points into the mount" || return 1
        [ -d "$v/$l" ] || { echo "  FAIL: vault has no $l/"; return 1; }
    done
    assert_eq "narrative" "$(cat "$v/memory/narrative.alice.md")" "narrative moved" || return 1
    assert_eq "plan" "$(cat "$v/plans/p.md")" "plans moved" || return 1
    assert_eq "log" "$(cat "$v/private/session.log")" "session.log moved" || return 1
    assert_eq "msg" "$(cat "$v/private/mail/inbox/1.json")" "mail moved" || return 1
    assert_eq "h.md" "$(cat "$v/private/pending-handoff")" "pending-handoff moved" || return 1
    assert_eq "handoff" "$(cat "$v/private/handoffs/h.md")" "handoffs moved" || return 1
    assert_eq "cp" "$(cat "$v/private/checkpoints/c.md")" "checkpoints moved" || return 1
    assert_eq "old" "$(cat "$v/private/narrative-archive/a.md")" "narrative archive moved" || return 1
    local gone
    for gone in local/session.log local/mail local/pending-handoff handoffs checkpoints narrative-archive; do
        [ ! -e "$s/$gone" ] || { echo "  FAIL: plaintext .cs/$gone left behind"; return 1; }
    done
    assert_eq "claude_session_id=x" "$(cat "$s/local/state")" "ids stay in .cs/local" || return 1
    assert_eq "42" "$(cat "$s/local/context-pct")" "status-line numbers stay in .cs/local" || return 1
    [ -e "$v/.metadata_never_index" ] || { echo "  FAIL: Spotlight opt-out missing"; return 1; }
    [ -x "$s/local/pre-open" ] || { echo "  FAIL: pre-open missing or not executable"; return 1; }
    assert_eq "$(_vault_path enc)" "$(cat "$s/local/vault")" ".cs/local/vault names the container" || return 1
    assert_file_contains "$s/README.md" "^tags: \[encrypted\]$" "tagged encrypted" || return 1
    local c; c=$(_vault_path enc)
    assert_eq "create -size 50g -type SPARSEBUNDLE -fs APFS -encryption AES-256 -volname cs-enc $c
attach -nobrowse -mountpoint $s/vault-mnt $c
detach $s/vault-mnt" "$(cat "$FAKE_HDIUTIL_LOG")" "create, attach, then detach" || return 1
    assert_output_contains "$out" "~/.claude/history.jsonl" "lists copies it could not move" || return 1
}

test_encrypt_refuses_a_readme_it_cannot_tag() {
    _stubs
    create_test_session enc >/dev/null
    local out rc=0
    out=$(_encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: .cs/README.md has no YAML frontmatter to carry the encrypted tag." "names the README" || return 1
    _assert_nothing_written enc || return 1
}

test_encrypt_stops_when_create_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_HDIUTIL_FAIL=create _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: hdiutil create failed; the session is unchanged." "says nothing changed" || return 1
    assert_eq "narrative" "$(cat "$s/memory/narrative.alice.md")" "memory untouched" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: session changed"; return 1; }
}

test_encrypt_stops_when_attach_fails() {
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    out=$(FAKE_HDIUTIL_FAIL=attach _encrypt enc 2>&1) || rc=$?
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: hdiutil could not attach $(_vault_path enc); the session is unchanged. Delete the container before retrying." "names the container" || return 1
    assert_eq "narrative" "$(cat "$s/memory/narrative.alice.md")" "memory untouched" || return 1
    [ ! -L "$s/memory" ] && [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: session changed"; return 1; }
}

test_encrypt_stops_on_a_failed_move_and_names_what_moved() {
    [ "$(id -u)" != "0" ] || { echo "  SKIP: root ignores the permission that makes the move fail"; return 77; }
    _stubs
    _populated_session enc
    local s="$CS_SESSIONS_ROOT/enc/.cs" out rc=0
    chmod 555 "$s/local"
    out=$(_encrypt enc 2>&1) || rc=$?
    chmod 755 "$s/local"
    assert_eq "1" "$rc" "non-zero exit" || return 1
    assert_output_contains "$out" "enc: could not move .cs/local/session.log into the vault. Already moved: .cs/memory .cs/plans. Not moved:" "names moved and unmoved" || return 1
    local l
    for l in memory plans claude-config private; do
        [ ! -L "$s/$l" ] || { echo "  FAIL: .cs/$l linked after a failed move"; return 1; }
    done
    [ ! -e "$s/local/pre-open" ] || { echo "  FAIL: pre-open written after a failed move"; return 1; }
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
run_test test_encrypt_builds_the_vault_and_detaches
run_test test_encrypt_refuses_a_readme_it_cannot_tag
run_test test_encrypt_stops_when_create_fails
run_test test_encrypt_stops_when_attach_fails
run_test test_encrypt_stops_on_a_failed_move_and_names_what_moved
report_results
