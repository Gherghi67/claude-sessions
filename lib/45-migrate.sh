# ABOUTME: Session structure creation, git merge attributes, and the legacy migration phases.
# ABOUTME: Runs migrate_session on every open to bring old layouts current.

setup_merge_attributes() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$dir" config merge.ours.driver true 2>/dev/null || _CS_MIGRATE_CLEAN=0
    local ga="$dir/.gitattributes"
    if ! grep -q 'MEMORY\.md merge=ours' "$ga" 2>/dev/null; then
        printf '.cs/memory/MEMORY.md merge=ours\n' >> "$ga"
    fi
    if ! grep -q 'timeline\.jsonl merge=union' "$ga" 2>/dev/null; then
        printf '.cs/timeline.jsonl merge=union\n' >> "$ga"
    fi
    if ! grep -q 'narrative\.\*\.md merge=union' "$ga" 2>/dev/null; then
        printf '.cs/memory/narrative.*.md merge=union\n' >> "$ga"
    fi
}

# Refuse to proceed if per-actor local state has been committed to git.
cs_assert_local_untracked() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    if [ -n "$(git -C "$dir" ls-files -- .cs/local 2>/dev/null)" ]; then
        error ".cs/local/ is tracked in git (per-actor state must stay local). Fix with: git -C \"$dir\" rm -r --cached .cs/local && git commit -m 'stop tracking .cs/local'"
    fi
}

# For a checkout cs hides itself in through info/exclude (git_bookkeeping:
# exclude): the first path cs would rewrite at open that the branch tracks, or
# "<path> is a symlink" when one of them points elsewhere (a write through it
# lands on the target, which may be tracked). Empty when the open is safe. An
# exclude hides only untracked files, so a tracked one here would be dirtied
# on every open; checked at adoption to skip, and at every open to refuse,
# since the branch moves on.
_exclude_session_tracked_conflict() {  # dir
    local dir="$1" p
    for p in .claude .claude/settings.local.json CLAUDE.local.md .cs; do
        if [ -L "$dir/$p" ]; then
            printf '%s is a symlink' "$p"
            return 0
        fi
    done
    git -C "$dir" ls-files -- .cs .claude/settings.local.json CLAUDE.local.md 2>/dev/null | head -1
}

# True when cs created this session directory, and so owns its mode. Two ways to
# fail: the directory sits outside the sessions root, or a symlink IN the root
# resolves to it — an adopted session, whose target is the user's own project
# and stays whatever mode they chose, even when they keep it inside the root.
#
# Both sides are resolved before comparing. A plain prefix test on the unresolved
# root silently never matched wherever the root itself sits behind a link (macOS
# /var -> /private/var is the everyday case), so the backfill quietly did nothing
# on exactly the machines it was written on.
_session_root_is_cs_owned() {  # session_dir
    local dir root e
    dir=$(cd "$1" 2>/dev/null && pwd -P) || return 1
    root=$(cd "${SESSIONS_ROOT:-}" 2>/dev/null && pwd -P) || return 1
    case "$dir" in "$root"/*) ;; *) return 1 ;; esac
    for e in "${SESSIONS_ROOT:-}"/*; do
        [ -L "$e" ] || continue
        [ "$(cd "$e" 2>/dev/null && pwd -P)" = "$dir" ] && return 1
    done
    return 0
}

# Bring a session's own data directory to owner-only. cs writes narratives,
# plans, logs, the timeline and machine-local state here, and a session can hold
# anything its user worked on — but bare mkdir takes the caller's umask, so on
# any sessions root that is not itself private the whole lot is world-readable.
# Only .cs is set: reaching a file inside needs execute on the directory, so a
# private .cs covers everything under it whatever the files' own modes are.
#
# Scoped to .cs on purpose. adopt calls create_session_structure with the USER'S
# project directory, whose mode is theirs to choose — a shared checkout or a
# served directory may be world-readable deliberately — so the session root is
# hardened only where cs created it.
_harden_session_meta() {  # session_dir
    [ -d "$1/.cs" ] || return 0
    chmod 700 "$1/.cs" 2>/dev/null || true
    return 0
}

# A session can prepare itself before cs opens it, such as mounting the
# encrypted volume its memory lives on. The command lives in .cs/local/, which
# is never committed, so a cloned session cannot make cs run code (a file sync
# copies it like any other file).
# It runs in the session directory on the user's terminal (a password prompt
# needs the TTY), and any non-zero exit aborts the open.
_run_pre_open() {  # session_name, session_dir
    local hook="$2/.cs/local/pre-open" rc=0
    [ -e "$hook" ] || return 0
    # `git add -f` can still commit into the ignored .cs/local/; refuse before
    # running anything a clone could have delivered.
    cs_assert_local_untracked "$2"
    [ -x "$hook" ] || error "$1: .cs/local/pre-open is not executable; chmod +x it, or remove it."
    (cd "$2" && "$hook") || rc=$?
    [ "$rc" -eq 0 ] || error "$1: .cs/local/pre-open exited $rc; not opening the session."
    _arm_vault_detach "$2"
}

# A session can keep .cs/memory, .cs/plans, .cs/claude-config (Claude Code's
# own config dir) and .cs/private (cs's own content files) on an encrypted
# volume by making them symlinks into its mountpoint. Unmounted, the links
# dangle: `test -d` is false through them, so migrate would mkdir through them
# and abort on a raw mkdir error. Refuse by name instead, before anything
# writes there.
_refuse_unmounted_meta() {  # session_name, session_dir
    local sub link target
    for sub in $CS_VAULT_LINKS; do
        link="$2/.cs/$sub"
        if [ -e "$link" ] && [ ! -d "$link" ]; then
            error "$1: .cs/$sub is a file, not a directory or a link into encrypted storage. Remove it, or link it into the vault, then reopen."
        fi
        [ -L "$link" ] && [ ! -e "$link" ] || continue
        target=$(readlink "$link")
        error "$1: .cs/$sub points at $target, which is missing (encrypted storage not mounted?). Mount it, then reopen."
    done
    _refuse_plaintext_beside_private "$1" "$2"
}

# Feature worktrees of an encrypted session are not designed yet. cs -encrypt
# links the four names relative to .cs/, so a checkout of them resolves inside
# the worktree, where nothing is mounted; and a base whose .cs/ is ignored
# gives the worktree plaintext files of its own. Refused by name until then.
_refuse_worktree_of_encrypted_base() {  # base_name, base_dir
    local sub
    for sub in $CS_VAULT_LINKS; do
        [ -L "$2/.cs/$sub" ] || continue
        error "$1: .cs/$sub links into encrypted storage, and feature worktrees of an encrypted session are not supported yet."
    done
}

# The cs content files a plain session keeps in .cs/local and an encrypted one
# keeps behind .cs/private. The open refuses a plaintext copy of any of them,
# and cs -encrypt moves each into the vault.
CS_PRIVATE_LOCAL_FILES="session.log scope-prompt.trace memory-index.snapshot mail
    queue queue.tmp queue.state queue.done queue.declined queue.migrating
    notifications.jsonl notifications.seen failures rewrite.trace pending-handoff
    finish-progress.json"

# Once .cs/private holds a session's cs content files, a copy still in
# .cs/local is plaintext the vault was meant to hold: an unmigrated log, or one
# written by an older cs. Named rather than moved, since a move cannot remove
# the copies backups and snapshots already hold.
_refuse_plaintext_beside_private() {  # session_name, session_dir
    local meta="$2/.cs" name
    [ -e "$meta/private" ] || return 0
    for name in $CS_PRIVATE_LOCAL_FILES; do
        [ -e "$meta/local/$name" ] || continue
        error "$1: .cs/private keeps this session's cs files in its vault, but .cs/local still holds $name in plaintext. Move it into .cs/private or delete it, then reopen."
    done
    if [ -e "$meta/handoffs" ]; then
        error "$1: .cs/private keeps this session's rotation handoffs in its vault, but .cs/handoffs still holds them in plaintext. Move it to .cs/private/handoffs or delete it, then reopen."
    fi
    if [ -e "$meta/checkpoints" ]; then
        error "$1: .cs/private keeps this session's checkpoints in its vault, but .cs/checkpoints is still plaintext. Move it to .cs/private/checkpoints or delete it, then reopen."
    fi
    # A narrative in the vault rotates into it; a .cs/narrative-archive link
    # into the vault is where rotation writes, not a leftover.
    if [ -L "$meta/memory" ] && [ -e "$meta/narrative-archive" ] && [ ! -L "$meta/narrative-archive" ]; then
        error "$1: this session's narrative lives in its vault, but .cs/narrative-archive is still plaintext. Move it to .cs/private/narrative-archive or delete it, then reopen."
    fi
}

# Create session directory structure
# The part of a session README every reader parses: the YAML frontmatter
# (status, created, tags, aliases) and the `# Session: <name>` title, followed
# by one blank line. Callers append their own body. The TUI, the hooks and
# `cs -list` read these fields, so every session kind writes them here.
_write_session_readme_head() {  # readme, name, tags_yaml, aliases_yaml
    local readme="$1" name="$2" tags="$3" aliases="$4"
    cat > "$readme" << EOF
---
status: active
created: $(date '+%Y-%m-%d')
tags: $tags
aliases: $aliases
---
# Session: $name

EOF
}

create_session_structure() {
    local session_dir="$1"
    local claude_session_id claude_session_color
    claude_session_id=$(_alloc_uuid)
    claude_session_color=$(_alloc_random_color)

    mkdir -p "$session_dir/.cs/local"
    _harden_session_meta "$session_dir"

    # Machine-local values go to .cs/local/state, never the git-synced README.
    _set_local_state "$session_dir/.cs/local/state" claude_session_id "$claude_session_id"
    _set_local_state "$session_dir/.cs/local/state" claude_session_color "$claude_session_color"

    # Create README.md with YAML frontmatter for structured queries. A brand
    # new session never has one yet; adopt's orphaned-.cs re-adopt path is the
    # one caller that runs this against a directory that already carries one,
    # and its records must survive untouched.
    if [ ! -f "$session_dir/.cs/README.md" ]; then
        _write_session_readme_head "$session_dir/.cs/README.md" "$(basename "$session_dir")" "[]" "[\"$(basename "$session_dir")\"]"
        cat >> "$session_dir/.cs/README.md" << EOF
**Started:** $(date '+%Y-%m-%d %H:%M:%S')
**Location:** $(hostname):$(pwd)

## Objective

[Describe what you're trying to accomplish in this session]

## Environment

[Describe the system, server, or context you're working in]

## Outcome

[To be filled when session is complete - summarize what was accomplished]
EOF
    fi


    write_session_claude_md "$session_dir"

    # Initialize session log (machine-local; never git-synced)
    cat > "$session_dir/.cs/local/session.log" << EOF
Claude Code Session Log
Session: $(basename "$session_dir")
Started: $(date '+%Y-%m-%d %H:%M:%S')
Location: $(hostname):$(pwd)

================================================================================

EOF

    # Redirect Claude Code auto memory into the session directory
    setup_auto_memory "$session_dir"

    # Create the session narrative topic file + index pointer
    ensure_narrative_file "$session_dir"
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

# Move a file or directory if source exists and destination doesn't (idempotent)
migrate_if_exists() {
    local src="$1" dst="$2"
    if [ -e "$src" ] && [ ! -e "$dst" ]; then
        mv "$src" "$dst"
    fi
}

# Convert a legacy line-per-message inbox (already renamed to
# inbox.jsonl.migrating) into per-message maildir documents. Lines at or below
# the old `seen` cursor were read and go to cur/; the rest go to new/. A line
# that does not parse at all is quarantined in mail/corrupt.jsonl — it is
# evidence of the append tearing the maildir removes, not garbage. Records may
# lack a numeric ts (accepted and pinned by test) or a usable id, so neither
# is assumed for the filename: a missing ts sorts to the front and a missing id
# becomes a migration-local sequence, preserving order within the legacy file.
# Every name derives only from the legacy content, so converting the same file
# twice produces the same names and the second run delivers nothing new — which
# is what makes an interrupted conversion safe to retry. Deletes the converted
# file and the cursor when done.
_convert_legacy_inbox() {  # maildir
    local maildir="$1" legacy="$1/inbox.jsonl.migrating"
    [ -f "$legacy" ] || return 0
    _mail_ensure_maildir "$maildir"
    local seen=""
    if [ -f "$maildir/seen" ]; then
        IFS= read -r seen < "$maildir/seen" || true
    fi
    case "$seen" in ''|*[!0-9]*) seen=0;; esac
    local lineno=0 seq=0 line meta ts id fname dest failed=0
    # `|| [ -n "$line" ]` converts a final line the stale writer never
    # terminated rather than dropping it.
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        case "$line" in *[![:space:]]*) : ;; *) continue ;; esac
        meta=$(printf '%s\n' "$line" | jq -r '
            (try (if (.ts|type) == "number" then (.ts|floor|tostring) else "" end) catch "") + "\t" +
            (try (if (.id|type) == "string" then .id else "" end) catch "")
        ' 2>/dev/null) || meta=""
        if [ -z "$meta" ]; then
            printf '%s\n' "$line" >> "$maildir/corrupt.jsonl"
            continue
        fi
        seq=$((seq + 1))
        ts="${meta%%$'\t'*}"
        id="${meta#*$'\t'}"
        # Base-10 normalize before printf %d, which reads a leading zero as octal.
        # A record with no usable ts sorts to the front rather than taking the
        # migration's own clock: "now" differs on every run, which would give
        # the same record a new name each time and defeat the rerun guard below.
        case "$ts" in ''|*[!0-9]*) ts=0;; *) ts=$((10#$ts));; esac
        case "$id" in ''|*[!A-Za-z0-9._-]*) id=$(printf 'legacy-%04d' "$seq");; esac
        # The line's own position is part of the name, so the name depends only
        # on the legacy file's content -- the same record converts to the same
        # filename on every run.
        fname="$(printf '%010d' "$ts")-${id}-$(printf '%04d' "$seq").json"
        if [ "$lineno" -le "$seen" ]; then dest="cur"; else dest="new"; fi
        # A conversion interrupted partway leaves records already delivered.
        # Skip those, in EITHER box: re-delivering one the recipient has since
        # read would resurrect it as unread, and delivering it twice would show
        # the same message twice.
        if [ -e "$maildir/new/$fname" ] || [ -e "$maildir/cur/$fname" ]; then
            continue
        fi
        if ! { printf '%s\n' "$line" > "$maildir/tmp/$fname" \
                && mv "$maildir/tmp/$fname" "$maildir/$dest/$fname"; }; then
            rm -f "$maildir/tmp/$fname"
            failed=1
        fi
    done < "$legacy"
    # Only drop the legacy file once every record reached a box. A failed write
    # is the non-final command of an && list, so errexit does not fire and the
    # loop runs on; unlinking here regardless would destroy the one copy of the
    # mail that never landed. Retrying is safe because the names above are a
    # pure function of the legacy content.
    [ "$failed" -eq 0 ] && rm -f "$legacy" "$maildir/seen"
    return 0
}

# One-time, idempotent mailbox migration, keyed ONLY on inbox.jsonl existing.
# It must not also require new/ to be absent: delivery creates the recipient's
# maildir on send, so a session receiving one new-format message before its
# next open would otherwise read the gate false forever and strand its legacy
# unread mail. Renaming before converting keeps a stale writer safe: one
# holding an open descriptor keeps writing into the renamed inode and its
# lines are still converted; one that reopens the path creates a fresh
# inbox.jsonl, which the next open converts.
migrate_mailbox() {  # session_dir
    local maildir="$1/.cs/local/mail"
    # A migration interrupted between rename and delete left real mail in
    # inbox.jsonl.migrating; convert it before renaming a fresh inbox over it.
    _convert_legacy_inbox "$maildir"
    [ -f "$maildir/inbox.jsonl" ] || return 0
    mv "$maildir/inbox.jsonl" "$maildir/inbox.jsonl.migrating" 2>/dev/null || return 0
    _convert_legacy_inbox "$maildir"
}

# Check if session needs migration from flat layout to .cs/ directory
needs_cs_migration() {
    local session_dir="$1"
    [[ ! -d "$session_dir/.cs" ]] && { [[ -d "$session_dir/logs" ]] || [[ -f "$session_dir/discoveries.md" ]]; }
}

# Rewrite the read-all-narratives sentences cs wrote into existing sessions, and
# the read-the-live-narratives sentences that replaced them (nobody can read a
# teammate's whole file either; a resume reads its own in full and a teammate's
# only from the line the digest names). Three places cs owns: a narrative's
# frontmatter description, its MEMORY.md pointer and the protocol block in
# CLAUDE.local.md. Only the exact sentences cs emitted are
# touched — a narrative body or a user's own prose never is. Temp+mv rather than
# sed -i (BSD/GNU disagree on -i). Idempotent: nothing matches on the second run.
migrate_narrative_resume_wording() {  # session_dir, [actor_slug]
    local session_dir="$1" actor="${2:-}"
    local mem="$session_dir/.cs/memory" f
    if [ -z "$actor" ]; then
        actor=$(cs_actor_slug "$session_dir")
    fi
    # Only the actor's own narrative: a teammate's file is theirs to migrate on
    # their own resume, and a committed edit to its head would show up in their
    # teammates' digests as growth that is not a tail.
    f="$mem/narrative.$actor.md"
    # Keyed to the description line specifically (not just "somewhere in the
    # first 8 lines"): a cs-written narrative has exactly 7 header lines, so
    # a body line beginning on line 8 sits inside a bare line-range window
    # too and would otherwise be rewritten. No pipe into grep -q: under
    # pipefail a huge first line can make `head -8 | grep -q` exit 141 and
    # silently skip the file.
    if [ -f "$f" ] \
        && awk 'NR <= 8 && /^description: .*Read (all|the live) narrative\.\*\.md on resume[.;]/ { f = 1 } NR > 8 { exit } END { exit !f }' "$f"; then
        # One replacement for both vintages: the pattern alternates, the
        # sentence appears once, so a typo cannot migrate half the population
        # to a wording no later gate matches.
        cs_write_atomic "$f" sed -E '1,8{/^description: /s/Read (all narrative\.\*\.md on resume\.|the live narrative\.\*\.md on resume; older sections are archived under \.cs\/narrative-archive\/\.)/Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs\/narrative-archive\/./;}' "$f" \
            || { warn "could not rewrite $f; its description keeps the old wording"; _CS_MIGRATE_CLEAN=0; }
    fi
    f="$mem/MEMORY.md"
    if [ -f "$f" ] && grep -qE 'read (all|the live) narrative\.\*\.md on resume' "$f"; then
        cs_write_atomic "$f" sed -E 's/read (all narrative\.\*\.md on resume|the live narrative\.\*\.md on resume, older sections under \.cs\/narrative-archive\/)/its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs\/narrative-archive\//' "$f" \
            || { warn "could not rewrite $f; its narrative pointer keeps the old wording"; _CS_MIGRATE_CLEAN=0; }
    fi
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

# Phases 13, 5, 7, 6 and 12: the cs-managed text in the narrative, CLAUDE.md,
# CLAUDE.local.md and .cs/README.md. Each phase is a no-op once its file is
# current.
_migrate_session_documents() {  # session_dir, tracked_tree_is_ours, actor_slug
    local session_dir="$1" tracked_tree_is_ours="$2" actor_slug="$3"

    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation.
    migrate_narrative_resume_wording "$session_dir" "$actor_slug"

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
    if [ "$tracked_tree_is_ours" = 1 ]; then
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

    # Phase 7: prune retired command-tracker artifacts.
    if [ "$tracked_tree_is_ours" = 1 ]; then
        prune_commands_artifacts "$session_dir"
    fi

    # Phase 6: Add YAML frontmatter to README.md if missing
    local readme="$session_dir/.cs/README.md"
    # A trailing CR is stripped before the test: a repo cloned with autocrlf
    # with default autocrlf has "---\r" on line 1, which '^---$' does not match —
    # so this phase read the file as having NO frontmatter and PREPENDED a second
    # block, leaving the original orphaned in the body. Two frontmatter blocks
    # break every reader of it (tags, status, aliases) and strand the
    # machine-local fields outside the bounded block Phase 12 scans.
    if [ -f "$readme" ] && ! head -1 "$readme" | tr -d '\r' | grep -q '^---$'; then
        local session_name
        session_name=$(basename "$session_dir")
        # Derive created date from the "Started:" line, then from the git
        # date the README was added (shared history — every clone derives
        # the same value), then from file mtime (non-git sessions only;
        # mtime is not preserved across clones so it must never feed a
        # value that another machine could contradict on merge).
        local created_date
        created_date=$(grep -oE 'Started:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}' "$readme" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
        if [ -z "$created_date" ]; then
            created_date=$(git -C "$session_dir" log --diff-filter=A --format=%as -- .cs/README.md 2>/dev/null | tail -1 || true)
        fi
        if [ -z "$created_date" ]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                created_date=$(stat -f '%Sm' -t '%Y-%m-%d' "$readme" 2>/dev/null || date '+%Y-%m-%d')
            else
                created_date=$(stat -c '%y' "$readme" 2>/dev/null | cut -d' ' -f1 || date '+%Y-%m-%d')
            fi
        fi
        local existing_content
        existing_content=$(cat "$readme")
        # Through a temp file, like every neighbouring write: redirecting onto
        # the README truncates the user's file before a byte is written, so a
        # write that does not complete leaves nothing behind.
        if cs_write_atomic "$readme" printf -- '---\nstatus: active\ncreated: %s\ntags: []\naliases: ["%s"]\n---\n%s\n' \
            "$created_date" "$session_name" "$existing_content" 2>/dev/null; then
            warn "Added frontmatter to .cs/README.md"
        else
            _CS_MIGRATE_CLEAN=0
        fi
    fi

    # Phase 12: Move machine-local fields out of README frontmatter into
    # .cs/local/state. claude_session_id / claude_session_color are copied
    # (unless the state file already has its own value — the local machine's
    # binding wins over whatever another machine last pushed); last_resumed
    # and updated are dropped, they are regenerated activity stamps. The
    # README then loses all four lines: hooks on every machine rewrote them
    # with divergent values, which made merge conflicts inevitable whenever
    # a session was shared through git.
    local _state="$session_dir/.cs/local/state"
    # Bounded to the frontmatter block: opened by the `---` on line 1 that Phase 6
    # guarantees, and CLOSED by a second one, which it does not. Without a
    # terminator there is no way to tell frontmatter from prose — fm would stay
    # set to EOF and the strip below would delete a body line — so an unclosed
    # block is left entirely alone. All four keys are ordinary English, and the README
    # carries hand-written prose sections, so a body line beginning "updated:"
    # is the user's own content — matching it anywhere in the file deleted it.
    local _fm_field_re='^(claude_session_id|claude_session_color|last_resumed|updated):'
    # Matching is done on a CR-stripped COPY of each line, and the file is written
    # back untouched: a repo cloned with autocrlf enabled
    # arrives as CRLF, where /^---$/ never matches "---\r", fm is never set, and
    # the whole strip silently no-ops.
    if [ -f "$readme" ] && awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; next }
            fm && line == "---"      { closed = 1; exit }
            fm && line ~ re          { found = 1 }
            END                      { exit (found && closed) ? 0 : 1 }
        ' "$readme"; then
        local _legacy_uuid _legacy_color
        _legacy_uuid=$(awk '/^claude_session_id:/ { sub(/^claude_session_id:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        _legacy_color=$(awk '/^claude_session_color:/ { sub(/^claude_session_color:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit }' "$readme")
        # The README is whatever the clone or the adopted project committed, so
        # only a UUID is taken as a conversation id.
        if [ -n "$_legacy_uuid" ] && [ -z "$(_read_local_state "$_state" claude_session_id)" ]; then
            if _is_uuid "$_legacy_uuid"; then
                _set_local_state "$_state" claude_session_id "$_legacy_uuid"
            else
                warn "ignoring claude_session_id in .cs/README.md: not a UUID, so it names no conversation"
            fi
        fi
        # The colour is claude's first prompt, so the same rule: only one of
        # claude's own colours is taken; anything else leaves the slot empty for
        # the backfill below.
        if [ -n "$_legacy_color" ] && [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
            if _is_session_color "$_legacy_color"; then
                _set_local_state "$_state" claude_session_color "$_legacy_color"
            else
                warn "ignoring claude_session_color in .cs/README.md: not one of claude's colours"
            fi
        fi
        if cs_write_atomic "$readme" awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; print; next }
            fm && line == "---"      { fm = 0; print; next }
            fm && line ~ re          { next }
            { print }
        ' "$readme"; then
            warn "Moved machine-local fields from .cs/README.md to .cs/local/state"
        else
            warn "could not rewrite $readme; its machine-local fields stay in it"
            _CS_MIGRATE_CLEAN=0
        fi
    fi
}

# Phases 9, 10 and 14: the cs sections of CLAUDE.local.md.
_ensure_claude_local_sections() {  # session_dir
    local session_dir="$1"

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

To opt out, delete the prose above but keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
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
}

# The session files a completed migration vouches for. Changed after the stamp
# (newer than it), any of them sends the next open through the full migration.
CS_MIGRATION_PROBES=".gitignore .gitattributes CLAUDE.local.md CLAUDE.md .cs/README.md"

# How far an open can trust the last completed migration, from the stamp
# .cs/local/migrated. Prints "fresh" when it can skip every one-time phase,
# "narrative" when only MEMORY.md changed after the stamp (Claude Code writes
# it, and only the narrative check reads it), or "stale: <reason>" when the
# open must run them all.
_migration_stamp_state() {  # session_dir, actor_raw
    local stamp="$1/.cs/local/migrated" line1="" line2="" rest p encrypted=0
    if [ ! -f "$stamp" ]; then
        echo "stale: no stamp"
        return 0
    fi
    if ! { IFS= read -r line1 && IFS= read -r line2; } < "$stamp" 2>/dev/null || [ -z "$line2" ]; then
        echo "stale: the stamp is unreadable or incomplete"
        return 0
    fi
    case "$line1" in
        "$VERSION"$'\t'*) ;;
        *) echo "stale: written by cs ${line1%%$'\t'*}, not $VERSION"; return 0 ;;
    esac
    case "$line1" in
        "$VERSION"$'\t'"$2"$'\t'*) ;;
        *) echo "stale: written for another actor"; return 0 ;;
    esac
    if [ -d "$1/.cs/private" ]; then
        encrypted=1
    fi
    if [ "$line1" != "$VERSION"$'\t'"$2"$'\t'"$encrypted" ]; then
        echo "stale: the stamp records another encryption state"
        return 0
    fi
    rest="$line2"
    while [ -n "$rest" ]; do
        p=${rest%%$'\t'*}
        rest=${rest#"$p"}
        rest=${rest#$'\t'}
        if [ -n "$p" ] && [ ! -e "$1/$p" ]; then
            echo "stale: $p is gone"
            return 0
        fi
    done
    for p in $CS_MIGRATION_PROBES; do
        if [ "$1/$p" -nt "$stamp" ]; then
            echo "stale: $p changed after the stamp"
            return 0
        fi
    done
    # setup_merge_attributes sets merge.ours.driver in a checkout cs commits
    # into, and the doctor's advice for a missing one is to launch once. Every
    # `git config` write rewrites .git/config (SessionStart's hideRefs on each
    # launch among them), so its modification time says nothing: read the value.
    if [ -e "$1/.git" ] && [ "$(_read_local_state "$1/.cs/local/state" git_bookkeeping)" != "exclude" ] \
        && [ "$(git -C "$1" config --get merge.ours.driver 2>/dev/null)" != "true" ]; then
        echo "stale: merge.ours.driver is not set"
        return 0
    fi
    if [ "$1/.cs/memory/MEMORY.md" -nt "$stamp" ]; then
        echo "narrative"
        return 0
    fi
    echo "fresh"
}

# Record a completed migration in .cs/local/migrated. Line 1: the cs version,
# the raw actor and whether the session is encrypted (1) or not (0), tab
# separated. Line 2: the probe files that exist now, tab separated, so a later
# open can tell one was deleted.
_write_migration_stamp() {  # session_dir, actor_raw, actor_slug
    local dir="$1" encrypted=0 listed="" p
    if [ -d "$dir/.cs/private" ]; then
        encrypted=1
    fi
    for p in $CS_MIGRATION_PROBES .cs/memory/MEMORY.md ".cs/memory/narrative.$3.md" .claude/settings.local.json; do
        if [ -e "$dir/$p" ]; then
            listed="$listed${listed:+$'\t'}$p"
        fi
    done
    cs_write_atomic "$dir/.cs/local/migrated" printf '%s\t%s\t%s\n%s\n' "$VERSION" "$2" "$encrypted" "$listed"
}

# Migrate existing session to latest format
migrate_session() {
    local session_dir="$1"

    # Sessions created before cs set a mode are still world-readable on disk,
    # and git does not record directory modes, so a fresh clone recreates .cs
    # under the cloner's umask however it was set on the other machine.
    _harden_session_meta "$session_dir"
    # The root only when cs owns it. An adopted session's real directory is the
    # user's project, living wherever they keep it — re-permissioning that on
    # every launch would change their directory behind their back. Testing the
    # PARENT rather than the name: by the time migrate runs, the path has been
    # resolved through the symlink, so the adopted session no longer looks like
    # a link and its basename is the project's, not the session's.
    if _session_root_is_cs_owned "$session_dir"; then
        chmod 700 "$session_dir" 2>/dev/null || true
    fi

    # Per-actor local state must never be committed; refuse if it has been.
    cs_assert_local_untracked "$session_dir"
    if [ "$(_read_local_state "$session_dir/.cs/local/state" git_bookkeeping)" = "exclude" ]; then
        local conflict
        conflict=$(_exclude_session_tracked_conflict "$session_dir")
        if [ -n "$conflict" ]; then
            case "$conflict" in
                *symlink) error "$conflict in $session_dir, and cs writes through it at every open. Replace it with a real file or directory, or cs -rm the session." ;;
                *) error "$conflict is tracked on the branch in $session_dir, and cs would rewrite it at every open. Stop tracking it, or cs -rm the session." ;;
            esac
        fi
    fi

    # A migration that completes without a warning stamps .cs/local/migrated.
    # While the stamp is fresh the one-time phases below have nothing left to
    # do, so a reopen skips them ("none"); when MEMORY.md alone changed it runs
    # only the narrative check and restamps ("narrative"). The refusals above
    # and the phases that only test for a leftover's existence run on every
    # open. The stamp sits after cs_assert_local_untracked on purpose: a stamp
    # committed into git is refused before anything trusts it. A phase that
    # carries on past a failed write clears _CS_MIGRATE_CLEAN, so the next
    # open retries it.
    local actor_raw actor_slug="" repair=all
    actor_raw=$(cs_actor_raw "$session_dir" "$session_dir/.cs")
    case "$(_migration_stamp_state "$session_dir" "$actor_raw")" in
        fresh) repair=none ;;
        narrative) repair=narrative ;;
    esac
    _CS_MIGRATE_CLEAN=1

    # Backfill the merge attributes on existing sessions, and the .cs/local/
    # ignore rule on older sessions whose .gitignore predates it, so per-actor
    # local state never gets committed (which would otherwise trip
    # cs_assert_local_untracked and block the next resume). An adopted Claude
    # Code worktree keeps cs's files out of git through the repo's common
    # exclude instead (git_bookkeeping: exclude): nothing of cs's is committed
    # there for attributes to govern, and an in-tree .gitignore or
    # .gitattributes would be the one thing dirtying its PR branch.
    # The same sessions keep their tracked CLAUDE.md as the branch has it: the
    # two CLAUDE.md migrations further down are skipped for them too.
    local tracked_tree_is_ours=1
    if [ "$(_read_local_state "$session_dir/.cs/local/state" git_bookkeeping)" = "exclude" ]; then
        tracked_tree_is_ours=0
    fi
    if [ "$tracked_tree_is_ours" = 1 ] && [ "$repair" = all ]; then
        setup_merge_attributes "$session_dir"
        ensure_cs_gitignore_entries "$session_dir"
    fi

    # Phase 1: Structural migration (flat layout -> .cs/ directory)
    if needs_cs_migration "$session_dir"; then
        mkdir -p "$session_dir/.cs"

        # Move directories
        migrate_if_exists "$session_dir/logs" "$session_dir/.cs/logs"
        migrate_if_exists "$session_dir/archives" "$session_dir/.cs/archives"
        migrate_if_exists "$session_dir/age-recipients" "$session_dir/.cs/age-recipients"

        # Move metadata files
        migrate_if_exists "$session_dir/README.md" "$session_dir/.cs/README.md"
        migrate_if_exists "$session_dir/discoveries.md" "$session_dir/.cs/discoveries.md"
        migrate_if_exists "$session_dir/summary.md" "$session_dir/.cs/summary.md"
        migrate_if_exists "$session_dir/secrets.enc" "$session_dir/.cs/secrets.enc"
        migrate_if_exists "$session_dir/secrets.age" "$session_dir/.cs/secrets.age"

        # Update .gitignore for new structure
        create_session_gitignore "$session_dir"

        echo ""
        echo -e "${ORANGE}Migrated session to .cs/ directory structure${NC}"
        echo -e "${DIM}Session metadata moved to .cs/ - your workspace root is now clean for project files.${NC}"
        echo ""

        # Commit the migration if git is initialized
        if [ -d "$session_dir/.git" ]; then
            (
                cd "$session_dir" || exit 0
                git add -A 2>/dev/null || true
                if ! git diff --cached --quiet 2>/dev/null; then
                    git commit -q -m "Migrate session structure to .cs/ metadata directory" 2>/dev/null || true
                fi
            )
        fi
    fi

    # Phase 2: Ensure .cs/ subdirectories exist (handles partial migrations and edge cases)
    if [ ! -d "$session_dir/.cs/local" ]; then
        mkdir -p "$session_dir/.cs/local"
    fi

    # Phase 2a: Convert a legacy line-per-message mail inbox to the maildir,
    # and a legacy line-per-task queue file to the queue directory.
    migrate_mailbox "$session_dir"
    _queue_convert_legacy "$session_dir/.cs/local"

    # Phase 2b: Relocate the session log to machine-local state. The audit trail
    # (bash commands, lifecycle events, autosave notes) is per-checkout, not
    # shared — keeping it git-synced with merge=union interleaved every machine's
    # commands into the one shared repo. Move it under .cs/local/ (gitignored) so
    # it stays with the machine that produced it; the shared structured record
    # lives in timeline.jsonl. The tracked deletion is left for the next normal
    # commit, as with the README-frontmatter move below. One-time, idempotent:
    # once the old file is gone the block is a no-op. During the upgrade window a
    # peer still on the old cs may keep appending to the tracked log, so a
    # one-time modify/delete conflict on this low-stakes file is possible — take
    # either side.
    # An encrypted session's log belongs behind .cs/private; open has already
    # refused a locked vault, so cs_private_dir resolves here.
    if [ -f "$session_dir/.cs/logs/session.log" ]; then
        local log_dir
        log_dir=$(cs_private_dir "$session_dir/.cs") \
            || error "Cannot move .cs/logs/session.log: .cs/private $(cs_private_state "$session_dir/.cs"), and cs cannot write there."
        cat "$session_dir/.cs/logs/session.log" >> "$log_dir/session.log"
        rm -f "$session_dir/.cs/logs/session.log"
        rmdir "$session_dir/.cs/logs" 2>/dev/null || true
        # Drop the obsolete union rule for the relocated log. awk, not grep -v:
        # grep exits 1 when that was the only line, and an empty file is the
        # right result there.
        local ga="$session_dir/.gitattributes"
        if [ "$tracked_tree_is_ours" = 1 ] && [ -f "$ga" ] && grep -q 'logs/session\.log merge=union' "$ga"; then
            cs_write_atomic "$ga" awk '!/logs\/session\.log merge=union/' "$ga" 2>/dev/null || true
        fi
        warn "Moved .cs/logs/session.log to ${log_dir#"$session_dir"/}/session.log"
    fi

    # Remove inert sync/remote metadata left by older versions (the sync
    # subsystem was removed; nothing reads these files anymore)
    if [ "$repair" = all ]; then
        rm -f "$session_dir/.cs/sync.conf" "$session_dir/.cs/remote.conf"
    fi

    # Phase 4: Ensure auto memory and plans are configured
    if [ ! -d "$session_dir/.cs/memory" ] || [ ! -d "$session_dir/.cs/plans" ] || [ ! -f "$session_dir/.claude/settings.local.json" ]; then
        setup_auto_memory "$session_dir"
    fi

    # Phase 4b: Fold a legacy discoveries.md into the narrative topic file, then
    # ensure the narrative file + index pointer exist (idempotent; skipped while
    # the migration stamp is fresh).
    migrate_discoveries_to_narrative "$session_dir"
    if [ "$repair" != none ]; then
        actor_slug=$(_slugify "$actor_raw")
        ensure_narrative_file "$session_dir" "$actor_slug"
    fi

    if [ "$repair" = all ]; then
        _migrate_session_documents "$session_dir" "$tracked_tree_is_ours" "$actor_slug"
    fi

    local _state="$session_dir/.cs/local/state"
    # Phase 8: Bind claude_session_id in local state to a real claude
    # transcript on disk so `claude --resume <uuid>` resolves to an actual
    # conversation. A recorded UUID with no matching transcript file is an
    # orphan — the cs hooks/doctor cross-checks will warn about it on every
    # launch, and `--resume` will fail. Steady state ("recorded UUID present,
    # transcript exists") is the fast path; cold paths run discovery.
    {
        local _existing _proj _bind_uuid=""
        _existing=$(_read_local_state "$_state" claude_session_id)
        _proj=$(_claude_project_dir "$session_dir")

        if [ -n "$_existing" ] && [ -f "$_proj/$_existing.jsonl" ]; then
            : # already bound — skip discovery entirely
        else
            local _discovered
            _discovered=$(_discover_session_uuid_in "$_proj")
            # No transcripts: a recorded UUID is left alone (claude hasn't
            # written the jsonl yet, eg. the session was just created with
            # --session-id but hasn't talked to the user), and so is an empty
            # slot. Only a transcript on disk names a conversation; an empty
            # slot is the launch's to fill when it starts the first one.
            if [ -n "$_discovered" ]; then
                _bind_uuid="$_discovered"
            fi
        fi

        if [ -n "$_bind_uuid" ]; then
            _set_local_state "$_state" claude_session_id "$_bind_uuid"
            if [ -z "$_existing" ]; then
                warn "Bound claude_session_id in .cs/local/state to $_bind_uuid"
            else
                warn "Repaired orphan claude_session_id (was $_existing)"
            fi
        fi
    }

    if [ "$repair" = all ]; then
        _ensure_claude_local_sections "$session_dir"
    fi

    # Phase 11: Backfill claude_session_color in local state when absent.
    # Picks one of the 8 colors claude's /color command accepts. Idempotent —
    # runs only when the field is missing. Legacy sessions (pre-v2026.5.7)
    # get a randomly-chosen color on next launch and stay on it from then on.
    if [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
        local _new_color
        _new_color=$(_alloc_random_color)
        _set_local_state "$_state" claude_session_color "$_new_color"
        warn "Backfilled claude_session_color in .cs/local/state ($_new_color)"
    fi

    # A stamp that cannot be written costs only speed: without it the next
    # open runs every phase again, which is what it did before the stamp.
    if [ "$repair" != none ] && [ "$_CS_MIGRATE_CLEAN" = 1 ]; then
        _write_migration_stamp "$session_dir" "$actor_raw" "$actor_slug" 2>/dev/null || true
    fi
}

# Cross-platform helpers
