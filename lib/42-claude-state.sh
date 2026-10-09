# ABOUTME: Claude native identity discovery, conversation color, and staged fresh invocation.
# ABOUTME: Keeps native transcripts and executable calls outside shared storage helpers.

_claude_encode_path() {
    local p="$1"
    p="${p//[^A-Za-z0-9]/-}"
    printf '%s' "$p"
}

# The 8 colors claude's /color slash command accepts (verified against the
# binary's own error message in claude 2.1.162). Anything else errors with
# "Invalid color X". Notably absent: teal, magenta, white, black, gray, hex.
CS_VALID_COLORS=(red blue green yellow purple orange pink cyan)

# Pick a random color from CS_VALID_COLORS. Used at session creation to give
# each cs session a distinct prompt-bar accent without user choice. Claude
# defaults to teal; cs randomizes so parallel sessions are visually distinct
# at a glance.
_alloc_random_color() {
    echo "${CS_VALID_COLORS[$((RANDOM % ${#CS_VALID_COLORS[@]}))]}"
}

# Return the path to claude's per-cwd transcript directory. Symlinks in the
# input are resolved via `pwd -P` so the encoding matches claude's own —
# macOS mktemp returns /var/folders/... which is a symlink to
# /private/var/folders/... and claude realpaths cwd before encoding.
# CS_TRANSCRIPTS_DIR overrides the base for tests (also used by doctor).
# A session with .cs/claude-config runs Claude Code on that config dir, so its
# transcripts live in the dir's projects/. A dangling link (vault locked) still
# names that base: the shared one never holds the session's conversations.
_claude_project_dir() {
    local cwd="$1"
    local resolved base="${CS_TRANSCRIPTS_DIR:-$HOME/.claude/projects}"
    resolved=$( (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s' "$cwd" )
    if [ -e "$cwd/.cs/claude-config" ] || [ -L "$cwd/.cs/claude-config" ]; then
        base="$cwd/.cs/claude-config/projects"
    fi
    printf '%s/%s\n' "$base" "$(_claude_encode_path "$resolved")"
}

# Discover claude's most-recently-modified transcript UUID under a project
# directory, or empty string if none. The newest transcript is what
# `claude --continue` would resume, so binding the session's recorded UUID
# to it makes `--resume <uuid>` equivalent to `--continue` on first contact.
# Takes the project dir (not cwd) so callers that already computed it via
# _claude_project_dir can avoid a second symlink resolution.
# True when a transcript shares the session's project dir without being a
# conversation of the session: an agent-team teammate's, or a headless run's.
# A teammate started with the session as its working directory
# writes a top-level transcript into the same project dir as the lead, so the
# filename cannot tell them apart — and it is routinely the newest, because the
# teammate outlives the turn that spawned it.
#
# What separates them is WHERE the teammate frame appears, not whether it does.
# A teammate's brief IS its first user turn. A lead that merely receives
# teammate reports carries the same frame mid-file, because Claude Code injects
# an inbound message as "Another Claude session sent a message:
# <teammate-message ...>" — so testing the whole file would classify every
# team-using lead as a teammate, which is exactly the population this serves.
#
# Reads the file directly rather than `head -c N | grep -q`: an early-exiting
# pipe consumer SIGPIPEs its producer, and transcripts run to megabytes. `-m1`
# also stops at the first user turn instead of scanning a whole transcript to
# prove a marker absent.
#
# A headless run is the other occupant of the project dir: an Agent SDK call
# or a `claude -p` with the session as its working directory. Claude Code stamps
# every user line with the entrypoint that produced it, and the headless ones
# seen so far all begin `sdk-` (`sdk-py`, and `sdk-cli` for `claude -p`), while a
# person's conversation reads `cli` or `claude-desktop`. Measured over 5522
# transcripts on one machine: 4670 began headless, 842 `cli`, 6 `claude-desktop`.
#
# The first line alone does not settle it: `claude --resume` on a run a script
# started makes it a person's conversation, first line unchanged. So a file is a
# headless run only when it opens with an `sdk-` entrypoint AND no later user
# line carries a different value (any string that does not start `sdk-`, the
# empty string included). An opening line with no entrypoint at all, or one
# with a value Claude Code has not invented yet, counts as a conversation
# (unless that value itself begins `sdk-`): a
# wrongly skipped conversation leaves a session resuming nothing, which is
# worse than a wrongly named one. The second read happens only for files that
# open headless; a purely headless one is read to its end. The prompt text
# shares the line with the field, but JSON escapes its quotes, so a prompt that
# quotes the pattern cannot match it.
_is_bystander_transcript() {  # transcript_file
    local first
    first=$(grep -m1 '"type":"user"' "$1" 2>/dev/null) || return 1
    case "$first" in
        *teammate-message*) return 0 ;;
        *'"entrypoint":"sdk-'*)
            # Any entrypoint value that does not begin `sdk-`.
            grep -m1 -E '"entrypoint":"([^s"]|"|s[^d"]|s"|sd[^k"]|sd"|sdk[^-"]|sdk")' "$1" >/dev/null 2>&1 \
                && return 1
            return 0 ;;
    esac
    return 1
}

# Bystanders are skipped rather than merely deprioritised: naming one is wrong
# for every caller — as a rebind target it would bind the session to a
# reviewer's or a script's conversation, and as a resume suggestion it would
# offer to continue one.
_discover_session_uuid_in() {
    local proj="$1"
    [ -d "$proj" ] || return 0
    # Collect first, then iterate a here-string. A `while read` fed by a pipe
    # would SIGPIPE `ls` on the early return — the same trap the direct file
    # read above avoids.
    local listing
    listing=$(ls -t "$proj"/*.jsonl 2>/dev/null) || true
    [ -n "$listing" ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! _is_bystander_transcript "$f"; then
            basename "$f" .jsonl
            return 0
        fi
    done <<< "$listing"
    return 0
}

# The conversation of a Claude Code worktree (`claude --worktree`) once it has
# exited. While it runs, its transcript sits under the worktree's own project
# dir like any other; at exit Claude Code relocates the file into the PARENT
# repo's project dir (2.1.289), beside the parent's own conversations, and the
# worktree's dir is left empty. The moved file keeps a `worktree-state` record
# naming the worktree path, which is what tells it apart from the parent's
# conversations: the newest file in that dir is whatever was last opened on
# the parent, not this worktree. A parent conversation that stepped into the
# worktree with the EnterWorktree tool gains the same record, so the record
# alone does not make a file the worktree's: its first prompt must also be
# stamped with the worktree as cwd, which is where a `claude --worktree`
# session starts and where a parent conversation never does. Newest-first, the
# first non-bystander file that passes both is the worktree's conversation.
# Empty when none does.
_discover_worktree_uuid_in() {  # parent_project_dir, wt_dir
    local proj="$1" wt_real
    [ -d "$proj" ] || return 0
    wt_real=$( (cd "$2" 2>/dev/null && pwd -P) || printf '%s' "$2" )
    # The record is a JSON string, so a `\` or `"` in the path is escaped there;
    # escape the same way before matching, or such a repo never matches.
    wt_real=$(printf '%s' "$wt_real" | sed 's/\\/\\\\/g; s/"/\\"/g')
    local listing
    listing=$(ls -t "$proj"/*.jsonl 2>/dev/null) || true
    [ -n "$listing" ] || return 0
    local f first
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # The closing quote pins the whole path: a worktree named `wt` must not
        # claim `wt2`'s conversation.
        grep -m1 -F "\"worktreePath\":\"$wt_real\"" "$f" >/dev/null 2>&1 || continue
        first=$(grep -m1 '"type":"user"' "$f" 2>/dev/null) || continue
        case "$first" in
            *"\"cwd\":\"$wt_real\""*) ;;
            *) continue ;;
        esac
        if ! _is_bystander_transcript "$f"; then
            basename "$f" .jsonl
            return 0
        fi
    done <<< "$listing"
    return 0
}

# Stage a replacement UUID and launch it under the core controller.
# SessionStart promotes the candidate only after verifying this run and lead.
# Failure preserves the prior binding and the pending transition for inspection.
# With no recorded conversation to leave (the first open after cs -adopt, a
# clone without its machine-local state) this is the session's first
# conversation, not a rotation: no CS_FRESH_REBIND.
_exec_fresh_rebind() {
    local session_dir="$1"
    local reason="${2:-declined-resume}"
    local handoff="${3:-}"
    local spawn_kick="${4:-}"
    local merge_kick="${5:-}"
    # The name cs knows the session by, not the directory's basename: an
    # adopted session lives at the project's own path, so its basename is the
    # project directory and `--name` would open (and create) a different
    # session. cs_launch_session exported the resolved name before handing
    # the launch to the engine, and the open records it in local state; the
    # basename is only the fallback for a session that lives under the
    # sessions root, where the two agree.
    local session_name="${CS_SESSION_NAME:-}"
    [ -n "$session_name" ] || session_name=$(_read_local_state "$session_dir/.cs/local/state" session_name)
    [ -n "$session_name" ] || session_name=$(basename "$session_dir")
    # Only a UUID names a conversation to leave; the launch ignores anything
    # else in the slot, and so does the rotation record.
    local old_uuid
    old_uuid=$(cs_binding_read "$session_dir" claude) || return 1
    _is_uuid "$old_uuid" || old_uuid=""
    local new_uuid
    new_uuid=$(_alloc_uuid)
    # An encrypted session's handoff name is its topic, so it stays out of the
    # plaintext pending record and timeline, and out of claude's argv (visible
    # to ps and in a terminal title); the SessionStart hook names the file from
    # the vault.
    local public_handoff="$handoff"
    if [ -L "$session_dir/.cs/private" ] || [ -e "$session_dir/.cs/private" ]; then
        public_handoff=""
    fi
    cs_binding_stage "$session_dir" claude "$old_uuid" "$new_uuid" "$reason" "$public_handoff" || return 1
    local session_color
    session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)
    local color_arg=""
    _is_session_color "$session_color" && color_arg="/color $session_color"
    # A handoff kick makes the fresh conversation act on its first turn instead of
    # waiting for the user. It stays a bare trigger on purpose: the SessionStart
    # hook (which the same r answer arms via the pending-handoff marker) is the
    # single owner of the how — next-step section, transcript-not-loaded, the
    # narrative pointers — so the wording lives in one place. A merge kick
    # outranks a spawn kick, which outranks the handoff, which outranks the
    # color re-apply; all four ride claude's single prompt slot, so a displaced
    # color returns on the next open.
    local handoff_arg=""
    if [ -n "$public_handoff" ]; then
        handoff_arg="Continue from the pending rotation handoff: read .cs/handoffs/$handoff first."
    elif [ -n "$handoff" ]; then
        handoff_arg="Continue from the pending rotation handoff."
    fi
    local launch_prompt="${merge_kick:-${spawn_kick:-${handoff_arg:-$color_arg}}}"
    export CS_CLAUDE_SESSION_ID="$new_uuid"
    [ -z "$old_uuid" ] || export CS_FRESH_REBIND=1
    # shellcheck disable=SC2086
    cs_run_child $CLAUDE_CODE_BIN --name "$session_name" --session-id "$new_uuid" ${launch_prompt:+"$launch_prompt"}
}

