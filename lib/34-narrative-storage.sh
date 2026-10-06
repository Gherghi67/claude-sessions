# ABOUTME: Portable per-actor narratives, memory index, and discoveries migration.
# ABOUTME: Shared Markdown session storage for every runtime.

# Ensure the session narrative topic file and its MEMORY.md index pointer exist.
# The narrative is the looser-bar lab notebook, held as a native memory topic
# file so it inherits lazy-load and /memory tooling. Idempotent: creates the
# stub on first run and re-adds the index pointer if a memory write dropped it.
ensure_narrative_file() {
    local session_dir="$1"
    local mem_dir="$session_dir/.cs/memory"
    local index="$mem_dir/MEMORY.md"
    mkdir -p "$mem_dir"

    local actor
    actor=$(cs_actor_slug "$session_dir")
    local narrative="$mem_dir/narrative.$actor.md"

    # One-time migration: a pre-per-actor narrative.md becomes this actor's file.
    if [ -f "$mem_dir/narrative.md" ] && [ ! -f "$narrative" ]; then
        mv "$mem_dir/narrative.md" "$narrative"
    fi

    if [ ! -f "$narrative" ]; then
        cat > "$narrative" << EOF
---
name: session-narrative-$actor
description: Session lab-notebook and work-in-progress narrative for $actor. Looser bar than durable memory. Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs/narrative-archive/.
type: narrative
---
# Session narrative ($actor)

EOF
    fi

    # Drop the legacy single-narrative index pointer if a migration left it stale.
    # Through a temp file instead of sed -i: the BSD `sed -i ''` form errors on
    # GNU sed and would abort session resume on Linux under set -e.
    if [ -f "$index" ] && grep -q '(narrative\.md)' "$index" 2>/dev/null; then
        cs_write_atomic "$index" sed '/(narrative\.md)/d' "$index" \
            || warn "could not rewrite $index; the stale narrative.md pointer stays"
    fi

    if [ ! -f "$index" ] || ! grep -q "(narrative\.$actor\.md)" "$index" 2>/dev/null; then
        printf -- '- [Session narrative — %s (lab notebook)](narrative.%s.md): looser-bar work-in-progress; its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs/narrative-archive/\n' "$actor" "$actor" >> "$index"
    fi
}

# Fold a legacy discoveries.md (and its compact companion) into the narrative
# topic file, then consume the originals so the fold runs at most once. A
# header-only or empty discoveries.md is ignored. Runs on resume of sessions
# that predate the narrative relocation.
migrate_discoveries_to_narrative() {
    local session_dir="$1"
    local meta="$session_dir/.cs"
    local disc="$meta/discoveries.md"
    local compact="$meta/discoveries.compact.md"

    [ -f "$disc" ] || return 0
    local disc_body compact_body
    disc_body=$(grep -vE '^# Discoveries & Notes$|^[[:space:]]*$' "$disc" 2>/dev/null || true)
    compact_body=""
    [ -f "$compact" ] && compact_body=$(grep -vE '^[[:space:]]*$' "$compact" 2>/dev/null || true)
    if [ -z "$disc_body" ] && [ -z "$compact_body" ]; then
        rm -f "$disc" "$compact"
        return 0
    fi

    ensure_narrative_file "$session_dir"
    local narrative="$meta/memory/narrative.$(cs_actor_slug "$session_dir").md"
    # Date the fold from shared git history, not the local clock: two clones
    # folding the same legacy file must produce byte-identical blocks so a
    # later merge collapses them instead of conflicting.
    local fold_date
    fold_date=$(git -C "$session_dir" log -1 --format=%as -- .cs/discoveries.md 2>/dev/null || true)
    {
        if [ -n "$disc_body" ]; then
            echo ""
            if [ -n "$fold_date" ]; then
                echo "## Folded from discoveries.md ($fold_date)"
            else
                echo "## Folded from discoveries.md"
            fi
            echo ""
            cat "$disc"
        fi
        if [ -n "$compact_body" ]; then
            echo ""
            echo "## Folded from discoveries.compact.md"
            echo ""
            cat "$compact"
        fi
    } >> "$narrative"
    rm -f "$disc" "$compact"
}

