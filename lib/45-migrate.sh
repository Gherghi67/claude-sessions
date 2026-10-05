# ABOUTME: Session structure creation, git merge attributes, and the legacy migration phases.
# ABOUTME: Runs migrate_session on every open to bring old layouts current.

setup_merge_attributes() {
    local dir="$1"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
    git -C "$dir" config merge.ours.driver true 2>/dev/null || true
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

# For a checkout ags hides itself in through info/exclude (git_bookkeeping:
# exclude): the first path ags would rewrite at open that the branch tracks, or
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
    # The .tmp names are the fixed temp files ags writes through before its mv.
    git -C "$dir" ls-files -- .cs .claude/settings.local.json .claude/settings.local.json.tmp CLAUDE.local.md CLAUDE.local.md.tmp 2>/dev/null | head -1
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

# Feature worktrees of an encrypted session are not designed yet. ags -encrypt
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

# The ags content files a plain session keeps in .cs/local and an encrypted one
# keeps behind .cs/private. The open refuses a plaintext copy of any of them,
# and ags -encrypt moves each into the vault.
CS_PRIVATE_LOCAL_FILES="session.log scope-prompt.trace memory-index.snapshot mail
    queue queue.tmp queue.state queue.done queue.declined queue.migrating
    notifications.jsonl notifications.seen failures rewrite.trace pending-handoff"

# Once .cs/private holds a session's ags content files, a copy still in
# .cs/local is plaintext the vault was meant to hold: an unmigrated log, or one
# written by an older ags. Named rather than moved, since a move cannot remove
# the copies backups and snapshots already hold.
_refuse_plaintext_beside_private() {  # session_name, session_dir
    local meta="$2/.cs" name
    [ -e "$meta/private" ] || return 0
    for name in $CS_PRIVATE_LOCAL_FILES; do
        [ -e "$meta/local/$name" ] || continue
        error "$1: .cs/private keeps this session's ags files in its vault, but .cs/local still holds $name in plaintext. Move it into .cs/private or delete it, then reopen."
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
# `ags -list` read these fields, so every session kind writes them here.
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
    local session_dir="$1" engine="${2:-claude}"

    mkdir -p "$session_dir/.cs/local"
    _harden_session_meta "$session_dir"

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


    # Initialize session log (machine-local; never git-synced)
    cat > "$session_dir/.cs/local/session.log" << EOF
Agent Sessions Log
Session: $(basename "$session_dir")
Started: $(date '+%Y-%m-%d %H:%M:%S')
Location: $(hostname):$(pwd)

================================================================================

EOF

    # Portable storage exists regardless of the selected provider.
    mkdir -p "$session_dir/.cs"/{memory,plans}

    # Create the session narrative topic file + index pointer
    cs_engine_call "$engine" prepare_workspace "$session_dir" create || return $?
    ensure_narrative_file "$session_dir"
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
migrate_narrative_resume_wording() {
    local session_dir="$1"
    local mem="$session_dir/.cs/memory" f tmp
    # Only the actor's own narrative: a teammate's file is theirs to migrate on
    # their own resume, and a committed edit to its head would show up in their
    # teammates' digests as growth that is not a tail.
    f="$mem/narrative.$(cs_actor_slug "$session_dir").md"
    # Keyed to the description line specifically (not just "somewhere in the
    # first 8 lines"): a cs-written narrative has exactly 7 header lines, so
    # a body line beginning on line 8 sits inside a bare line-range window
    # too and would otherwise be rewritten. No pipe into grep -q: under
    # pipefail a huge first line can make `head -8 | grep -q` exit 141 and
    # silently skip the file.
    if [ -f "$f" ] \
        && awk 'NR <= 8 && /^description: .*Read (all|the live) narrative\.\*\.md on resume[.;]/ { f = 1 } NR > 8 { exit } END { exit !f }' "$f"; then
        tmp="$f.tmp"
        # One replacement for both vintages: the pattern alternates, the
        # sentence appears once, so a typo cannot migrate half the population
        # to a wording no later gate matches.
        sed -E '1,8{/^description: /s/Read (all narrative\.\*\.md on resume\.|the live narrative\.\*\.md on resume; older sections are archived under \.cs\/narrative-archive\/\.)/Its owner reads it in full on resume; anyone else reads only the lines the resume digest names. Older sections are archived under .cs\/narrative-archive\/./;}' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    fi
    f="$mem/MEMORY.md"
    if [ -f "$f" ] && grep -qE 'read (all|the live) narrative\.\*\.md on resume' "$f"; then
        tmp="$f.tmp"
        sed -E 's/read (all narrative\.\*\.md on resume|the live narrative\.\*\.md on resume, older sections under \.cs\/narrative-archive\/)/its owner reads it in full on resume, anyone else only the lines the resume digest names; older sections under .cs\/narrative-archive\//' "$f" > "$tmp" \
            && mv "$tmp" "$f"
    fi

}

# Migrate existing session to latest format
migrate_session() {
    local session_dir="$1" engine="${2:-claude}"

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
                *symlink) error "$conflict in $session_dir, and ags writes through it at every open. Replace it with a real file or directory, or ags -rm the session." ;;
                *) error "$conflict is tracked on the branch in $session_dir, and ags would rewrite it at every open. Stop tracking it, or ags -rm the session." ;;
            esac
        fi
    fi

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
    if [ "$tracked_tree_is_ours" = 1 ]; then
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
    mkdir -p "$session_dir/.cs/local"

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
        # Drop the obsolete union rule for the relocated log. grep -v exits 1 when
        # that was the only line, so guard on presence and tolerate the exit code
        # rather than leaving the rule (and a stray .tmp) behind.
        local ga="$session_dir/.gitattributes"
        if [ "$tracked_tree_is_ours" = 1 ] && [ -f "$ga" ] && grep -q 'logs/session\.log merge=union' "$ga"; then
            { grep -v 'logs/session\.log merge=union' "$ga" > "$ga.tmp"; } 2>/dev/null || true
            mv "$ga.tmp" "$ga" 2>/dev/null || rm -f "$ga.tmp"
        fi
        warn "Moved .cs/logs/session.log to ${log_dir#"$session_dir"/}/session.log"
    fi

    # Remove inert sync/remote metadata left by older versions (the sync
    # subsystem was removed; nothing reads these files anymore)
    rm -f "$session_dir/.cs/sync.conf" "$session_dir/.cs/remote.conf"

    # Native memory import must precede creating a portable memory index.
    cs_engine_call "$engine" prepare_workspace "$session_dir" migrate_storage || return $?
    mkdir -p "$session_dir/.cs"/{memory,plans}

    # Phase 4b: Fold a legacy discoveries.md into the narrative topic file, then
    # ensure the narrative file + index pointer exist (idempotent on every resume).
    migrate_discoveries_to_narrative "$session_dir"
    ensure_narrative_file "$session_dir"

    # Phase 13: the resume protocol reads live narratives only; rewrite the
    # read-all sentences cs wrote into files that predate rotation.
    migrate_narrative_resume_wording "$session_dir"

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
        # Temp+mv, like every neighbouring write: redirecting onto the README
        # truncates the user's file before the block writes a byte, so a write
        # that does not complete leaves nothing behind.
        if { {
            echo "---"
            echo "status: active"
            echo "created: $created_date"
            echo "tags: []"
            echo "aliases: [\"$session_name\"]"
            echo "---"
            echo "$existing_content"
        } > "$readme.tmp"; } 2>/dev/null && mv "$readme.tmp" "$readme"; then
            warn "Added frontmatter to .cs/README.md"
        else
            rm -f "$readme.tmp" 2>/dev/null || true
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
                _set_local_state_if_absent "$_state" claude_session_id "$_legacy_uuid"
            else
                warn "ignoring claude_session_id in .cs/README.md: not a UUID, so it names no conversation"
            fi
        fi
        # The colour is claude's first prompt, so the same rule: only one of
        # claude's own colours is taken; anything else leaves the slot empty for
        # the backfill below.
        if [ -n "$_legacy_color" ] && [ -z "$(_read_local_state "$_state" claude_session_color)" ]; then
            if _is_session_color "$_legacy_color"; then
                _set_local_state_if_absent "$_state" claude_session_color "$_legacy_color"
            else
                warn "ignoring claude_session_color in .cs/README.md: not one of claude's colours"
            fi
        fi
        local _tmp="$readme.tmp"
        awk -v re="$_fm_field_re" '
            { line = $0; sub(/\r$/, "", line) }
            NR == 1 && line == "---" { fm = 1; print; next }
            fm && line == "---"      { fm = 0; print; next }
            fm && line ~ re          { next }
            { print }
        ' "$readme" > "$_tmp" && mv "$_tmp" "$readme"
        warn "Moved machine-local fields from .cs/README.md to .cs/local/state"
    fi

    cs_engine_call "$engine" prepare_workspace "$session_dir" migrate

}

# Cross-platform helpers
