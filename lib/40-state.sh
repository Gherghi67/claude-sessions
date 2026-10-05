# ABOUTME: Provider-neutral local-state read/write, JSONL records, and actor identity.
# ABOUTME: Backs 'ags -whoami' and 'ags -who'.

_alloc_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    else
        error "no UUID generator available (need uuidgen, /proc/sys/kernel/random/uuid, or python3)"
    fi
}

# A conversation id goes onto claude's command line, and the README a clone or an
# adopted project brings can say anything, so only a UUID counts as one. Same
# pattern as hooks/session-start.sh's UUID_RE.
_is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# True when $1 is one of CS_VALID_COLORS. The recorded colour becomes claude's
# first prompt (`/color <value>`), so every reader checks it here before building
# that prompt: a README frontmatter travels with a clone or an adopted project,
# and a hand-edited state file can hold anything.
_is_session_color() {
    local c
    for c in "${CS_VALID_COLORS[@]}"; do
        [ "$1" = "$c" ] && return 0
    done
    return 1
}

# Machine-local session state lives in .cs/local/state as 'key: value' lines
# (claude_session_id, claude_session_color, last_resumed, and session_name for
# adopted sessions, whose name lives in a symlink no hook can see). It is gitignored
# (see create_session_gitignore) because these values legitimately differ per
# machine — recording them in the git-synced README caused merge conflicts
# whenever two machines resumed the same session.

# Read a key's value from a machine-local state file. Prints the value to
# stdout, or empty if absent or unreadable. Never errors. KEEP THE FORMAT IN
# SYNC WITH bin/cs-statusline's _read_state_key (session name ink, context-pct
# gating) and hooks/session-start.sh's local_state_set.
_read_local_state() {
    local state="$1" key="$2"
    [ -f "$state" ] || return 0
    awk -v key="$key" '
        index($0, key ":") == 1 {
            sub(/^[^:]*:[[:space:]]*/, "")
            gsub(/"/, "")
            print
            exit
        }
    ' "$state" 2>/dev/null || true
}

# Write 'key: value' into a machine-local state file, replacing any existing
# line for that key. Creates .cs/local/ and the file on first write. Atomic
# (tmp+mv), idempotent. A write that fails (permissions, a full disk) names the
# file and returns non-zero; the locking wrappers below then end ags: the launch
# has already told the user what it was about to start, and a silent miss
# leaves the next open resuming nothing.
_cs_set_local_state_unlocked() {
    local state="$1" key="$2" value="$3" tmp
    mkdir -p "$(dirname "$state")" 2>/dev/null || { _cs_state_write_failed "$(dirname "$state")" create; return 1; }
    tmp=$(mktemp "$state.XXXXXX" 2>/dev/null) || { _cs_state_write_failed "$state"; return 1; }
    {
        {
            if [ -f "$state" ]; then
                awk -v key="$key" 'index($0, key ":") != 1' "$state"
            fi && printf '%s: %s\n' "$key" "$value"
        } > "$tmp" && mv "$tmp" "$state"
    } 2>/dev/null || { rm -f "$tmp" 2>/dev/null; _cs_state_write_failed "$state"; return 1; }
}

# Name the file a machine-local state write could not create or replace, as
# error() would, but without exiting: a lease callback returns and its caller
# decides; the wrappers below end ags.
_cs_state_write_failed() {  # path [verb]
    printf "${RED}Error: could not %s %s${NC}\n" "${2:-write}" "$1" >&2
}

_set_local_state() {
    # Even pre-launch migration must serialize the whole read/modify/write,
    # otherwise a color/name update can overwrite a newly acknowledged ID.
    # Run-owned callers already holding a lease use the raw helper above.
    case "$1" in
        */local/state)
            cs_run_guarded "${1%/local/state}" _cs_set_local_state_unlocked "$@"
            ;;
        *) _cs_set_local_state_unlocked "$@" ;;
    esac || exit 1
}

_cs_set_local_state_if_absent_unlocked() {
    [ -z "$(_read_local_state "$1" "$2")" ] || return 0
    _cs_set_local_state_unlocked "$@"
}

_set_local_state_if_absent() {
    case "$1" in
        */local/state)
            cs_run_guarded "${1%/local/state}" _cs_set_local_state_if_absent_unlocked "$@"
            ;;
        *) _cs_set_local_state_if_absent_unlocked "$@" ;;
    esac || exit 1
}

# Remove a key's line from a machine-local state file. A missing file or key is
# a no-op. Atomic (tmp+mv), serialized like _set_local_state, and loud on the
# same failures.
_cs_unset_local_state_unlocked() {
    local state="$1" key="$2" tmp
    [ -f "$state" ] || return 0
    tmp=$(mktemp "$state.XXXXXX" 2>/dev/null) || { _cs_state_write_failed "$state"; return 1; }
    { awk -v key="$key" 'index($0, key ":") != 1' "$state" > "$tmp" && mv "$tmp" "$state"; } 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; _cs_state_write_failed "$state"; return 1; }
}

_unset_local_state() {
    case "$1" in
        */local/state)
            cs_run_guarded "${1%/local/state}" _cs_unset_local_state_unlocked "$@"
            ;;
        *) _cs_unset_local_state_unlocked "$@" ;;
    esac || exit 1
}

# The first prompt somebody typed into a conversation, as an Objective line:
# whitespace collapsed, clipped to 100 characters with an ellipsis. Prints
# nothing when the transcript holds no such prompt, or without jq. User records
# also carry tool results, injected meta text and slash commands, which Claude
# Code records as a <command-name> block indented across lines, so a record
# counts only when its text, once collapsed, starts with none of `/`, `!` or
# `<` and runs to 8 characters or more.
# KEEP IN SYNC with the objective capture in hooks/scope-prompt.sh: the hook
# applies the same rules to the prompt it is handed live.
_transcript_first_prompt() {  # transcript_file
    local file="$1"
    [ -f "$file" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    local candidates
    candidates=$(jq -r -R '
        fromjson? | select(.type == "user" and ((.isMeta // false) | not))
        | .message.content
        | if type == "string" then .
          elif type == "array" then ([.[] | select(.type == "text") | .text] | join(" "))
          else empty end
        | gsub("[\\n\\r\\t]+"; " ") | gsub(" +"; " ")
        | select(length > 0)' "$file" 2>/dev/null) || return 0
    local line
    while IFS= read -r line; do
        line="${line# }"; line="${line% }"
        case "$line" in /*|!*|'<'*) continue ;; esac
        [ "${#line}" -ge 8 ] || continue
        [ "${#line}" -gt 100 ] && line="${line:0:100}…"
        printf '%s\n' "$line"
        return 0
    done <<< "$candidates"
    return 0
}

# Replace the Objective placeholder (a whole line wrapped in [...] under
# `## Objective`) with text, leaving every other line alone. A hand-written
# objective has no placeholder and is never touched. tmp+mv keeps the write
# atomic; ENVIRON sidesteps awk -v escape processing of arbitrary prompt text.
_seed_readme_objective() {  # readme, text
    local readme="$1" text="$2" tmp
    [ -f "$readme" ] && [ -n "$text" ] || return 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/cs-objective.XXXXXX") || return 0
    if OBJ="$text" awk '
            /^## / { in_obj = ($0 ~ /^## Objective/) }
            in_obj && /^\[.*\]$/ { print ENVIRON["OBJ"]; next }
            { print }
        ' "$readme" > "$tmp"; then
        mv "$tmp" "$readme" || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# Terminate a JSONL file whose last line lost its newline to an interrupted
# write, so the next `>>` starts a fresh line instead of splicing two records
# onto one. The tolerant per-line reader (`fromjson? // empty` in
# run_conversations) drops a spliced line whole, which loses the torn record AND
# the intact one appended after it. The torn record itself is unrecoverable —
# it was never complete — but the next one no longer dies with it. A no-op on a
# file that is empty or already terminated, and best-effort on write like every
# other timeline append: a launch must not die because a journal could not be
# repaired.
_terminate_jsonl() {  # file
    [ -s "$1" ] || return 0
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] || return 0
    { printf '\n' >> "$1"; } 2>/dev/null || true
}

# Append a rotated event to the tracked timeline: the durable link between
# the conversation being left and the one about to start. Shape shared with
# hooks/session-start.sh's rebind emitter (hooks cannot source bin/cs).
# Report append failure so acknowledged transitions keep their recovery record.
_timeline_rotated() {  # session_dir, from, to, reason, [handoff]
    local session_dir="$1" from="$2" to="$3" reason="$4" handoff="${5:-}" engine="${6:-claude}"
    _terminate_jsonl "$session_dir/.cs/timeline.jsonl"
    { jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg from "$from" \
           --arg to "$to" \
           --arg reason "$reason" \
           --arg handoff "$handoff" \
           --arg engine "$engine" --arg run_id "${CS_RUN_ID:-}" \
           '{ts: $ts, event: "rotated", engine: $engine, run_id: $run_id, from: $from, to: $to, reason: $reason}
            + (if $handoff == "" then {} else {handoff: $handoff} end)' \
        >> "$session_dir/.cs/timeline.jsonl"; } 2>/dev/null
}

# A native adapter calls this only after its conversation readiness acknowledgement.
_timeline_started() {  # session_dir, engine, native_id, source
    local session_dir="$1" engine="$2" native_id="$3" source="$4"
    _terminate_jsonl "$session_dir/.cs/timeline.jsonl"
    { jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg engine "$engine" --arg session_id "$native_id" --arg source "$source" \
        --arg run_id "${CS_RUN_ID:-}" \
        '{ts:$ts,event:"started",engine:$engine,session_id:$session_id,
          source:$source,run_id:$run_id}' >> "$session_dir/.cs/timeline.jsonl"; } 2>/dev/null
}

# Resolve a SPECIFIC session's actor slug from its own dir, bypassing $CS_ACTOR
# (which cs_actor_slug honours first and would otherwise stamp the caller's
# identity onto every 'ags -live' row). Arg: session_dir (session root).
# Falls back to git config in that dir, then 'unknown'. Always slugified.
session_actor_slug() {  # session_dir
    local session_dir="$1" raw="" id_file="$1/.cs/local/identity"
    if [ -f "$id_file" ]; then IFS= read -r raw < "$id_file" || true; fi
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.email 2>/dev/null || true)"
    [ -n "$raw" ] || raw="$(git -C "$session_dir" config user.name 2>/dev/null || true)"
    [ -n "$raw" ] || raw="unknown"
    _slugify "$raw"
}

# Print the resolved actor slug; warn if the pinned local identity disagrees with git.
cmd_whoami() {
    echo "actor: $(cs_actor_slug)"
    if [ -n "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}" ] && [ -f "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/local/identity" ]; then
        local file_slug="" git_raw="" git_slug=""
        file_slug=$(_slugify "$(head -1 "${CS_SESSION_META_DIR:-${CLAUDE_SESSION_META_DIR:-}}/local/identity")")
        git_raw=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || true)
        git_slug=$(_slugify "$git_raw")
        if [ -n "$git_slug" ] && [ "$file_slug" != "$git_slug" ]; then
            warn "cs actor '$file_slug' differs from git identity '$git_slug' (using cs actor)"
        fi
    fi
}

# Summarize shared memory/narrative contributors from git history (recent
# activity, by author). Not presence — purely a read over git log.
cmd_who() {
    local dir="${CS_SESSION_DIR:-${CLAUDE_SESSION_DIR:-$PWD}}"
    [ -d "$dir/.cs" ] || error "Not in a cs session (no .cs/ in $dir)"
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || error "Session is not a git repo; nothing to summarize"
    echo "Contributors to shared memory/narrative (recent activity):"
    git -C "$dir" log --format='%an|%ad' --date=short -- .cs/memory 2>/dev/null \
        | awk -F'|' '
            { count[$1]++; if ($2 > last[$1]) last[$1] = $2 }
            END {
                for (a in count) printf "%6d  %s  (last %s)\n", count[a], a, last[a]
            }' \
        | sort -rn
}

# Configure conflict-free merges for the session files that multiple
# machines write independently. The Claude-Code-maintained memory index gets
# merge=ours (it is hand-maintained; two branches editing it would conflict,
# and the local copy re-accumulates entries through normal use). The
# append-only log, timeline, and per-actor narratives get merge=union (git's
# built-in driver, no per-clone config) so divergent appends keep both sides.
