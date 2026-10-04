#!/usr/bin/env bash
# ABOUTME: Tests for `cs -adopt --worktrees`, which registers Claude Code's own .claude/worktrees/* as sessions.
# ABOUTME: Covers naming, conversation binding, the clean PR branch, idempotent re-runs, pruning and --dry-run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

UUID_A="aaaa1111-2222-4333-8444-555566667777"
UUID_B="bbbb1111-2222-4333-8444-555566667777"

# A repo with a tracked CLAUDE.md and one Claude Code worktree per name under
# .claude/worktrees/, the layout `claude --worktree` leaves behind.
_make_repo() {  # repo_dir, worktree...
    local repo="$1"; shift
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "john.doe@example.com"
    git -C "$repo" config user.name "John Doe"
    git -C "$repo" config core.autocrlf false
    printf '# Project rules\n' > "$repo/CLAUDE.md"
    git -C "$repo" add CLAUDE.md
    git -C "$repo" commit -q -m "init"
    mkdir -p "$repo/.claude/worktrees"
    local wt
    for wt in "$@"; do
        git -C "$repo" worktree add -q -b "$wt" ".claude/worktrees/$wt" >/dev/null 2>&1
    done
}

# Claude's transcript dir for a worktree, as the lib encodes it.
_wt_project_dir() {  # wt_dir
    printf '%s' "$CS_TRANSCRIPTS_DIR/$(cd "$1" && pwd -P | tr '/.' '--')"
}

_seed_conversation() {  # wt_dir, uuid, first_prompt
    local proj
    proj=$(_wt_project_dir "$1")
    mkdir -p "$proj"
    printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$3" > "$proj/$2.jsonl"
}

_readme_objective() {  # session_dir
    sed -n '/^## Objective/,/^## /{/^## Objective/d;/^## /d;/^$/d;p;}' "$1/.cs/README.md" | head -1
}

test_refuses_outside_a_git_repo() {
    local plain="$TEST_TMPDIR/plain"
    mkdir -p "$plain"
    local output rc=0
    output=$(cd "$plain" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_eq "1" "$rc" "adopt --worktrees outside a repo exits 1" || return 1
    assert_output_contains "$output" "not inside a git repository" "the refusal says why" || return 1
}

test_refuses_a_repo_without_claude_worktrees() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo"
    rmdir "$repo/.claude/worktrees"
    local output rc=0
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || rc=$?
    assert_eq "1" "$rc" "a repo with no .claude/worktrees exits 1" || return 1
    assert_output_contains "$output" "$repo/.claude/worktrees" "the refusal names the directory it looked for" || return 1
}

test_adopts_a_worktree_with_a_conversation() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" brave-jang-0f6265
    local wt="$repo/.claude/worktrees/brave-jang-0f6265"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    local claude_md_before
    claude_md_before=$(cat "$wt/CLAUDE.md")

    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) \
        || { echo "  FAIL: adopt --worktrees should succeed"; return 1; }

    local link="$CS_SESSIONS_ROOT/repo.brave-jang-0f6265"
    [ -L "$link" ] || { echo "  FAIL: no session link at $link"; return 1; }
    assert_eq "$(cd "$wt" && pwd -P)" "$(cd "$link" && pwd -P)" "the link resolves to the worktree" || return 1
    assert_dir "$wt/.cs/local" "the worktree carries session records" || return 1
    assert_eq "$UUID_A" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state binds the worktree's conversation" || return 1
    assert_eq "repo.brave-jang-0f6265" "$(awk '/^session_name:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the state records the session name the hooks resolve" || return 1
    if grep -q '^cs_base:' "$wt/.cs/local/state"; then
        echo "  FAIL: an adopted worktree is a peer, not a task of a base: cs_base must be absent"
        return 1
    fi
    assert_eq "Rewrite the electron UI shell for the desktop app" "$(_readme_objective "$wt")" \
        "the Objective is the conversation's first prompt" || return 1
    assert_eq "$claude_md_before" "$(cat "$wt/CLAUDE.md")" "the tracked CLAUDE.md is untouched" || return 1
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the worktree's PR branch stays clean" || return 1
}

test_skips_a_worktree_without_a_conversation() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" quiet-wt
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: should succeed with nothing to adopt"; return 1; }
    assert_not_exists "$repo/.claude/worktrees/quiet-wt/.cs" "no records for a worktree nobody talked in" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.quiet-wt" ] && { echo "  FAIL: no session link for a skipped worktree"; return 1; }
    assert_output_contains "$output" "skip quiet-wt: no conversation" "the skip names the worktree and the reason" || return 1
}

test_binds_the_newest_of_two_conversations() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" busy-wt
    local wt="$repo/.claude/worktrees/busy-wt"
    _seed_conversation "$wt" "$UUID_A" "The older conversation about the shell"
    sleep 1
    _seed_conversation "$wt" "$UUID_B" "The newer conversation about the menu"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "$UUID_B" "$(awk '/^claude_session_id:/ { print $2; exit }' "$wt/.cs/local/state")" \
        "the newest transcript is the one a resume would continue" || return 1
    assert_eq "The newer conversation about the menu" "$(_readme_objective "$wt")" \
        "the Objective comes from the bound conversation" || return 1
}

test_rerun_adopts_nothing_twice_and_keeps_the_exclude_file() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-one
    local wt="$repo/.claude/worktrees/wt-one"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    local exclude="$repo/.git/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    printf 'my-own-rule.tmp\n' > "$exclude"

    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: first run should succeed"; return 1; }
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: re-run should succeed"; return 1; }
    assert_output_contains "$output" "skip wt-one: already carries .cs/" "the re-run reports the skip" || return 1
    assert_eq "1" "$(find "$CS_SESSIONS_ROOT" -maxdepth 1 -name 'repo.wt-one' | wc -l | tr -d ' ')" "one link, not two" || return 1
    assert_eq "my-own-rule.tmp
.cs/
.claude/settings.local.json
CLAUDE.local.md" "$(cat "$exclude")" "the user's rule stays and cs's three lines appear once" || return 1
}

test_dry_run_writes_nothing() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-one
    local wt="$repo/.claude/worktrees/wt-one"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    # git init seeds info/exclude from its template; the dry run must leave it as found.
    local exclude_before
    exclude_before=$(cat "$repo/.git/info/exclude" 2>/dev/null || echo "<absent>")
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees --dry-run 2>&1) || { echo "  FAIL: dry run should succeed"; return 1; }
    assert_output_contains "$output" "would adopt wt-one as 'repo.wt-one'" "the dry run names what it would do" || return 1
    assert_not_exists "$wt/.cs" "no records written" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.wt-one" ] && { echo "  FAIL: no link written on a dry run"; return 1; }
    assert_eq "$exclude_before" "$(cat "$repo/.git/info/exclude" 2>/dev/null || echo "<absent>")" "the exclude file is as git left it" || return 1
}

test_rerun_prunes_a_link_whose_worktree_is_gone() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" wt-gone
    local wt="$repo/.claude/worktrees/wt-gone"
    _seed_conversation "$wt" "$UUID_A" "Rewrite the electron UI shell for the desktop app"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: first run should succeed"; return 1; }
    # Claude Code removes the worktree once its branch lands.
    git -C "$repo" worktree remove --force .claude/worktrees/wt-gone
    [ -L "$CS_SESSIONS_ROOT/repo.wt-gone" ] || { echo "  FAIL: fixture: the link should dangle now"; return 1; }
    # A hand-made link that merely resembles ours must survive.
    ln -s "$TEST_TMPDIR/elsewhere" "$CS_SESSIONS_ROOT/repo.hand-made"

    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || { echo "  FAIL: re-run should succeed"; return 1; }
    assert_output_contains "$output" "Pruned repo.wt-gone" "the prune is reported" || return 1
    [ -L "$CS_SESSIONS_ROOT/repo.wt-gone" ] && { echo "  FAIL: the dangling link should be gone"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/repo.hand-made" ] || { echo "  FAIL: a link not pointing into .claude/worktrees is not ours to prune"; return 1; }
}

test_same_worktree_name_under_two_repos_opens_the_right_one() {
    local repo_a="$TEST_TMPDIR/alpha" repo_b="$TEST_TMPDIR/beta"
    _make_repo "$repo_a" agent-a018e313
    _make_repo "$repo_b" agent-a018e313
    _seed_conversation "$repo_a/.claude/worktrees/agent-a018e313" "$UUID_A" "Alpha work on the shell"
    _seed_conversation "$repo_b/.claude/worktrees/agent-a018e313" "$UUID_B" "Beta work on the menu"
    (cd "$repo_a" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: alpha adopt should succeed"; return 1; }
    (cd "$repo_b" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: beta adopt should succeed"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/alpha.agent-a018e313" ] && [ -L "$CS_SESSIONS_ROOT/beta.agent-a018e313" ] \
        || { echo "  FAIL: both sessions should exist"; return 1; }

    # The stub records claude's argv; a bound session asks to resume and `y` resumes it.
    cat > "$TEST_TMPDIR/claude-stub" << SCRIPT
#!/bin/bash
printf '<%s>' "\$@" >> "$TEST_TMPDIR/claude-args"; echo >> "$TEST_TMPDIR/claude-args"
exit 0
SCRIPT
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    local output
    output=$("$CS_BIN" beta.agent-a018e313 <<< "y" 2>&1) || true
    assert_output_not_contains "$output" "Base session not found" "a dotted name never enters the base@task path" || return 1
    assert_output_contains "$(cat "$TEST_TMPDIR/claude-args" 2>/dev/null)" "<--resume><$UUID_B>" \
        "opening beta's worktree resumes beta's conversation" || return 1
    assert_eq "" "$(git -C "$repo_b/.claude/worktrees/agent-a018e313" status --porcelain)" \
        "the open's own files (settings.local.json, CLAUDE.local.md) stay out of git status" || return 1
}

test_a_symlink_to_another_project_is_not_adopted() {
    local repo="$TEST_TMPDIR/repo" other="$TEST_TMPDIR/other-project"
    _make_repo "$repo"
    mkdir -p "$other"
    ln -s "$other" "$repo/.claude/worktrees/sneaky"
    _seed_conversation "$other" "$UUID_A" "Work that belongs to another project"
    local output
    output=$(cd "$repo" && "$CS_BIN" -adopt --worktrees 2>&1) || true
    assert_not_exists "$other/.cs" "a directory outside the repo gets no .cs/" || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/repo.sneaky" "no session is registered for it" || return 1
    assert_output_contains "$output" "skip sneaky: not a worktree of" "the skip says why" || return 1
}

test_open_leaves_a_tracked_claude_md_with_cs_markers_alone() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" marked
    local wt="$repo/.claude/worktrees/marked"
    printf '# Project rules\n\n## Discovered Commands\n\n- make test\n\n<!-- cs:session-protocol -->\nold protocol text\n' > "$wt/CLAUDE.md"
    git -C "$wt" commit -q -am "rules with old cs markers"
    _seed_conversation "$wt" "$UUID_A" "Tidy the release notes"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/claude-stub"
    chmod +x "$TEST_TMPDIR/claude-stub"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude-stub"
    "$CS_BIN" repo.marked <<< "y" >/dev/null 2>&1 || true
    assert_eq "" "$(git -C "$wt" status --porcelain)" "the open changes no tracked file" || return 1
    assert_eq "- make test" "$(sed -n 5p "$wt/CLAUDE.md")" "the Discovered Commands section survives" || return 1
}

test_an_exclude_file_without_a_final_newline_keeps_its_last_rule() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" tidy
    _seed_conversation "$repo/.claude/worktrees/tidy" "$UUID_A" "Tidy the release notes"
    printf 'my-own-rule.tmp' > "$repo/.git/info/exclude"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    assert_eq "my-own-rule.tmp" "$(sed -n 1p "$repo/.git/info/exclude")" "the existing rule is unchanged" || return 1
    assert_eq ".cs/" "$(sed -n 2p "$repo/.git/info/exclude")" "the .cs/ rule sits on its own line" || return 1
}

test_rerun_finishes_an_adoption_that_lost_its_link() {
    local repo="$TEST_TMPDIR/repo"
    _make_repo "$repo" halfway
    local wt="$repo/.claude/worktrees/halfway"
    _seed_conversation "$wt" "$UUID_A" "Finish the half done adoption"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: adopt should succeed"; return 1; }
    # The state a run leaves when it dies after writing .cs/ and before linking.
    rm "$CS_SESSIONS_ROOT/repo.halfway"
    printf 'my note\n' >> "$wt/.cs/README.md"
    (cd "$repo" && "$CS_BIN" -adopt --worktrees >/dev/null 2>&1) || { echo "  FAIL: the re-run should succeed"; return 1; }
    [ -L "$CS_SESSIONS_ROOT/repo.halfway" ] || { echo "  FAIL: the re-run should register the session"; return 1; }
    assert_eq "my note" "$(tail -1 "$wt/.cs/README.md")" "the re-run keeps the README it found" || return 1
}

run_test test_refuses_outside_a_git_repo
run_test test_refuses_a_repo_without_claude_worktrees
run_test test_adopts_a_worktree_with_a_conversation
run_test test_skips_a_worktree_without_a_conversation
run_test test_binds_the_newest_of_two_conversations
run_test test_rerun_adopts_nothing_twice_and_keeps_the_exclude_file
run_test test_dry_run_writes_nothing
run_test test_rerun_prunes_a_link_whose_worktree_is_gone
run_test test_same_worktree_name_under_two_repos_opens_the_right_one
run_test test_a_symlink_to_another_project_is_not_adopted
run_test test_open_leaves_a_tracked_claude_md_with_cs_markers_alone
run_test test_an_exclude_file_without_a_final_newline_keeps_its_last_rule
run_test test_rerun_finishes_an_adoption_that_lost_its_link

report_results
