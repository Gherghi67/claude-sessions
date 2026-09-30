#!/usr/bin/env bash
# ABOUTME: Guards /sweep's rewrites of .cs/memory/MEMORY.md: snapshot, check, restore.
# ABOUTME: Run by the sweep command from the session root; not a hook itself.

set -euo pipefail

INDEX=".cs/memory/MEMORY.md"
# The snapshot copies MEMORY.md, so it sits where the session keeps its cs
# files: .cs/private for an encrypted session, whose index lives in the vault,
# .cs/local for any other. cs-shared.sh (build.sh's copy of lib/02-shared.sh)
# holds that rule.
_shared="$(dirname "$0")/cs-shared.sh"
[ -r "$_shared" ] || { printf 'memory-index-guard: %s is missing; reinstall cs\n' "$_shared" >&2; exit 2; }
# shellcheck source=cs-shared.sh
. "$_shared"
if ! _snapshot_dir=$(cs_private_dir .cs); then
    printf 'memory-index-guard: .cs/private is locked; mount the session'"'"'s vault, then retry\n' >&2
    exit 2
fi
SNAPSHOT="$_snapshot_dir/memory-index.snapshot"
# Claude Code loads MEMORY.md at every session start and cuts it past a limit;
# pointers beyond the cut are never read again. Bytes, not characters.
BUDGET=24400

_die() {  # message
    printf 'memory-index-guard: %s\n' "$1" >&2
    exit 2
}

# The target of every pointer, one per line, sorted for comm. A pointer is a
# line opening with `- [title](target)`; a link later on the line is
# supporting text, not a pointer. grep exits 1 on no match and 2 on a read
# error, and only the first is an empty index.
_pointers() {  # file
    local lines rc=0
    lines=$(grep -E '^- \[[^]]*\]\([^)]+\)' "$1") || rc=$?
    [ "$rc" -le 1 ] || _die "cannot read $1"
    [ -n "$lines" ] || return 0
    printf '%s\n' "$lines" | sed -E 's/^- \[[^]]*\]\(([^)]+)\).*/\1/' | LC_ALL=C sort -u
}

_need_index() {
    [ -f "$INDEX" ] || _die "no $INDEX here; run from the session root"
}

# Without a snapshot there is nothing to compare against, and check must not
# report that as a clean rewrite.
_need_snapshot() {
    [ -f "$SNAPSHOT" ] || _die "no snapshot at $SNAPSHOT; run snapshot before editing MEMORY.md"
    [ -r "$SNAPSHOT" ] || _die "cannot read $SNAPSHOT"
}

case "${1:-}" in
    snapshot)
        [ -d .cs/memory ] || _die "no .cs/memory here; run from the session root"
        mkdir -p "$_snapshot_dir" || _die "cannot create $_snapshot_dir"
        # Claude Code writes MEMORY.md with the first entry, so a fresh
        # session's first sweep starts from an empty index.
        if [ -f "$INDEX" ]; then
            cp "$INDEX" "$SNAPSHOT" || _die "cannot write $SNAPSHOT"
        else
            : > "$SNAPSHOT" || _die "cannot write $SNAPSHOT"
        fi
        printf 'snapshot: %s\n' "$SNAPSHOT"
        ;;
    check)
        _need_index
        _need_snapshot
        status=0
        before=$(_pointers "$SNAPSHOT")
        after=$(_pointers "$INDEX")
        removed=$(LC_ALL=C comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')
        if [ -n "$removed" ]; then
            printf '%s\n' "$removed" | sed 's/^/removed: /'
            status=1
        fi
        # An entry this sweep wrote after the snapshot is in no snapshot, so
        # the entries on disk are checked too: each needs a pointer.
        entries=$(cd .cs/memory && for f in user_*.md feedback_*.md project_*.md reference_*.md; do
            [ -f "$f" ] || continue
            printf '%s\n' "$f"
        done | LC_ALL=C sort)
        unindexed=$(LC_ALL=C comm -23 <(printf '%s\n' "$entries") <(printf '%s\n' "$after") | sed '/^$/d')
        if [ -n "$unindexed" ]; then
            printf '%s\n' "$unindexed" | sed 's/^/unindexed: /'
            status=1
        fi
        size=$(wc -c < "$INDEX" | tr -d ' ')
        if [ "$size" -gt "$BUDGET" ]; then
            printf 'over budget: %s bytes > %s\n' "$size" "$BUDGET"
            status=1
        fi
        printf 'MEMORY.md: %s/%s bytes\n' "$size" "$BUDGET"
        exit "$status"
        ;;
    restore)
        _need_snapshot
        cp "$SNAPSHOT" "$INDEX" || _die "cannot write $INDEX"
        printf 'restored: %s from %s\n' "$INDEX" "$SNAPSHOT"
        ;;
    *)
        _die "usage: memory-index-guard.sh snapshot|check|restore"
        ;;
esac
