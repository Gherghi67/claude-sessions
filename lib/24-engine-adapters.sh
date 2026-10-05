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
    local capabilities capability
    capabilities=$(cs_engine_call "${1:-}" capabilities) || return $?
    while IFS= read -r capability; do
        [ -n "$capability" ] || continue
        [ "$capability" != "${2:-}" ] || return 0
    done <<< "$capabilities"
    return 1
}
