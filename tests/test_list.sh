#!/usr/bin/env bash
# ABOUTME: Tests for `cs -list` (list_sessions), including bash 3.2 portability
# ABOUTME: Guards against bash 4+ constructs (associative arrays) breaking the listing

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# -list counts secrets with `security dump-keychain`, so a stand-in comes first
# on PATH for the whole suite and no test here reaches the developer's real
# keychain. It logs each call to $FAKE_SECURITY_LOG and answers dump-keychain
# with the file $FAKE_SECURITY_DUMP, each when set.
_FAKE_SECURITY_BIN="$(mktemp -d)/bin"
mkdir -p "$_FAKE_SECURITY_BIN"
printf '%s\n' '#!/usr/bin/env bash' \
    '[ -n "${FAKE_SECURITY_LOG:-}" ] && printf "%s\n" "$*" >> "$FAKE_SECURITY_LOG"' \
    '[ "${1:-}" = dump-keychain ] && [ -n "${FAKE_SECURITY_DUMP:-}" ] && cat "$FAKE_SECURITY_DUMP"' \
    'exit 0' > "$_FAKE_SECURITY_BIN/security"
chmod +x "$_FAKE_SECURITY_BIN/security"
export PATH="$_FAKE_SECURITY_BIN:$PATH"

# Session alpha with two secrets in the keychain, as dump-keychain prints them,
# and a list run against it with the backend given as $1 ("" for unset). The
# Unicode lock is pinned so the count reads the same on every machine.
_list_with_keychain_secrets() {  # backend
    create_test_session alpha >/dev/null
    printf '%s\n' 'keychain: "/Users/someone/Library/Keychains/login.keychain-db"' \
        'class: "genp"' 'attributes:' \
        '    "acct"<blob>="someone"' \
        '    "svce"<blob>="cs:alpha:API_KEY"' \
        '    "svce"<blob>="cs:alpha:DB_PASS"' > "$TEST_TMPDIR/keychain-dump"
    (
        if [ -n "$1" ]; then export CS_SECRETS_BACKEND="$1"; else unset CS_SECRETS_BACKEND; fi
        FAKE_SECURITY_LOG="$TEST_TMPDIR/security.log" FAKE_SECURITY_DUMP="$TEST_TMPDIR/keychain-dump" \
            CS_NERD_FONTS=0 "$CS_BIN" -list 2>&1
    )
}

# The keychain is the store ags-secrets uses, so -list counts alpha's two.
test_list_counts_keychain_secrets_under_the_keychain_backend() {
    local out
    out=$(_list_with_keychain_secrets keychain) || {
        echo "  FAIL: ags -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha (⚿ 2)" "the keychain backend shows the keychain count" || return 1
}

# A plain install picks the keychain on macOS, and its listing is unchanged.
test_list_counts_keychain_secrets_with_no_backend_set() {
    local out
    out=$(_list_with_keychain_secrets "") || {
        echo "  FAIL: ags -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha (⚿ 2)" "an unset backend keeps the keychain count" || return 1
}

# Under the encrypted backend (the ags profile's) the keychain holds the stable
# install's secrets: cs:alpha:* there belongs to its alpha, not this one. -list
# must neither read the keychain nor show that count.
test_list_skips_the_keychain_under_the_encrypted_backend() {
    local out
    out=$(_list_with_keychain_secrets encrypted) || {
        echo "  FAIL: ags -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "alpha is still listed" || return 1
    assert_output_not_contains "$out" "⚿" "no count comes from another store" || return 1
    assert_file_not_exists "$TEST_TMPDIR/security.log" "ags -list must not call security at all" || return 1
}

# `cs -list` renders the session table under the current bash.
test_list_renders_sessions() {
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "ags -list should list session alpha" || return 1
    assert_output_contains "$out" "beta" "ags -list should list session beta"
}

# `cs -list` must work under bash <4 (no associative arrays), e.g. macOS stock
# /bin/bash 3.2. Regression: list_sessions used `local -A`, which aborts there
# with "local: -A: invalid option" under set -euo pipefail. Skips when no such
# bash is available (e.g. Linux where /bin/bash is modern).
test_list_runs_under_old_bash() {
    local old_bash=/bin/bash
    if [ ! -x "$old_bash" ] || "$old_bash" -c 'declare -A _x' 2>/dev/null; then
        echo "    SKIP: no bash lacking associative arrays available"
        return 77
    fi
    create_test_session alpha >/dev/null
    create_test_session beta >/dev/null
    local out rc=0
    out=$("$old_bash" "$CS_BIN" -list 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL: cs -list aborted under bash <4 (rc=$rc)"
        echo "    output: $out"
        return 1
    fi
    assert_output_contains "$out" "alpha" "ags -list should list alpha under bash <4" || return 1
    assert_output_contains "$out" "beta" "ags -list should list beta under bash <4"
}

# A non-session directory under the sessions root (editor config, an empty cs
# artifact) must not be listed, so that -list and tab-completion agree on what a
# session is.
test_list_omits_non_session_directories() {
    create_test_session alpha >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.obsidian"
    mkdir -p "$CS_SESSIONS_ROOT/worktrees"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "alpha" "ags -list should list a real session" || return 1
    assert_output_not_contains "$out" ".obsidian" "ags -list should omit editor config" || return 1
    assert_output_not_contains "$out" "worktrees" "ags -list should omit the empty worktrees holder" || return 1
}

# A pre-.cs/ session keeps its state beside a root CLAUDE.md; -list still shows it.
test_list_includes_a_legacy_session() {
    local legacy="$CS_SESSIONS_ROOT/legacy"
    mkdir -p "$legacy/logs"
    echo "# Session" > "$legacy/CLAUDE.md"
    local out
    out=$("$CS_BIN" -list 2>&1) || {
        echo "  FAIL: cs -list exited non-zero"
        echo "    output: $out"
        return 1
    }
    assert_output_contains "$out" "legacy" "ags -list should list a pre-.cs/ session" || return 1
}

test_tui_launch_exports_the_cs_binary_path() {
    # The picker forks cs back for its own subcommands, so cs must hand it its
    # own path. The launch itself needs a tty and a resolved cs-tui, neither of
    # which a test has, so pin the exported assignment in the built binary.
    assert_file_contains "$CS_BIN" 'CS_BIN="\$0"' "cs must export its own path to the picker" || return 1
}

echo ""
echo "cs -list tests"
echo "=============="
echo ""

run_test test_list_renders_sessions
run_test test_list_omits_non_session_directories
run_test test_list_includes_a_legacy_session
run_test test_list_runs_under_old_bash
run_test test_list_counts_keychain_secrets_under_the_keychain_backend
run_test test_list_counts_keychain_secrets_with_no_backend_set
run_test test_list_skips_the_keychain_under_the_encrypted_backend
run_test test_tui_launch_exports_the_cs_binary_path

report_results
