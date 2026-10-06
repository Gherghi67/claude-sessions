#!/usr/bin/env bash
# ABOUTME: Tests the migration stamp (.cs/local/migrated): a fresh stamp lets a reopen skip
# ABOUTME: the one-time migration phases, and every kind of drift sends it back through them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Open a session as an actor (alice unless named), answering the resume prompt.
# Prints cs's output; returns cs's status.
_open() {  # name, [actor]
    CS_ACTOR="${2:-alice}" "$CS_BIN" "$1" <<< "" 2>&1
}

# A session cs created, then reopened once so the migration stamped it.
_stamped_session() {  # name
    local dir="$CS_SESSIONS_ROOT/$1"
    _open "$1" > /dev/null || { echo "  FAIL: creating $1 failed"; return 1; }
    _open "$1" > /dev/null || { echo "  FAIL: the first reopen of $1 failed"; return 1; }
    assert_file_exists "$dir/.cs/local/migrated" "a clean reopen stamps the migration" || return 1
}

# Put every probe file at a fixed old time and the stamp a year later, so
# nothing is newer than the stamp whichever second the opens ran in (bash 3.2
# compares mtimes in whole seconds).
_age_session() {  # dir
    local dir="$1" p
    for p in .gitignore .gitattributes CLAUDE.local.md CLAUDE.md .cs/README.md \
        .cs/memory/MEMORY.md .claude/settings.local.json; do
        if [ -e "$dir/$p" ]; then
            touch -t 202401010000 "$dir/$p"
        fi
    done
    touch -t 202501010000 "$dir/.cs/local/migrated"
}

# Remove one exact line from a file, keeping the rest.
_drop_line() {  # file, line
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/drop-line.XXXXXX")
    grep -vxF "$2" "$1" > "$tmp" || true
    cat "$tmp" > "$1"
    rm -f "$tmp"
}

# Two observables, one per kind of skipped work: the .obsidian/ ignore line
# only ensure_cs_gitignore_entries re-adds, and the cs:memory-note sentinel
# only Phase 9 re-adds. The positive control removes the stamp from the same
# fixture and watches both come back, so their absence means "skipped", not
# "cs never repairs this".
test_fresh_stamp_skips_the_one_time_phases() {
    local dir="$CS_SESSIONS_ROOT/stamped" out
    _stamped_session stamped || return 1
    _drop_line "$dir/.gitignore" ".obsidian/"
    _drop_line "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->"
    _age_session "$dir"
    out=$(_open stamped) || { echo "  FAIL: the stamped reopen failed: $out"; return 1; }
    assert_output_contains "$out" "--resume" "the stamped reopen still launches" || return 1
    assert_file_not_contains "$dir/.gitignore" '^\.obsidian/$' \
        "a fresh stamp skips the .gitignore backfill" || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" '<!-- cs:memory-note -->' \
        "a fresh stamp skips the CLAUDE.local.md sections" || return 1

    rm "$dir/.cs/local/migrated"
    _open stamped > /dev/null || { echo "  FAIL: the unstamped reopen failed"; return 1; }
    assert_file_contains "$dir/.gitignore" '^\.obsidian/$' \
        "positive control: without the stamp the .gitignore line is restored" || return 1
    assert_file_contains "$dir/CLAUDE.local.md" '<!-- cs:memory-note -->' \
        "positive control: without the stamp the memory note is restored" || return 1
}

test_gitignore_edited_after_the_stamp_is_repaired() {
    local dir="$CS_SESSIONS_ROOT/edited"
    _stamped_session edited || return 1
    _drop_line "$dir/.gitignore" ".obsidian/"
    _age_session "$dir"
    touch -t 202601010000 "$dir/.gitignore"
    _open edited > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_file_contains "$dir/.gitignore" '^\.obsidian/$' \
        "a .gitignore newer than the stamp is repaired" || return 1
}

test_deleted_claude_local_md_is_regenerated() {
    local dir="$CS_SESSIONS_ROOT/deleted"
    _stamped_session deleted || return 1
    rm "$dir/CLAUDE.local.md"
    _age_session "$dir"
    _open deleted > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_file_contains "$dir/CLAUDE.local.md" '<!-- cs:session-protocol -->' \
        "a CLAUDE.local.md deleted after the stamp is written again" || return 1
}

# The doctor's advice for a missing merge.ours.driver is to launch once. The
# stamp check reads the value, since every `git config` write rewrites
# .git/config: .git/config is left at its old time here, so only the value
# can send the open through the migration.
test_merge_driver_removed_after_the_stamp_is_restored() {
    local dir="$CS_SESSIONS_ROOT/driver"
    _stamped_session driver || return 1
    git -C "$dir" config --unset merge.ours.driver \
        || { echo "  FAIL: the fixture has no merge driver to remove"; return 1; }
    _age_session "$dir"
    touch -t 202401010000 "$dir/.git/config"
    _open driver > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_eq "true" "$(git -C "$dir" config --get merge.ours.driver)" \
        "a merge driver removed after the stamp is set again" || return 1
}

# A checkout cs hides itself in (git_bookkeeping: exclude) never gets the merge
# driver, so its absence there must not send every open through the migration.
test_excluded_bookkeeping_without_a_driver_stays_fresh() {
    local dir="$CS_SESSIONS_ROOT/excluded" out
    _stamped_session excluded || return 1
    # An excluded checkout tracks none of cs's files, or the open refuses it.
    git -C "$dir" rm -r -q --cached --ignore-unmatch .cs .claude/settings.local.json CLAUDE.local.md \
        && git -C "$dir" commit -q -m "untrack cs files" \
        || { echo "  FAIL: could not untrack cs's files"; return 1; }
    printf 'git_bookkeeping: exclude\n' >> "$dir/.cs/local/state"
    git -C "$dir" config --unset merge.ours.driver \
        || { echo "  FAIL: the fixture has no merge driver to remove"; return 1; }
    _drop_line "$dir/CLAUDE.local.md" "<!-- cs:memory-note -->"
    _age_session "$dir"
    out=$(_open excluded) || { echo "  FAIL: the reopen failed: $out"; return 1; }
    assert_file_not_contains "$dir/CLAUDE.local.md" '<!-- cs:memory-note -->' \
        "an excluded checkout without a driver keeps its fresh stamp" || return 1

    rm "$dir/.cs/local/migrated"
    out=$(_open excluded) || { echo "  FAIL: the unstamped reopen failed: $out"; return 1; }
    assert_file_contains "$dir/CLAUDE.local.md" '<!-- cs:memory-note -->' \
        "positive control: without the stamp the memory note is restored" || return 1
}

# Replace line 1 of a session's stamp, keeping line 2 (the probe list).
_rewrite_stamp_line1() {  # dir, line1
    local stamp="$1/.cs/local/migrated" line2
    line2=$(sed -n 2p "$stamp")
    printf '%s\n%s\n' "$2" "$line2" > "$stamp"
}

test_stamp_from_another_version_reruns_the_migration() {
    local dir="$CS_SESSIONS_ROOT/upgraded" version
    version=$("$CS_BIN" -version)
    version=${version#cs }
    _stamped_session upgraded || return 1
    _rewrite_stamp_line1 "$dir" "$(printf '2000.1.1\talice\t0')"
    _drop_line "$dir/.gitignore" ".obsidian/"
    _age_session "$dir"
    _open upgraded > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_file_contains "$dir/.gitignore" '^\.obsidian/$' \
        "a stamp from another cs version runs the full migration" || return 1
    assert_eq "$(printf '%s\talice\t0' "$version")" "$(sed -n 1p "$dir/.cs/local/migrated")" \
        "the migration restamps with this cs version" || return 1
}

test_another_actor_reruns_the_migration() {
    local dir="$CS_SESSIONS_ROOT/shared"
    _stamped_session shared || return 1
    _age_session "$dir"
    _open shared bob > /dev/null || { echo "  FAIL: bob's reopen failed"; return 1; }
    assert_file_exists "$dir/.cs/memory/narrative.bob.md" \
        "a stamp written for alice runs the full migration for bob, which writes his narrative" || return 1
}

test_session_encrypted_after_the_stamp_gains_the_protocol() {
    local dir="$CS_SESSIONS_ROOT/vaulted"
    _stamped_session vaulted || return 1
    assert_file_not_contains "$dir/CLAUDE.local.md" 'cs:encrypted-protocol' \
        "precondition: the plain session has no encrypted protocol" || return 1
    # What cs -encrypt does to a plain session: link .cs/private into the
    # vault and move the launch's plaintext log behind it, which the open
    # otherwise refuses.
    mkdir -p "$TEST_TMPDIR/vault/private"
    ln -s "$TEST_TMPDIR/vault/private" "$dir/.cs/private"
    if [ -e "$dir/.cs/local/session.log" ]; then
        mv "$dir/.cs/local/session.log" "$TEST_TMPDIR/vault/private/session.log"
    fi
    _age_session "$dir"
    _open vaulted > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_file_contains "$dir/CLAUDE.local.md" '<!-- cs:encrypted-protocol -->' \
        "a session encrypted after the stamp gains the encrypted protocol" || return 1
}

# Phase 13 rewrites an old narrative pointer in MEMORY.md through a temp file
# beside it; with .cs/memory read-only that rewrite fails and warns, and the
# open carries on. The positive control reopens with the directory writable
# and gets its stamp, so the stamp's absence is the failed write's doing.
test_migration_with_a_failed_write_leaves_no_stamp() {
    local dir="$CS_SESSIONS_ROOT/warned" out rc=0
    _stamped_session warned || return 1
    printf -- '- [Notes](narrative.alice.md): read all narrative.*.md on resume\n' >> "$dir/.cs/memory/MEMORY.md"
    rm "$dir/.cs/local/migrated"
    _deny_writes "$dir/.cs/memory" || rc=$?
    if [ "$rc" = 2 ]; then
        return 77
    fi
    out=$(_open warned) || rc=$?
    _allow_writes "$dir/.cs/memory"
    assert_eq "0" "$rc" "an open that warns still launches: $out" || return 1
    assert_output_contains "$out" "could not rewrite $dir/.cs/memory/MEMORY.md" \
        "the open took the warn-and-continue branch" || return 1
    assert_file_not_exists "$dir/.cs/local/migrated" \
        "a migration with a failed write writes no stamp" || return 1

    _open warned > /dev/null || { echo "  FAIL: the writable reopen failed"; return 1; }
    assert_file_exists "$dir/.cs/local/migrated" \
        "positive control: the same session stamps once the rewrite succeeds" || return 1
}

# Empty, garbage, a first line alone, and a second line cut off before its
# newline: none is a stamp, so each open runs the full migration, restamps,
# and says nothing about it.
test_unusable_stamp_reruns_the_migration_quietly() {
    local dir="$CS_SESSIONS_ROOT/torn" version out rc content
    version=$("$CS_BIN" -version)
    version=${version#cs }
    _stamped_session torn || return 1
    for content in "" "garbage" "$(printf '%s\talice\t0\n' "$version")" \
        "$(printf '%s\talice\t0\n.gitignore\tCLAUDE.loc' "$version")"; do
        printf '%s' "$content" > "$dir/.cs/local/migrated"
        _drop_line "$dir/.gitignore" ".obsidian/"
        _age_session "$dir"
        rc=0
        out=$(_open torn) || rc=$?
        assert_eq "0" "$rc" "an open with stamp '$content' succeeds: $out" || return 1
        assert_output_not_contains "$out" "Error" "stamp '$content' raises no error" || return 1
        assert_output_not_contains "$out" "line [0-9][0-9]*: " "stamp '$content' trips no shell error" || return 1
        assert_file_contains "$dir/.gitignore" '^\.obsidian/$' \
            "stamp '$content' runs the full migration" || return 1
        assert_eq "$(printf '%s\talice\t0' "$version")" "$(sed -n 1p "$dir/.cs/local/migrated")" \
            "stamp '$content' is replaced by a whole one" || return 1
    done
}

test_committed_stamp_is_refused() {
    local dir="$CS_SESSIONS_ROOT/tracked" out rc=0
    _stamped_session tracked || return 1
    (cd "$dir" && git add -f .cs/local/migrated && git commit -q -m "track the stamp") \
        || { echo "  FAIL: could not commit the stamp"; return 1; }
    out=$(_open tracked) || rc=$?
    assert_eq "1" "$rc" "an open with a committed stamp is refused" || return 1
    assert_output_contains "$out" ".cs/local/ is tracked in git" \
        "the refusal names the tracked .cs/local" || return 1
    assert_output_not_contains "$out" "--resume" "the refused open launches nothing" || return 1
}

# Claude Code rewrites MEMORY.md itself, so a newer index alone re-runs only
# the narrative check: the dropped pointer comes back, while a backdated
# .gitignore edit (the full migration's job) stays as it was.
test_memory_index_edit_reruns_only_the_narrative_check() {
    local dir="$CS_SESSIONS_ROOT/indexed" tmp
    _stamped_session indexed || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/index.XXXXXX")
    grep -vF '(narrative.alice.md)' "$dir/.cs/memory/MEMORY.md" > "$tmp" || true
    cat "$tmp" > "$dir/.cs/memory/MEMORY.md"
    rm -f "$tmp"
    assert_file_not_contains "$dir/.cs/memory/MEMORY.md" '(narrative\.alice\.md)' \
        "precondition: the pointer is gone" || return 1
    _drop_line "$dir/.gitignore" ".obsidian/"
    _age_session "$dir"
    touch -t 202601010000 "$dir/.cs/memory/MEMORY.md"
    _open indexed > /dev/null || { echo "  FAIL: the reopen failed"; return 1; }
    assert_file_contains "$dir/.cs/memory/MEMORY.md" '(narrative\.alice\.md)' \
        "a newer MEMORY.md gets its narrative pointer back" || return 1
    assert_file_not_contains "$dir/.gitignore" '^\.obsidian/$' \
        "a newer MEMORY.md alone runs no other phase" || return 1
}

# A directory where the stamp goes makes every stamp write fail, the way a
# full disk or a permission change would, without denying the other writes an
# open makes in .cs/local (the state file, the session lock).
test_stamp_that_cannot_be_written_does_not_stop_the_open() {
    local dir="$CS_SESSIONS_ROOT/unwritable" out rc=0
    _stamped_session unwritable || return 1
    rm "$dir/.cs/local/migrated"
    mkdir "$dir/.cs/local/migrated"
    out=$(_open unwritable) || rc=$?
    assert_eq "0" "$rc" "an open whose stamp cannot be written succeeds: $out" || return 1
    assert_output_contains "$out" "--resume" "the open still launches" || return 1
    assert_output_not_contains "$out" "is a directory" "the failed stamp write is not reported" || return 1
    assert_dir "$dir/.cs/local/migrated" "the open leaves what it could not replace" || return 1
}

run_test test_fresh_stamp_skips_the_one_time_phases
run_test test_gitignore_edited_after_the_stamp_is_repaired
run_test test_deleted_claude_local_md_is_regenerated
run_test test_merge_driver_removed_after_the_stamp_is_restored
run_test test_excluded_bookkeeping_without_a_driver_stays_fresh
run_test test_stamp_from_another_version_reruns_the_migration
run_test test_another_actor_reruns_the_migration
run_test test_session_encrypted_after_the_stamp_gains_the_protocol
run_test test_migration_with_a_failed_write_leaves_no_stamp
run_test test_unusable_stamp_reruns_the_migration_quietly
run_test test_committed_stamp_is_refused
run_test test_memory_index_edit_reruns_only_the_narrative_check
run_test test_stamp_that_cannot_be_written_does_not_stop_the_open

report_results
