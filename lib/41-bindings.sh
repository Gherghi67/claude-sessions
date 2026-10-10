# ABOUTME: Reads and writes engine-qualified native conversation bindings.
# ABOUTME: Keeps each engine's machine-local storage format and writes atomically.

# A missing binding is an ordinary empty result. A present but unusable binding
# is an error: callers must not mistake damaged local storage for a fresh run.
# Native ID shapes belong to the adapters, not this storage layer.
cs_binding_read() {  # session_dir, engine
    local session_dir="$1" engine="$2" path value=""
    case "$engine" in
        claude)
            path="$session_dir/.cs/local/state"
            [ -e "$path" ] || [ -L "$path" ] || return 0
            [ -f "$path" ] && [ -r "$path" ] || return 1
            value=$(_read_local_state "$path" claude_session_id) || return 1
            ;;
        codex)
            path="$session_dir/.cs/local/codex-thread-id"
            [ -e "$path" ] || [ -L "$path" ] || return 0
            [ -f "$path" ] && [ -r "$path" ] || return 1
            # A single terminal newline is allowed. An additional line is
            # malformed storage, even when command substitution would hide it.
            awk 'NR > 1 { exit 1 }' "$path" || return 1
            IFS= read -r value < "$path" || [ -n "$value" ] || return 1
            ;;
        *) return 2 ;;
    esac
    case "$value" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    # Claude's older state reader treats an absent key as an empty binding.
    # Codex's dedicated file has no other fields, so an empty file is corrupt.
    [ "$engine" != codex ] || [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# A replacement is built beside its destination, then renamed into place.
# On any failure the previous binding survives and no temporary file remains.
cs_binding_write() (  # session_dir, engine, native_id
    local session_dir="$1" engine="$2" value="$3" local_dir path tmp
    [ -n "$value" ] || return 1
    case "$value" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    local_dir="$session_dir/.cs/local"
    case "$engine" in
        claude)
            path="$local_dir/state"
            # The established state reader strips quotes and leading spaces.
            # Refuse values that this format cannot recover unchanged.
            case "$value" in
                *'"'*|[[:space:]]*) return 1 ;;
            esac
            ;;
        codex) path="$local_dir/codex-thread-id" ;;
        *) return 2 ;;
    esac
    mkdir -p "$local_dir" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -f "$path" ] && [ -r "$path" ] || return 1
    fi
    umask 077
    tmp=$(mktemp "$local_dir/.binding.XXXXXX") || return 1
    trap 'rm -f "$tmp"' EXIT
    if [ "$engine" = claude ]; then
        if [ -f "$path" ]; then
            awk 'index($0, "claude_session_id:") != 1' "$path" > "$tmp" || return 1
        fi
        printf 'claude_session_id: %s\n' "$value" >> "$tmp" || return 1
    else
        printf '%s\n' "$value" > "$tmp" || return 1
    fi
    mv "$tmp" "$path" || return 1
)

# Stage a candidate without replacing the acknowledged native conversation.
# Keep an earlier unacknowledged transition as recovery evidence when retrying.
_cs_binding_stage_locked() {  # session_dir, engine, previous, candidate, reason, handoff
    local session_dir="$1" engine="$2" previous="$3" candidate="$4"
    local reason="$5" handoff="${6:-}" path tmp archive recorded
    case "$engine" in claude|codex) ;; *) return 2 ;; esac
    [ -n "${CS_RUN_ID:-}" ] && [ -n "$candidate" ] || return 1
    [ "${CS_RUN_ENGINE:-}" = "$engine" ] || return 1
    recorded=$(cs_binding_read "$session_dir" "$engine") || return 1
    [ "$recorded" = "$previous" ] || return 1
    path="$session_dir/.cs/local/pending-binding-$engine.json"
    tmp=$(mktemp "$session_dir/.cs/local/.pending-binding.XXXXXX") || return 1
    if ! jq -nc --arg run_id "$CS_RUN_ID" --arg engine "$engine" \
        --arg previous_id "$previous" --arg candidate_id "$candidate" \
        --arg reason "$reason" --arg handoff "$handoff" \
        '{run_id:$run_id,engine:$engine,previous_id:$previous_id,
          candidate_id:$candidate_id,reason:$reason,handoff:$handoff}' > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if [ -e "$path" ]; then
        archive=$(mktemp "$session_dir/.cs/local/pending-binding-$engine.abandoned.XXXXXX") || {
            rm -f "$tmp"; return 1;
        }
        cp "$path" "$archive" || { rm -f "$tmp" "$archive"; return 1; }
    fi
    mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

cs_binding_stage() {  # session_dir, engine, previous, candidate, reason, [handoff]
    cs_run_with_lease "$1/.cs" _cs_binding_stage_locked "$@"
}
