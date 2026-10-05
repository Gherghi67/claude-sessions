# ABOUTME: First-party runtime registry and the shared adapter dispatch contract.
# ABOUTME: Routes known operations without loading plugins or interpreting shell commands.

# Keep registration explicit. Tests may add a fake adapter to exercise the
# contract without either native runtime; installed cs only ships these two.
CS_ENGINE_IDS=(claude codex)

cs_engine_known() {  # engine
    local engine="${1:-}" registered
    case "$engine" in
        ''|[!a-z]*|*[!a-z0-9_]*) return 1 ;;
    esac
    for registered in "${CS_ENGINE_IDS[@]}"; do
        [ "$engine" != "$registered" ] || return 0
    done
    return 1
}

cs_engine_call() {  # engine operation [arguments...]
    local engine="${1:-}" operation="${2:-}" handler
    if ! cs_engine_known "$engine"; then
        printf 'Error: Unknown engine: %s. Choose claude or codex.\n' "$engine" >&2
        return 2
    fi
    case "$operation" in
        dependencies|capabilities|prepare_workspace|launch) ;;
        *) printf 'Error: Unknown adapter operation: %s\n' "$operation" >&2; return 2 ;;
    esac
    handler="_cs_${engine}_adapter_${operation}"
    if ! declare -F "$handler" >/dev/null; then
        printf 'Error: Engine %s has no %s adapter operation.\n' "$engine" "$operation" >&2
        return 2
    fi
    shift 2
    # A direct function call preserves argument boundaries, stdin, exit status,
    # and the launcher's process/trap behavior. No eval or command substitution.
    "$handler" "$@"
}

cs_engine_supports() {  # engine capability
    local capabilities
    capabilities=$(cs_engine_call "${1:-}" capabilities) || return $?
    # A whole-line match in memory. A here-string loop needs a temp file under
    # bash 3.2, which Codex's read-only sandbox refuses; the loop then read no
    # capabilities and every skill's probe answered "not supported".
    [ -n "${2:-}" ] || return 1
    case $'\n'"$capabilities"$'\n' in
        *$'\n'"$2"$'\n'*) return 0 ;;
    esac
    return 1
}

# The engine this conversation runs under. A launch exports CS_RUN_ENGINE into
# the native child, so a skill's shell sees the run's own engine. Outside a run
# the session's saved preference answers, as the next launch would read it.
_cs_current_engine() {
    if [ -n "${CS_RUN_ENGINE:-}" ]; then
        cs_engine_known "$CS_RUN_ENGINE" || error "Unknown engine in CS_RUN_ENGINE: $CS_RUN_ENGINE"
        printf '%s\n' "$CS_RUN_ENGINE"
        return 0
    fi
    [ -n "${CS_SESSION_DIR:-}" ] && [ -d "$CS_SESSION_DIR/.cs" ] \
        || error "Not in a cs session: CS_SESSION_DIR is unset and no run names its engine"
    _session_engine "$CS_SESSION_DIR" ""
}

# What a skill asks before it relies on an adapter feature: which engine, which
# native conversation the session has bound for it, and what it supports.
# `supports <capability>` answers by exit status alone, so a skill can refuse
# cleanly under an engine that lacks the feature instead of half-running.
cmd_engine() {  # [supports <capability>]
    local engine conversation="" capabilities
    engine=$(_cs_current_engine) || exit 1
    case "${1:-}" in
        '')
            if [ -n "${CS_SESSION_DIR:-}" ] && [ -d "$CS_SESSION_DIR/.cs" ]; then
                conversation=$(cs_binding_read "$CS_SESSION_DIR" "$engine") \
                    || error "Unreadable $engine conversation binding under $CS_SESSION_DIR/.cs/local"
            fi
            capabilities=$(cs_engine_call "$engine" capabilities | tr '\n' ' ')
            printf 'engine: %s\nconversation: %s\ncapabilities: %s\n' \
                "$engine" "$conversation" "${capabilities% }"
            ;;
        supports)
            [ -n "${2:-}" ] && [ $# -eq 2 ] || error "Usage: ags -engine supports <capability>"
            cs_engine_supports "$engine" "$2" && return 0
            printf '%s is not supported under %s in ags\n' "$2" "$engine" >&2
            return 1
            ;;
        *) error "Usage: ags -engine [supports <capability>]" ;;
    esac
}
