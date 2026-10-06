# ABOUTME: Claude adapter workspace preparation and legacy instruction/binding migrations.
# ABOUTME: Core workspace operations dispatch here only when Claude is selected.

_cs_claude_adapter_prepare_workspace() {  # session_dir, create|migrate_storage|migrate|worktree
    local session_dir="$1" mode="$2" state="$1/.cs/local/state"
    case "$mode" in
        create)
            # Re-adoption preserves a previous exact conversation binding.
            [ -n "$(_read_local_state "$state" claude_session_id)" ] \
                || _set_local_state_if_absent "$state" claude_session_id "$(_alloc_uuid)"
            [ -n "$(_read_local_state "$state" claude_session_color)" ] \
                || _set_local_state_if_absent "$state" claude_session_color "$(_alloc_random_color)"
            _claude_ensure_workspace_protocol "$session_dir"
            setup_auto_memory "$session_dir"
            ;;
        migrate_storage)
            # Phase 4: Ensure auto memory and plans are configured
            if [ ! -d "$session_dir/.cs/memory" ] || [ ! -d "$session_dir/.cs/plans" ] || [ ! -f "$session_dir/.claude/settings.local.json" ]; then
                setup_auto_memory "$session_dir"
            fi
            ;;
        migrate) _claude_migrate_workspace "$session_dir" ;;
        worktree)
            # Worktrees can track a user's own protocol file; never replace it.
            if [ ! -f "$session_dir/CLAUDE.local.md" ] \
                || grep -q 'cs:session-protocol' "$session_dir/CLAUDE.local.md"; then
                write_session_claude_md "$session_dir"
            fi
            [ -n "$(_read_local_state "$state" claude_session_color)" ] \
                || _set_local_state_if_absent "$state" claude_session_color "$(_alloc_random_color)"
            setup_auto_memory "$session_dir"
            ;;
        *) return 2 ;;
    esac
}

_claude_migrate_protocol_wording() {
    local session_dir="$1" f
    f="$session_dir/CLAUDE.local.md"
    # cs has shipped two protocol-block wordings for the same sentence: the
    # current two-line form, and the July-2026 four-line form ("Note:
    # narratives are per-actor ... so co-developers never / conflict. Append
    # only to your own ... read all / narrative.*.md on resume to restore
    # your working narrative and see teammates' / in-progress findings.").
    # Either grep alternative can match a line that a CRLF checkout split
    # from its neighbour with a trailing \r, so the gate itself does not need
    # \r-tolerance — only the awk's line-for-line comparisons do.
    if [ -f "$f" ] && grep -qE "read all narrative\.\*\.md on resume to restore your|^Note: narratives are per-actor \(narrative\.<actor>\.md\) so co-developers never|on resume read the live narrative\.\*\.md \(rotation keeps|lab notebooks \(yours \+ teammates'\)" "$f"; then
        cs_write_atomic "$f" awk '
            function strip(s) { sub(/\r$/, "", s); return s }
            function protocol_para() {
                print "Append only to your own; on resume read your own in full, and a teammate narrative only"
                print "from the line the resume digest names for it (nothing, when it names none). Older sections"
                print "sit under .cs/narrative-archive/<actor>/ — grep on demand, never preload."
            }
            {
                cur = strip($0)
            }
            cur == "Append only to your own; read all narrative.*.md on resume to restore your" {
                line1 = $0
                getline nextline
                if (strip(nextline) ~ /^working narrative and see teammates/) {
                    protocol_para()
                    next
                }
                print line1; print nextline; next
            }
            cur == "3. **.cs/memory/narrative.*.md** - Per-actor lab notebooks (yours + teammates\047): findings, in-progress state, observations" {
                print "3. **.cs/memory/narrative.<actor>.md** - Per-actor lab notebooks: findings, in-progress state, observations. Yours in full; a teammate\047s only where the resume digest says it grew"
                next
            }
            cur == "Append only to your own; on resume read the live narrative.*.md (rotation keeps" {
                line1 = $0
                getline nextline
                if (strip(nextline) ~ /^them small\)\. Older sections sit under/) {
                    protocol_para()
                    next
                }
                print line1; print nextline; next
            }
            cur == "Note: narratives are per-actor (narrative.<actor>.md) so co-developers never" {
                line1 = $0
                getline line2
                getline line3
                getline line4
                if (strip(line2) ~ /^conflict\. Append only to your own/ && strip(line3) ~ /^narrative\.\*\.md on resume/) {
                    protocol_para()
                    next
                }
                print line1; print line2; print line3; print line4; next
            }
            { print }
        ' "$f" || error "could not rewrite $f"
    fi
}

# Remove .cs/commands.md (and its adjacent state files), and strip the
# `@.cs/commands.md` import plus the "Discovered Commands" section from
# CLAUDE.md. Idempotent: silent and a no-op once a session is clean.
prune_commands_artifacts() {
    local session_dir="$1"
    local meta_dir="$session_dir/.cs"
    local removed=0

    local f
    for f in commands.md commands.md.tmp command-dates.txt promoted-commands.txt; do
        if [ -f "$meta_dir/$f" ]; then
            rm -f "$meta_dir/$f"
            removed=1
        fi
    done

    local claude_md="$session_dir/CLAUDE.md"
    if [ -f "$claude_md" ] && grep -qE '@\.cs/commands\.md|^## Discovered Commands|^[0-9]+\. \*\*\.cs/commands\.md\*\*' "$claude_md"; then
        cs_write_atomic "$claude_md" awk '
            /^## Discovered Commands[[:space:]]*$/ { in_section = 1; next }
            in_section && /^## / { in_section = 0 }
            in_section { next }
            /^[0-9]+\. \*\*\.cs\/commands\.md\*\*/ { next }
            { print }
        ' "$claude_md" || error "could not rewrite $claude_md"
        removed=1
    fi

    if [ "$removed" -eq 1 ]; then
        warn "Pruned retired command-tracker artifacts"
    fi
}

_claude_migrate_workspace() {
    local session_dir="$1" _state="$1/.cs/local/state"
    _claude_migrate_protocol_wording "$session_dir"

    _claude_ensure_workspace_protocol "$session_dir"

    # Phase 7: prune retired command-tracker artifacts. Not in an adopted
    # Claude Code worktree, whose tracked tree is the branch's (see
    # _claude_tracked_tree_is_ours).
    if _claude_tracked_tree_is_ours "$session_dir"; then
        prune_commands_artifacts "$session_dir"
    fi

    # Phase 8: Backfill only an absent binding. A missing native transcript
    # does not authorize replacing an existing conversation with a discovered one.
    {
        local _existing _proj _bind_uuid=""
        _existing=$(_read_local_state "$_state" claude_session_id)
        if [ -z "$_existing" ] && [ "${CS_LAUNCH_INTENT:-auto}" = auto ]; then
            _proj=$(_claude_project_dir "$session_dir")
            _bind_uuid=$(_discover_session_uuid_in "$_proj")
            if [ -n "$_bind_uuid" ]; then
                _set_local_state_if_absent "$_state" claude_session_id "$_bind_uuid"
                warn "Bound claude_session_id in .cs/local/state to $_bind_uuid"
            fi
        fi
    }

    # Phase 9: Manage the cs:memory-note section in CLAUDE.md. Four states:
    #
    #   1. cs:memory-note already present — skip silently.
    #   2. cs:memory-rules sentinel + "## Auto-memory bucket guidance" header
    #      (any variant, with or without the "(scoop mode" suffix) — legacy
    #      imperative-prose block from v2026.5.2–5.4. Strip the entire block
    #      (sentinel through the next <!-- marker or EOF) and insert the
    #      cs:memory-note in its place. Adjacent cs:wrap-cues block keeps its
    #      order. Empirically the block did not influence claude's auto-memory
    #      writer (see .cs/memory/narrative.md); the note documents what cs
    #      actually owns — path redirect + indexing — without claiming
    #      behavioral ownership.
    #   3. cs:memory-rules sentinel without header line — user opted out via
    #      tombstone. The opt-out signal ("no cs memory documentation in my
    #      CLAUDE.md") carries over to the replacement note: preserve as-is,
    #      do NOT add the note.
    #   4. Neither sentinel present — append the note fresh.
    #
    # Note content lives in _emit_memory_note_block (shared with
    # write_session_claude_md). Phase 5 guarantees the local file for
    # migrated sessions; legacy sessions skip these phases.
    # Phases 9 and 10 manage sections in CLAUDE.local.md ONLY. Sessions
    # still on a legacy CLAUDE.md (pre-sentinel era, or a user file that
    # merely mentions .cs/) are left entirely alone — cs never writes to
    # CLAUDE.md again. Both phases' existing [ -f ] guards make them
    # no-ops when the local file is absent.
    local claude_md_p9="$session_dir/CLAUDE.local.md"
    if [ -f "$claude_md_p9" ]; then
        if grep -q '<!-- cs:memory-note -->' "$claude_md_p9"; then
            : # State 1: already on the note
        elif grep -q '<!-- cs:memory-rules -->' "$claude_md_p9"; then
            if grep -qE '^## Auto-memory bucket guidance' "$claude_md_p9"; then
                # State 2: legacy rules block — strip + insert note in place.
                # NEW_BLOCK passed via env (not -v) so awk doesn't re-process
                # C-style escapes in the markdown content.
                NEW_BLOCK=$(_emit_memory_note_block) cs_write_atomic "$claude_md_p9" awk '
                    /<!-- cs:memory-rules -->/ {
                        print ENVIRON["NEW_BLOCK"]
                        stripping = 1
                        next
                    }
                    stripping && /^<!-- / { stripping = 0 }
                    !stripping { print }
                ' "$claude_md_p9" || error "could not rewrite $claude_md_p9"
                warn "Retired auto-memory bucket guidance; replaced with cs:memory-note"
            # State 3: tombstone (sentinel without header) — preserve opt-out
            fi
        else
            # State 4: no sentinel of either kind — append fresh
            {
                echo ""
                _emit_memory_note_block
            } >> "$claude_md_p9"
            warn "Added cs:memory-note to CLAUDE.local.md"
        fi
    fi

    # Phase 10: Append session wrap-up cues to CLAUDE.md when sentinel absent.
    # The cs:wrap-cues marker (with or without content beneath) signals
    # "managed, do not re-add" — users opt out via tombstone (delete prose,
    # keep the HTML comment).
    if [ -f "$claude_md_p9" ] && ! grep -q 'cs:wrap-cues' "$claude_md_p9"; then
        cat >> "$claude_md_p9" << 'EOF'

<!-- cs:wrap-cues -->
## Session wrap-up cues

When the conversation reaches a natural stopping point — work shipped, a PR merged, a deploy completed, a bug fixed, or the user signaling they're winding down — proactively offer to distill the session via AskUserQuestion BEFORE the conversation drifts.

**Strong signals (sufficient on their own — but only when the phrase describes work that actually completed; never fire when it reports a problem, is negated, or is part of a plan for later):**
- "shipped", "PR merged", "PR up", "deployed", "released"
- "let's call it", "wraps up", "done for the day", "good place to stop"
- "all good now", "that did it", "ready to ship"

**Soft signals (require a corroborating signal — a recent commit, an explicit "done", or two or more soft signals in succession):**
- "that works", "looks good", "we're good", "all set"

**When fired**, use AskUserQuestion with header "Wrap up?" and these options:
- "Run /wrap" — distill memory entries AND write a session summary in sequence (the usual choice)
- "Run /sweep only" — just the memory pass; skip the narrative summary
- "Run /summary only" — just the narrative; skip the memory pass
- "Not yet — keep working"

Do not fire on every short affirmative ("yes", "ok", "thanks"). Fire when the *work itself* has reached a coherent stopping point, not when a single answer satisfied a single question. False positives erode the signal — be picky.

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — ags treats the sentinel's presence as "managed, do not re-add."
EOF
        warn "Appended session wrap-up cues to CLAUDE.local.md"
    fi

    # Phase 14: an encrypted session (.cs/private present; a locked one was
    # refused before migrate) gains the encrypted protocol. The sentinel is a
    # tombstone like cs:wrap-cues: present means managed, never re-added.
    if [ -f "$claude_md_p9" ] && [ -d "$session_dir/.cs/private" ] \
        && ! grep -q 'cs:encrypted-protocol' "$claude_md_p9"; then
        { echo; _emit_encrypted_protocol_block; } >> "$claude_md_p9"
        warn "Added the encrypted-session protocol to CLAUDE.local.md"
    fi

    # Phase 11: Backfill claude_session_color in local state when absent.
    # Picks one of the 8 colors claude's /color command accepts. Idempotent —
    # runs only when the field is missing. Legacy sessions (pre-v2026.5.7)
    # get a randomly-chosen color on next launch and stay on it from then on.
    if [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
        local _new_color
        _new_color=$(_alloc_random_color)
        _set_local_state_if_absent "$_state" claude_session_color "$_new_color"
        warn "Backfilled claude_session_color in .cs/local/state ($_new_color)"
    fi
}

# An adopted Claude Code worktree (git_bookkeeping: exclude) keeps its tracked
# CLAUDE.md and files as the branch has them: nothing moves out of CLAUDE.md
# and nothing tracked is pruned. migrate_session skips its own tracked-tree
# work for the same sessions.
_claude_tracked_tree_is_ours() {  # session_dir
    [ "$(_read_local_state "$1/.cs/local/state" git_bookkeeping)" != "exclude" ]
}

_claude_ensure_workspace_protocol() {
    local session_dir="$1"
    # Phase 5: move cs-managed sections out of CLAUDE.md, then ensure the
    # protocol is present in CLAUDE.local.md (machine-local, gitignored). A
    # sentinel-free CLAUDE.md that references .cs/ is a pre-sentinel-era cs
    # template: that session stays entirely on CLAUDE.md — extraction cannot
    # be surgical without sentinels, and a second protocol file would
    # duplicate instructions. A wholesale-moved old-template head lacks the
    # leading cs:session-protocol sentinel by definition (that absence is
    # what made it a wholesale-move candidate), so "protocol already
    # present" in CLAUDE.local.md is any cs sentinel at all, not just the
    # leading one — otherwise this fallback would re-append a duplicate
    # fresh template on top of it.
    if _claude_tracked_tree_is_ours "$session_dir"; then
        migrate_claude_md_to_local "$session_dir"
    fi
    local claude_md="$session_dir/CLAUDE.md"
    local claude_local="$session_dir/CLAUDE.local.md"
    if ! { [ -f "$claude_local" ] && grep -q '<!-- cs:' "$claude_local"; } \
        && ! { [ -f "$claude_md" ] && grep -q '\.cs/' "$claude_md"; }; then
        if [ -f "$claude_local" ]; then
            printf '\n' >> "$claude_local"
            _emit_session_claude_md >> "$claude_local"
            warn "Appended the cs session protocol to your existing CLAUDE.local.md"
        else
            write_session_claude_md "$session_dir"
        fi
    fi

}
