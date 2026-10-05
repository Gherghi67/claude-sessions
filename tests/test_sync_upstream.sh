#!/usr/bin/env bash
# ABOUTME: Tests for scripts/sync-upstream.py, which merges an upstream release into the fork.
# ABOUTME: A fixture upstream, a fork that rebrands and splits it, and an upstream release to merge.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
SYNC="$SCRIPT_DIR/../scripts/sync-upstream.py"

# Upstream v1: a state fragment, a mail fragment that names the command and
# reads the session variables, a companion script, a build that commits bin/cs.
make_upstream() {
    UP="$TEST_TMPDIR/upstream"
    mkdir -p "$UP/lib" "$UP/bin"
    git init -q -b main "$UP"
    cat > "$UP/lib/40-state.sh" <<'EOF'
# ABOUTME: Session state.

# Pick a colour for the prompt bar.
_alloc_color() {
    echo red
}

_read_state() {
    cat "$1"
}
EOF
    cat > "$UP/lib/53-mail.sh" <<'EOF'
# ABOUTME: Mail between sessions.

send_mail() {
    [ -n "${CLAUDE_SESSION_META_DIR:-}" ] || return 0
    [ -n "$1" ] || error "cs -msg needs a body"
    echo "$1" >> "$CLAUDE_SESSION_META_DIR/mail"
}

# cs never reads mail twice.
read_mail() {
    cat "$CLAUDE_SESSION_META_DIR/mail"
}
EOF
    printf '#!/usr/bin/env bash\necho "cs-statusline v1"\n' > "$UP/bin/cs-statusline"
    printf '#!/usr/bin/env bash\ncd "$(dirname "$0")"\ncat lib/*.sh > bin/cs\n' > "$UP/build.sh"
    printf 'cs is a session manager.\n' > "$UP/README.md"
    chmod +x "$UP/bin/cs-statusline" "$UP/build.sh"
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v1 && git tag v1)
}

# The fork: Claude's colour helper moves to a fragment of its own, the command
# and variables are renamed (except one comment, kept on purpose), the
# companion becomes bin/ags-statusline with bin/cs-statusline a symlink to it,
# and the README is rewritten by hand.
make_fork() {
    FORK="$TEST_TMPDIR/fork"
    git clone -q "$UP" "$FORK"
    cat > "$FORK/lib/40-state.sh" <<'EOF'
# ABOUTME: Session state.

_read_state() {
    cat "$1"
}
EOF
    cat > "$FORK/lib/42-claude-state.sh" <<'EOF'
# ABOUTME: Claude's own session state.

_claude_only() {
    echo claude
}

# Pick a colour for the prompt bar.
_alloc_color() {
    echo red
}
EOF
    cat > "$FORK/lib/53-mail.sh" <<'EOF'
# ABOUTME: Mail between sessions.

send_mail() {
    [ -n "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ] || return 0
    [ -n "$1" ] || error "ags -msg needs a body"
    echo "$1" >> "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/mail"
}

# cs never reads mail twice.
read_mail() {
    cat "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/mail"
}
EOF
    printf '#!/usr/bin/env bash\necho "ags-statusline v1"\n' > "$FORK/bin/ags-statusline"
    chmod +x "$FORK/bin/ags-statusline"
    rm "$FORK/bin/cs-statusline"
    ln -s ags-statusline "$FORK/bin/cs-statusline"
    printf '#!/usr/bin/env bash\ncd "$(dirname "$0")"\ncat lib/*.sh > bin/ags\nln -sf ags bin/cs\n' > "$FORK/build.sh"
    printf 'ags is the agent-sessions manager.\n' > "$FORK/README.md"
    (cd "$FORK" && git checkout -q -b rebrand && bash build.sh && git add -A && git commit -q -m rebrand)
}

# Upstream v2 changes the moved helper, adds a function beside it, edits the
# renamed lines and the kept comment, the companion and the README.
release_upstream() {
    sed -i.bak 's/echo red/echo blue/' "$UP/lib/40-state.sh"
    printf '\n_is_uuid() {\n    [ -n "$1" ]\n}\n' >> "$UP/lib/40-state.sh"
    sed -i.bak -e 's/cs -msg needs a body/cs -msg needs a non-empty body/' \
        -e 's/echo "\$1" >> /printf "%s\\n" "$1" >> /' \
        -e 's/# cs never reads mail twice\./# cs never reads mail twice, nor drops it./' "$UP/lib/53-mail.sh"
    sed -i.bak 's/v1/v2/' "$UP/bin/cs-statusline"
    printf 'cs is a session manager for Claude Code.\n' > "$UP/README.md"
    rm -f "$UP"/lib/*.bak "$UP"/bin/*.bak
    (cd "$UP" && bash build.sh && git add -A && git commit -q -m v2 && git tag v2)
}

make_fixture() {
    make_upstream && make_fork && release_upstream
}

sync_start() {
    (cd "$FORK" && python3 "$SYNC" start --skip-tests "$@") > "$TEST_TMPDIR/sync.log" 2>&1
}

sync_continue() {
    (cd "$WT" && python3 "$SYNC" continue --skip-tests "$@") > "$TEST_TMPDIR/continue.log" 2>&1
}

resolve_readme() {
    printf 'ags is the agent-sessions manager for Claude Code and Codex.\n' > "$WT/README.md"
}

test_start_translates_upstream_into_the_forks_dialect() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    local status=0
    sync_start || status=$?
    # Only the README, rewritten by hand on both sides, is left for a person.
    assert_eq 1 "$status" || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" '1 left in conflict' || return 1
    assert_file_contains "$WT/README.md" '^<<<<<<< ours' || return 1
    # The moved helper takes upstream's change where the fork keeps it; the
    # function upstream added stays where upstream put it.
    assert_file_contains "$WT/lib/42-claude-state.sh" 'echo blue' || return 1
    assert_file_contains "$WT/lib/42-claude-state.sh" '_claude_only' || return 1
    assert_file_not_contains "$WT/lib/40-state.sh" '_alloc_color' || return 1
    assert_file_contains "$WT/lib/40-state.sh" '_is_uuid()' || return 1
    # Upstream's edits arrive renamed; the comment the fork kept stays upstream's.
    grep -Fqx '    [ -n "$1" ] || error "ags -msg needs a non-empty body"' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: message not renamed"; return 1; }
    grep -Fqx '    printf "%s\n" "$1" >> "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/mail"' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: variable not renamed"; return 1; }
    grep -Fqx '# cs never reads mail twice, nor drops it.' "$WT/lib/53-mail.sh" \
        || { cat "$WT/lib/53-mail.sh"; echo "  FAIL: kept comment renamed"; return 1; }
    # The companion's change lands in the fork's file; the symlink stays.
    assert_eq 'echo "ags-statusline v2"' "$(tail -1 "$WT/bin/ags-statusline")" || return 1
    assert_eq ags-statusline "$(readlink "$WT/bin/cs-statusline")" || return 1
    # Generated files are rebuilt, never merged: bin/cs is still the fork's symlink.
    assert_eq ags "$(readlink "$WT/bin/cs")" || return 1
    # The fork's own checkout is untouched.
    assert_eq rebrand "$(git -C "$FORK" rev-parse --abbrev-ref HEAD)" || return 1
    assert_eq "" "$(git -C "$FORK" status --porcelain)"
}

test_continue_commits_a_merge_the_fork_can_fast_forward_to() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    sync_start
    local status=0
    sync_continue || status=$?
    assert_eq 1 "$status" "continue refuses while markers remain" || return 1
    assert_file_contains "$TEST_TMPDIR/continue.log" 'README.md' || return 1
    resolve_readme
    sync_continue --trailer "Co-Authored-By: Test <t@example.com>" \
        || { cat "$TEST_TMPDIR/continue.log"; return 1; }
    # A real merge: the fork's tip and the release are both parents.
    assert_eq "$(git -C "$FORK" rev-parse rebrand) $(git -C "$FORK" rev-parse 'v2^{commit}')" \
        "$(git -C "$WT" log -1 --format=%P)" || return 1
    git -C "$WT" log -1 --format=%B | grep -q '^Co-Authored-By: Test' || { echo "  FAIL: no trailer"; return 1; }
    assert_eq "" "$(git -C "$WT" status --porcelain)" || return 1
    # build.sh ran: bin/ags carries the merged sources.
    assert_file_contains "$WT/bin/ags" 'echo blue' || return 1
    git -C "$FORK" merge -q --ff-only sync/v2 || return 1
    # Merged once, a rerun finds nothing to do.
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" 'Already contains v2'
}

test_continue_refuses_a_function_defined_in_two_fragments() {
    make_fixture || return 1
    WT="$TEST_TMPDIR/fork-sync-v2"
    sync_start
    resolve_readme
    printf '\n_claude_only() {\n    echo twice\n}\n' >> "$WT/lib/40-state.sh"
    local status=0
    sync_continue || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/continue.log" '_claude_only: lib/40-state.sh, lib/42-claude-state.sh' || return 1
    # Nothing was committed: the merge is still in progress.
    git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "  FAIL: merge was committed"; return 1; }
}

test_start_refuses_uncommitted_work() {
    make_fixture || return 1
    printf 'draft\n' >> "$FORK/README.md"
    local status=0
    sync_start || status=$?
    assert_eq 2 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/sync.log" 'uncommitted changes' || return 1
    assert_not_exists "$TEST_TMPDIR/fork-sync-v2"
}

test_start_merges_an_upstream_that_only_touched_untouched_files() {
    make_upstream && make_fork || return 1
    printf 'notes\n' > "$UP/NOTES.md"
    (cd "$UP" && git add -A && git commit -q -m notes && git tag v1.1)
    WT="$TEST_TMPDIR/fork-sync-v1.1"
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/sync.log" "Committed the merge of v1.1" || return 1
    assert_eq notes "$(cat "$WT/NOTES.md")"
}

# A checkout kept inside another repository (a cs session folder) gets its
# sync worktree beside that repository, not as untracked files inside it.
test_start_puts_the_worktree_outside_an_enclosing_repository() {
    make_upstream || return 1
    git init -q "$TEST_TMPDIR/outer"
    FORK="$TEST_TMPDIR/outer/fork"
    git clone -q "$UP" "$FORK"
    (cd "$FORK" && git checkout -q -b rebrand)
    printf 'notes\n' > "$UP/NOTES.md"
    (cd "$UP" && git add -A && git commit -q -m notes && git tag v1.1)
    sync_start || { cat "$TEST_TMPDIR/sync.log"; return 1; }
    assert_dir "$TEST_TMPDIR/fork-sync-v1.1" || return 1
    assert_not_exists "$TEST_TMPDIR/outer/fork-sync-v1.1"
}

run_test test_start_translates_upstream_into_the_forks_dialect
run_test test_start_puts_the_worktree_outside_an_enclosing_repository
run_test test_continue_commits_a_merge_the_fork_can_fast_forward_to
run_test test_continue_refuses_a_function_defined_in_two_fragments
run_test test_start_refuses_uncommitted_work
run_test test_start_merges_an_upstream_that_only_touched_untouched_files
report_results
