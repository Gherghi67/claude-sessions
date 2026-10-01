#!/usr/bin/env bash
# ABOUTME: Tests for cs -remove/-rm: multi-name removal, per-name confirms,
# ABOUTME: fail-fast on unknown names, and the usage error with no name.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
CS_BIN="$SCRIPT_DIR/../bin/cs"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export CS_SESSIONS_ROOT="$TEST_TMPDIR/sessions"
    mkdir -p "$CS_SESSIONS_ROOT"
}
teardown() {
    [ -n "${TEST_TMPDIR:-}" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
    unset CS_SESSIONS_ROOT 2>/dev/null || true
}

test_remove_multiple_names_each_confirmed() {
    create_test_session r1 >/dev/null
    create_test_session r2 >/dev/null
    printf 'y\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r1 r2 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r1" ] || { echo "  r1 survived"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r2" ] || { echo "  r2 survived"; return 1; }
}

test_remove_decline_skips_that_session_only() {
    create_test_session r3 >/dev/null
    create_test_session r4 >/dev/null
    printf 'n\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r3 r4 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r3" ] || { echo "  declined r3 was removed"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/r4" ] || { echo "  r4 survived"; return 1; }
}

test_remove_single_name_still_works() {
    create_test_session r5 >/dev/null
    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r5 >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/r5" ] || { echo "  r5 survived"; return 1; }
}

test_remove_no_name_errors() {
    ! "$CS_BIN" -rm >/dev/null 2>&1 || return 1
}

test_remove_unknown_name_fails_fast() {
    create_test_session r6 >/dev/null
    ! printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm nosuch r6 >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT/r6" ] || { echo "  fail-fast still removed a later name"; return 1; }
}

test_remove_empty_name_rejected_before_any_deletion() {
    create_test_session r7 >/dev/null
    ! printf 'y\ny\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm r7 "" >/dev/null 2>&1 || return 1
    [ -d "$CS_SESSIONS_ROOT" ] || { echo "  sessions root deleted"; return 1; }
    [ -d "$CS_SESSIONS_ROOT/r7" ] || { echo "  r7 removed despite invalid list"; return 1; }
    ! "$CS_BIN" -rm "" >/dev/null 2>&1 || return 1
}

test_remove_refuses_live_session_without_force() {
    create_test_session live1 >/dev/null
    sleep 300 &
    local live_pid=$!
    echo "$live_pid" > "$CS_SESSIONS_ROOT/live1/.cs/session.lock"

    local out rc=0
    out=$(printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm live1 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: live session must refuse removal without --force"
        return 1
    fi
    assert_output_contains "$out" "--force" "refusal names the override" || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null; return 1; }
    [ -d "$CS_SESSIONS_ROOT/live1" ] || {
        kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
        echo "  FAIL: refused removal still deleted the session"; return 1; }

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm live1 --force >/dev/null 2>&1
    rc=$?
    kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
    [ "$rc" -eq 0 ] || { echo "  FAIL: --force should remove a live session"; return 1; }
    [ ! -d "$CS_SESSIONS_ROOT/live1" ] || { echo "  FAIL: --force did not remove"; return 1; }
}

test_remove_discards_pending_spawn_seeds() {
    create_test_session seeded >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\ndo a task\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale"
    printf 'other\n' > "$CS_SESSIONS_ROOT/.spawn/other.seed"

    printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  declined removal still discarded the seed"; return 1; }

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm seeded >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed" ] || { echo "  seed survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/seeded.seed.stale" ] || { echo "  stale seed survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/other.seed" ] || { echo "  another session's seed was deleted"; return 1; }
}

# The brief staged with a seed dies with the session too: a leftover would
# reach a future same-name session as a brief nobody wrote for it.
test_remove_discards_pending_spawn_brief() {
    create_test_session briefed >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.seed"
    printf 'do this\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md"
    printf 'old\n' > "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md.stale"
    printf 'theirs\n' > "$CS_SESSIONS_ROOT/.spawn/other.brief.md"

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm briefed >/dev/null 2>&1 || return 1
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md" ] || { echo "  brief survived removal"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/briefed.brief.md.stale" ] || { echo "  stale brief survived removal"; return 1; }
    [ -f "$CS_SESSIONS_ROOT/.spawn/other.brief.md" ] || { echo "  another session's brief was deleted"; return 1; }
}

test_remove_worktree_session_discards_seeds() {
    local base="$CS_SESSIONS_ROOT/wbase"
    create_test_session wbase >/dev/null
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md
    git -C "$base" -c user.email=t@t -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$CS_SESSIONS_ROOT/wbase@t" -b cs/t
    mkdir -p "$CS_SESSIONS_ROOT/wbase@t/.cs/local"
    mkdir -p "$CS_SESSIONS_ROOT/.spawn"
    printf 'spawner\n' > "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed"

    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm "wbase@t" >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/wbase@t" ] || { echo "  worktree session survived"; return 1; }
    [ ! -f "$CS_SESSIONS_ROOT/.spawn/wbase@t.seed" ] || { echo "  worktree seed survived removal"; return 1; }
}

test_remove_allows_heartbeat_only_session_without_force() {
    # The live guard is strict PID-lock by decision: a heartbeat-live but
    # unlocked session (fresh context-pct, no session.lock) is still removable
    # without --force. cs -live shows it; cs -rm does not refuse it.
    create_test_session breathing >/dev/null
    mkdir -p "$CS_SESSIONS_ROOT/breathing/.cs/local"
    : > "$CS_SESSIONS_ROOT/breathing/.cs/local/context-pct"
    printf 'y\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm breathing >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/breathing" ] || { echo "  heartbeat-only session wrongly refused rm"; return 1; }
}

test_remove_noninteractive_without_force_errors_loudly() {
    create_test_session n1 >/dev/null
    local out rc=0
    out=$("$CS_BIN" -rm n1 </dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: non-interactive rm without --force must not exit 0"; return 1; }
    assert_output_contains "$out" "needs a terminal" "error names the missing terminal" || return 1
    [ -d "$CS_SESSIONS_ROOT/n1" ] || { echo "  FAIL: session was removed despite the refusal"; return 1; }
}

test_remove_force_skips_the_prompt() {
    create_test_session n2 >/dev/null
    "$CS_BIN" -rm n2 --force </dev/null >/dev/null 2>&1 || return 1
    [ ! -d "$CS_SESSIONS_ROOT/n2" ] || { echo "  FAIL: --force did not remove the session"; return 1; }
}

test_remove_force_refuses_when_session_holds_files_cs_did_not_create() {
    local dir
    dir=$(create_test_session f1)
    mkdir "$dir/journal.sparsebundle"
    echo keep > "$dir/start"
    local out rc=0
    out=$("$CS_BIN" -rm f1 --force </dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: --force removed a session holding foreign files"; return 1; }
    assert_output_contains "$out" "journal.sparsebundle, start" "refusal names the foreign entries" || return 1
    assert_output_contains "$out" "--delete-files" "refusal names the override" || return 1
    assert_dir "$dir/journal.sparsebundle" "foreign entry must survive the refusal" || return 1
}

test_remove_force_with_delete_files_removes_foreign_files() {
    local dir
    dir=$(create_test_session f2)
    mkdir "$dir/journal.sparsebundle"
    "$CS_BIN" -rm f2 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "session with foreign files should be gone" || return 1
}

test_remove_force_ignores_cs_owned_entries_and_ds_store() {
    local dir
    dir=$(create_test_session f3)
    mkdir -p "$dir/.claude" "$dir/.git"
    touch "$dir/.gitignore" "$dir/.gitattributes" "$dir/CLAUDE.local.md" "$dir/.DS_Store"
    "$CS_BIN" -rm f3 --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "a session holding only cs-owned entries should still go under --force" || return 1
}

test_remove_confirm_lists_foreign_entries() {
    local dir
    dir=$(create_test_session f4)
    touch "$dir/notes.txt"
    local out
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm f4 2>&1) || return 1
    assert_output_contains "$out" "Also deletes files cs did not create: notes.txt" "confirm lists the foreign entry" || return 1
    assert_dir "$dir" "declined session must survive" || return 1
}

# An encrypted session mounts its vault inside the session directory by
# convention; rm -rf would recurse into the mount and delete what the vault
# holds, even under --force --delete-files. Unmounted, the links dangle and
# removal goes ahead.
_vaulted_session() {  # name; echoes the session dir
    local dir
    dir=$(create_test_session "$1")
    mkdir -p "$dir/.cs/vault-mnt/memory"
    echo sealed > "$dir/.cs/vault-mnt/memory/narrative.md"
    rm -rf "$dir/.cs/memory"
    ln -s "$dir/.cs/vault-mnt/memory" "$dir/.cs/memory"
    echo "$dir"
}

test_remove_refuses_while_the_vault_is_mounted_inside() {
    local dir out rc=0
    dir=$(_vaulted_session v1)
    out=$("$CS_BIN" -rm v1 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'v1' has encrypted storage mounted inside it: .cs/memory points at $dir/.cs/vault-mnt/memory. Removing the session would delete what the vault holds; unmount it, then retry." \
        "$out" "names the mounted link" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the vault's contents survive" || return 1
}

test_remove_goes_ahead_once_the_vault_is_unmounted() {
    local dir
    dir=$(_vaulted_session v2)
    rm -rf "$dir/.cs/vault-mnt/memory"
    "$CS_BIN" -rm v2 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "an unmounted encrypted session is removed" || return 1
}

# A cs -encrypt that stops partway leaves its volume mounted at .cs/vault-mnt
# before any vault link exists, so only the mount table shows it. A `mount`
# stub prints the table it is given; echoes the stub's directory for PATH.
_mount_table() {  # line...
    local d="$TEST_TMPDIR/mount-stub"
    mkdir -p "$d"
    printf '%s\n' "$@" > "$d/table"
    printf '#!/bin/sh\ncat "%s"\n' "$d/table" > "$d/mount"
    chmod +x "$d/mount"
    echo "$d"
}

_half_encrypted_session() {  # name; echoes the session dir
    local dir
    dir=$(create_test_session "$1")
    mkdir -p "$dir/.cs/vault-mnt/memory"
    echo sealed > "$dir/.cs/vault-mnt/memory/narrative.md"
    echo "$dir"
}

test_remove_refuses_a_volume_mounted_inside_without_vault_links() {
    local dir stub out rc=0
    dir=$(_half_encrypted_session h1)
    stub=$(_mount_table "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled)" \
        "/dev/disk9s1 on $dir/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)")
    out=$(PATH="$stub:$PATH" "$CS_BIN" -rm h1 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'h1' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry." \
        "$out" "names the mount point" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

test_remove_reads_a_linux_mount_table() {
    local dir stub out rc=0
    dir=$(_half_encrypted_session h2)
    stub=$(_mount_table "/dev/sda1 on / type ext4 (rw,relatime)" \
        "/dev/loop9 on $dir/.cs/vault-mnt type ext4 (rw,relatime)")
    out=$(PATH="$stub:$PATH" "$CS_BIN" -rm h2 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_eq "Error: Session 'h2' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry." \
        "$out" "names the mount point without the filesystem type" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

# A sibling whose name extends this one's ("h3x" beside "h3") holds the mount:
# a string-prefix match would refuse the wrong session.
test_remove_ignores_a_volume_mounted_in_another_session() {
    local dir other stub
    dir=$(create_test_session h3)
    other=$(_half_encrypted_session h3x)
    stub=$(_mount_table "/dev/disk9s1 on $other/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled)")
    PATH="$stub:$PATH" "$CS_BIN" -rm h3 --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$dir" "the session without a mount is removed" || return 1
    assert_file_exists "$other/.cs/vault-mnt/memory/narrative.md" "the other session is untouched" || return 1
}

test_remove_refuses_when_the_mount_table_cannot_be_read() {
    local dir d out rc=0
    dir=$(create_test_session h4)
    d="$TEST_TMPDIR/mount-broken"
    mkdir -p "$d"
    printf '#!/bin/sh\necho "mount: cannot read table" >&2\nexit 1\n' > "$d/mount"
    chmod +x "$d/mount"
    out=$(PATH="$d:$PATH" "$CS_BIN" -rm h4 --force --delete-files </dev/null 2>&1) || rc=$?
    assert_eq "1" "$rc" "removal refuses" || return 1
    assert_output_contains "$out" "Error: cs -rm could not read the mount table, so it cannot tell whether a volume is mounted inside 'h4'; refusing to remove it." "says why" || return 1
    assert_dir "$dir" "the session survives" || return 1
}

# Runs `cs -rm <args>` with a mount stub first on PATH and gives it 30 s, so a
# parse that never ends fails the test instead of hanging the suite. The scan
# runs in a command-substitution child of cs, so that child goes first. Prints
# the output, then "rc=<status>" (124 for a run that had to be stopped).
_rm_within_30s() {  # stub-dir args...
    local stub="$1" out="$TEST_TMPDIR/rm-within.out" pid i=0 rc=0
    shift
    PATH="$stub:$PATH" "$CS_BIN" -rm "$@" </dev/null >"$out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge 150 ]; then
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            cat "$out"
            echo "rc=124"
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
    wait "$pid" || rc=$?
    cat "$out"
    echo "rc=$rc"
}

# A mount source may itself hold " on " (an NFS export, an SMB share name).
# Another session's line like that must not stall the scan.
test_remove_reads_past_a_mount_source_holding_on() {
    local dir other stub out
    dir=$(create_test_session h5)
    other=$(_half_encrypted_session h5x)
    stub=$(_mount_table "host:/export on disk on $other/.cs/vault-mnt (nfs)")
    out=$(_rm_within_30s "$stub" h5 --force --delete-files)
    assert_eq "Removed session: h5
rc=0" "$out" "removal finishes" || return 1
    assert_not_exists "$dir" "the session without a mount is removed" || return 1
}

# In the last two lines the source ends in " on", so its " on" and the
# separator share one space.
test_remove_refuses_a_mount_whose_source_holds_on() {
    local dir stub out line
    dir=$(_half_encrypted_session h6)
    for line in "host:/export on disk on $dir/.cs/vault-mnt (nfs)" \
        "host:/export on on $dir/.cs/vault-mnt (nfs)" \
        "host:/export on on $dir/.cs/vault-mnt type nfs (rw)"; do
        stub=$(_mount_table "$line")
        out=$(_rm_within_30s "$stub" h6 --force --delete-files)
        assert_eq "Error: Session 'h6' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry.
rc=1" "$out" "names the mount point: $line" || return 1
        assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive: $line" || return 1
    done
}

# macOS never prints " type <fs>", so a path holding " type " (here in the
# sessions root) is still the mount point, not a Linux line to cut short.
test_remove_reads_a_macos_mount_point_holding_type() {
    local root="$TEST_TMPDIR/project type archive" dir stub out
    mkdir -p "$root"
    dir=$(CS_SESSIONS_ROOT="$root" _half_encrypted_session h7)
    stub=$(_mount_table "/dev/disk9s1 on $dir/.cs/vault-mnt (apfs, local, nodev, nosuid, journaled, noowners, mounted by tester)")
    out=$(CS_SESSIONS_ROOT="$root" _rm_within_30s "$stub" h7 --force --delete-files)
    assert_eq "Error: Session 'h7' has a volume mounted inside it at $dir/.cs/vault-mnt. Removing the session would delete what the volume holds; unmount it, then retry.
rc=1" "$out" "names the mount point" || return 1
    assert_file_exists "$dir/.cs/vault-mnt/memory/narrative.md" "the volume's contents survive" || return 1
}

# A worktree session beside a base repo, with one untracked and one
# git-ignored file the user added. Echoes the worktree path.
_worktree_with_user_files() {  # base-name
    local base="$CS_SESSIONS_ROOT/$1" wt="$CS_SESSIONS_ROOT/$1@t"
    create_test_session "$1" >/dev/null
    printf '*.img\n.cs/local/\n' > "$base/.gitignore"
    git -C "$base" init -q
    git -C "$base" add CLAUDE.md .gitignore
    git -C "$base" -c user.email=t@example.com -c user.name=t commit -qm seed
    git -C "$base" worktree add -q "$wt" -b "cs/$1-t"
    mkdir -p "$wt/.cs/local"
    echo draft > "$wt/notes.txt"
    echo secret > "$wt/journal.img"
    echo "$wt"
}

test_remove_force_refuses_worktree_with_untracked_or_ignored_files() {
    local wt out rc=0
    wt=$(_worktree_with_user_files wf1)
    out=$("$CS_BIN" -rm wf1@t --force </dev/null 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "  FAIL: --force removed a worktree holding untracked files"; return 1; }
    assert_output_contains "$out" "journal.img, notes.txt" "refusal names the untracked and ignored files" || return 1
    assert_file_exists "$wt/journal.img" "ignored file must survive the refusal" || return 1
}

test_remove_force_with_delete_files_removes_worktree() {
    local wt
    wt=$(_worktree_with_user_files wf2)
    "$CS_BIN" -rm wf2@t --force --delete-files </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$wt" "worktree should be gone with --delete-files" || return 1
}

test_remove_worktree_confirm_lists_untracked_files() {
    local wt out
    wt=$(_worktree_with_user_files wf3)
    out=$(printf 'n\n' | CS_ASSUME_TTY=1 "$CS_BIN" -rm wf3@t 2>&1) || return 1
    assert_output_contains "$out" "Also deletes files git does not track: journal.img, notes.txt" "confirm lists untracked and ignored files" || return 1
    assert_dir "$wt" "declined worktree must survive" || return 1
}

test_remove_force_on_adopted_removes_only_the_link() {
    local project_dir="$TEST_TMPDIR/adopted-project"
    mkdir -p "$project_dir"
    (cd "$project_dir" && "$CS_BIN" -adopt n3 >/dev/null 2>&1)

    "$CS_BIN" -rm n3 --force </dev/null >/dev/null 2>&1 || return 1
    assert_not_exists "$CS_SESSIONS_ROOT/n3" "symlink should be gone" || return 1
    assert_dir "$project_dir/.cs" "project .cs/ should still be present" || return 1
}

run_test test_remove_empty_name_rejected_before_any_deletion
run_test test_remove_refuses_live_session_without_force
run_test test_remove_allows_heartbeat_only_session_without_force
run_test test_remove_discards_pending_spawn_seeds
run_test test_remove_discards_pending_spawn_brief
run_test test_remove_worktree_session_discards_seeds
run_test test_remove_multiple_names_each_confirmed
run_test test_remove_decline_skips_that_session_only
run_test test_remove_single_name_still_works
run_test test_remove_no_name_errors
run_test test_remove_unknown_name_fails_fast
run_test test_remove_noninteractive_without_force_errors_loudly
run_test test_remove_force_skips_the_prompt
run_test test_remove_force_refuses_when_session_holds_files_cs_did_not_create
run_test test_remove_force_with_delete_files_removes_foreign_files
run_test test_remove_force_ignores_cs_owned_entries_and_ds_store
run_test test_remove_confirm_lists_foreign_entries
run_test test_remove_force_refuses_worktree_with_untracked_or_ignored_files
run_test test_remove_force_with_delete_files_removes_worktree
run_test test_remove_worktree_confirm_lists_untracked_files
run_test test_remove_force_on_adopted_removes_only_the_link
run_test test_remove_refuses_while_the_vault_is_mounted_inside
run_test test_remove_goes_ahead_once_the_vault_is_unmounted
run_test test_remove_refuses_a_volume_mounted_inside_without_vault_links
run_test test_remove_reads_a_linux_mount_table
run_test test_remove_ignores_a_volume_mounted_in_another_session
run_test test_remove_refuses_when_the_mount_table_cannot_be_read
run_test test_remove_reads_past_a_mount_source_holding_on
run_test test_remove_refuses_a_mount_whose_source_holds_on
run_test test_remove_reads_a_macos_mount_point_holding_type

report_results
