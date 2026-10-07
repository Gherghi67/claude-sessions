# ABOUTME: Runtime dependency checks and session-name validation.
# ABOUTME: Rejects unsafe names before any filesystem work.

# The command word of CLAUDE_CODE_BIN. Every launch site expands the value
# unquoted, so it splits on IFS (spaces, tabs, newlines); this splits the same
# way, without expanding globs.
_claude_bin_word() {
    local glob_was_off=""
    case $- in *f*) glob_was_off=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $CLAUDE_CODE_BIN
    [ -n "$glob_was_off" ] || set +f
    printf '%s' "${1:-}"
}

check_dependencies() {
    local engine="${1:-claude}"
    local missing
    missing=$(cs_engine_call "$engine" dependencies) || return $?
    if [ -n "$missing" ]; then
        error "Missing required dependencies: ${missing//$'\n'/ }"
    fi
}

# Resolve engine selection before creating or migrating a session. Older
# sessions have no preference and retain Claude unless a default is configured.
_session_engine() {  # session_dir explicit_engine
    local engine="${2:-}"
    if [ -z "$engine" ]; then
        engine=$(_read_local_state "$1/.cs/local/state" engine)
    fi
    if [ -z "$engine" ] && [ -z "${CS_DEFAULT_ENGINE:-}" ]; then
        local installed_engines
        installed_engines=$(cat "${CS_INSTALL_DIR:-$HOME/.local/bin}/.cs-install-engines" 2>/dev/null) || installed_engines=""
        [ "$installed_engines" != codex ] || engine=codex
    fi
    engine="${engine:-${CS_DEFAULT_ENGINE:-claude}}"
    cs_engine_known "$engine" || error "Unknown engine: $engine. Choose claude or codex with --engine."
    printf '%s\n' "$engine"
}

# Validate session name
validate_session_name() {
    local name="$1"

    if [ -z "$name" ]; then
        error "Session name cannot be empty"
    fi

    case "$name" in
        .|..) error "Session name cannot be '.' or '..'" ;;
        # `ags <name>` reads a leading hyphen as a verb: a session named
        # -uninstall would run that verb rather than open, and -rm would reach
        # remove_session.
        -*) error "Session name cannot start with a hyphen" ;;
    esac

    if ! [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        error "Session name must contain only alphanumeric characters, hyphens, underscores, and dots"
    fi
}

# Validate a name used to REFER to an existing session, where the only concern
# is that "$SESSIONS_ROOT/$name" stays inside SESSIONS_ROOT. Deliberately looser
# than validate_session_name, which is the whitelist for names cs CREATES:
# worktree sessions are named <base>@<task> and that function admits no @, so
# borrowing it here would refuse every worktree session. Backslash counts as a
# separator too; nothing cs creates contains either.
validate_session_ref() {  # name
    case "${1:-}" in
        '') error "Session name cannot be empty" ;;
        .|..) error "Session name cannot be '.' or '..'" ;;
        */*|*\\*) error "Session name cannot contain a path separator: $1" ;;
    esac
}

# Split a worktree session name <base>@<task> into CS_WT_BASE / CS_WT_TASK.
# Returns 1 for plain names (no @). Errors out when either half is invalid.
# @ is safe as a separator: validate_session_name has never admitted it, so
# no existing session name can contain one.
