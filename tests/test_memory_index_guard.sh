#!/usr/bin/env bash
# ABOUTME: Tests for skills/sweep/scripts/memory-index-guard.sh, the /sweep MEMORY.md rewrite guard
# ABOUTME: Covers removed links, the byte budget, a missing snapshot, and restore

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

GUARD="$SCRIPT_DIR/../skills/sweep/scripts/memory-index-guard.sh"

# A session root holding a MEMORY.md with two pointers; the guard runs from it.
_guard_session() {
    SESSION="$TEST_TMPDIR/session"
    mkdir -p "$SESSION/.cs/memory" "$SESSION/.cs/local"
    INDEX="$SESSION/.cs/memory/MEMORY.md"
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never do alpha twice
- [Beta fact](project_beta.md): beta only runs on Tuesdays
EOF
}

_guard() {  # subcommand...
    ( cd "$SESSION" && bash "$GUARD" "$@" )
}

test_check_fails_when_a_link_is_removed() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md): never do alpha twice' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail when a pointer's link is gone" || return 1
    assert_output_contains "$out" "removed: project_beta.md" \
        "check must name the link that was removed" || return 1
}

# Appends one pointer line padded so MEMORY.md ends at exactly $1 bytes.
_pad_index_to() {  # bytes
    local head='- [Pad](project_pad.md): ' size fill
    size=$(wc -c < "$INDEX")
    fill=$(( $1 - size - ${#head} - 1 ))
    { printf '%s' "$head"; head -c "$fill" /dev/zero | tr '\0' x; printf '\n'; } >> "$INDEX"
    assert_eq "$1" "$(wc -c < "$INDEX" | tr -d ' ')" "fixture must be $1 bytes" || return 1
}

test_check_fails_over_the_byte_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    _pad_index_to 24401 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "check must fail one byte past the budget" || return 1
    assert_output_contains "$out" "over budget: 24401 bytes > 24400" \
        "check must print the size against the budget" || return 1
}

# step 5 runs check once per sweep even when nothing was written; with no
# snapshot there is nothing to compare, and that must never read as a pass.
test_check_without_a_snapshot_is_an_error() {
    _guard_session
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with no snapshot must not pass" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot; run snapshot before editing MEMORY.md" \
        "the error must name the missing snapshot and the fix" || return 1
}

test_check_without_the_index_is_an_error() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    rm "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 2 "$rc" "check with MEMORY.md gone must not pass" || return 1
    assert_output_contains "$out" "no .cs/memory/MEMORY.md here; run from the session root" \
        "the error must name the missing index" || return 1
}

# Rewriting a pointer shorter and adding a new one is what step 5 asks for.
test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    cat > "$INDEX" << 'EOF'
- [Alpha rule](feedback_alpha.md): never alpha twice
- [Beta fact](project_beta.md): beta only on Tuesdays
- [Gamma](reference_gamma.md): the gamma board
EOF
    _pad_index_to 24400 || return 1
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a rewrite keeping every link within budget must pass: $out" || return 1
    assert_output_contains "$out" "MEMORY.md: 24400/24400 bytes" \
        "a pass must still print the size against the budget" || return 1
}

# The budget is bytes: an em dash is three bytes and one character, so a
# character count would pass a file that Claude Code truncates.
test_check_counts_bytes_not_characters() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Delta](project_delta.md): delta — then epsilon' >> "$INDEX"
    _pad_index_to 24401 || return 1
    local chars
    chars=$(LC_ALL=en_US.UTF-8 wc -m < "$INDEX" | tr -d ' ')
    [ "$chars" -le 24400 ] || { echo "  FAIL: fixture must fit the budget in characters, has $chars"; return 1; }
    local rc=0
    _guard check > /dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "24401 bytes must fail even when the characters fit" || return 1
}

# restore puts back exactly what snapshot took, byte for byte: cs never
# rewrites MEMORY.md content of its own.
test_restore_puts_back_the_snapshot_byte_for_byte() {
    _guard_session
    printf '%s\n' '- [Delta](project_delta.md): delta — no trailing newline next' >> "$INDEX"
    printf '%s' 'last line without newline' >> "$INDEX"
    cp "$INDEX" "$TEST_TMPDIR/original"
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Alpha rule](feedback_alpha.md)' > "$INDEX"
    _guard restore > /dev/null || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: restore must reproduce the snapshot exactly"; return 1; }
}

test_restore_without_a_snapshot_leaves_the_index_alone() {
    _guard_session
    cp "$INDEX" "$TEST_TMPDIR/original"
    local out rc=0
    out=$(_guard restore 2>&1) || rc=$?
    assert_eq 2 "$rc" "restore with no snapshot must fail" || return 1
    assert_output_contains "$out" "no snapshot at .cs/local/memory-index.snapshot" \
        "the error must name the missing snapshot" || return 1
    cmp -s "$TEST_TMPDIR/original" "$INDEX" || { echo "  FAIL: a failed restore must not touch MEMORY.md"; return 1; }
}

test_unknown_subcommand_prints_usage() {
    _guard_session
    local out rc=0
    out=$(_guard verify 2>&1) || rc=$?
    assert_eq 2 "$rc" "an unknown subcommand must fail" || return 1
    assert_output_contains "$out" "usage: memory-index-guard.sh snapshot|check|restore" \
        "the error must list the subcommands" || return 1
}

# A pointer is its first link; a link inside its summary is supporting text.
test_check_passes_when_a_supporting_link_is_dropped() {
    _guard_session
    printf '%s\n' '- [Gamma](project_gamma.md): see [vendor docs](https://example.com/docs)' >> "$INDEX"
    _guard snapshot > /dev/null || return 1
    sed -i.bak 's|: see \[vendor docs\](https://example.com/docs)|: vendor configuration|' "$INDEX"
    grep -q 'vendor configuration' "$INDEX" || { echo "  FAIL: fixture edit did not land"; return 1; }
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "dropping a supporting link keeps every pointer: $out" || return 1
}

# Merging two pointers into one is forbidden even when the merged line still
# mentions the other entry's file.
test_check_fails_when_two_pointers_are_merged() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    printf '%s\n' '- [Beta fact](project_beta.md): Tuesdays; see [Alpha](feedback_alpha.md)' > "$INDEX"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a merged pointer must fail" || return 1
    assert_output_contains "$out" "removed: feedback_alpha.md" \
        "check must name the pointer the merge removed" || return 1
}

# Every entry in a memory bucket needs a pointer, including one this sweep
# wrote after the snapshot: an unindexed entry is never read again.
test_check_fails_on_an_unindexed_bucket_entry() {
    _guard_session
    _guard snapshot > /dev/null || return 1
    : > "$SESSION/.cs/memory/project_delta.md"
    : > "$SESSION/.cs/memory/notes.md"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a bucket entry with no pointer must fail" || return 1
    assert_output_contains "$out" "unindexed: project_delta.md" \
        "check must name the entry with no pointer" || return 1
    assert_output_not_contains "$out" "notes.md" \
        "a file outside the four buckets is not an entry" || return 1
}

# A fresh session has no MEMORY.md until Claude Code writes the first entry,
# so the first sweep snapshots nothing and must still reach a passing check.
test_first_sweep_snapshots_an_absent_index_as_empty() {
    _guard_session
    rm "$INDEX"
    local out rc=0
    out=$(_guard snapshot 2>&1) || rc=$?
    assert_eq 0 "$rc" "snapshot with no MEMORY.md yet must succeed: $out" || return 1
    [ -f "$SESSION/.cs/local/memory-index.snapshot" ] && [ ! -s "$SESSION/.cs/local/memory-index.snapshot" ] \
        || { echo "  FAIL: the snapshot of an absent index must be an empty file"; return 1; }
    : > "$SESSION/.cs/memory/project_first.md"
    printf '%s\n' '- [First](project_first.md): the first entry' > "$INDEX"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 0 "$rc" "a first sweep that indexes its entry must pass: $out" || return 1
    : > "$SESSION/.cs/memory/project_second.md"
    rc=0
    out=$(_guard check 2>&1) || rc=$?
    assert_eq 1 "$rc" "a first sweep still fails on an unindexed entry" || return 1
    assert_output_contains "$out" "unindexed: project_second.md" \
        "check must name the entry with no pointer" || return 1
}

# An absent index is only a fresh session inside a session root; anywhere else
# snapshot must refuse rather than record an empty index.
test_snapshot_outside_a_session_root_is_an_error() {
    mkdir -p "$TEST_TMPDIR/elsewhere"
    local out rc=0
    out=$( cd "$TEST_TMPDIR/elsewhere" && bash "$GUARD" snapshot 2>&1 ) || rc=$?
    assert_eq 2 "$rc" "snapshot outside a session root must fail" || return 1
    assert_output_contains "$out" "no .cs/memory here; run from the session root" \
        "the error must name the missing directory" || return 1
    [ ! -e "$TEST_TMPDIR/elsewhere/.cs" ] || { echo "  FAIL: snapshot must not create .cs outside a session root"; return 1; }
}

test_check_with_an_unreadable_snapshot_is_an_error() {
    [ "$(id -u)" -ne 0 ] || return 77
    _guard_session
    _guard snapshot > /dev/null || return 1
    chmod 000 "$SESSION/.cs/local/memory-index.snapshot"
    local out rc=0
    out=$(_guard check 2>&1) || rc=$?
    chmod 600 "$SESSION/.cs/local/memory-index.snapshot"
    assert_eq 2 "$rc" "an unreadable snapshot must not read as an empty one" || return 1
    assert_output_contains "$out" "cannot read .cs/local/memory-index.snapshot" \
        "the error must name the snapshot" || return 1
}

run_test test_check_fails_when_a_link_is_removed
run_test test_check_passes_a_rewrite_that_keeps_every_link_at_the_budget
run_test test_check_counts_bytes_not_characters
run_test test_check_without_a_snapshot_is_an_error
run_test test_check_without_the_index_is_an_error
run_test test_check_fails_over_the_byte_budget
run_test test_restore_puts_back_the_snapshot_byte_for_byte
run_test test_restore_without_a_snapshot_leaves_the_index_alone
run_test test_unknown_subcommand_prints_usage

run_test test_check_passes_when_a_supporting_link_is_dropped
run_test test_check_fails_when_two_pointers_are_merged
run_test test_check_fails_on_an_unindexed_bucket_entry
run_test test_first_sweep_snapshots_an_absent_index_as_empty
run_test test_snapshot_outside_a_session_root_is_an_error
run_test test_check_with_an_unreadable_snapshot_is_an_error

report_results
