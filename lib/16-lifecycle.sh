# ABOUTME: Shared run orchestration and native-child supervision for every adapter.
# ABOUTME: One launcher owns a token-qualified lease through prepare, run, and cleanup.

_cs_run_cleanup() {
    [ "${_cs_run_active:-0}" = 1 ] || return 0
    # A signal can arrive while a child runs. Reap it before releasing the lease.
    if [ -n "${_cs_run_child_pid:-}" ]; then
        kill -TERM "$_cs_run_child_pid" 2>/dev/null || true
        local deadline=$((SECONDS + 5))
        while kill -0 "$_cs_run_child_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
            sleep 0.1
        done
        kill -KILL "$_cs_run_child_pid" 2>/dev/null || true
        wait "$_cs_run_child_pid" 2>/dev/null || true
        _cs_run_child_pid=""
    fi
    [ -z "${_cs_run_gate:-}" ] || rm -f "$_cs_run_gate" 2>/dev/null || true
    release_session_lock "$_cs_run_meta" || true
    # An encrypted session's vault, mounted by this open's pre-open hook, is
    # detached when the last process holding it ends: here too, so a signal
    # or an error mid-launch does not leave it mounted.
    if declare -F _detach_opened_vault >/dev/null; then _detach_opened_vault || true; fi
    if declare -F reset_tab_title >/dev/null; then reset_tab_title || true; fi
    _cs_run_active=0
}

_cs_run_signal() {  # exit_status
    trap '' INT TERM
    _cs_run_cleanup
    exit "$1"
}

# Keep the native runtime directly below the launcher for Claude's lead-parent
# checks. Explicit stdin preserves terminal access for an asynchronous command
# in a noninteractive Bash shell. All launch paths, fresh and resume, use this.
_cs_run_record_child() {  # meta_dir, pid
    local meta="$1" pid="$2" tmp signature=""
    signature=$(LC_ALL=C "${CS_PS_BIN:-ps}" -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//') || signature=""
    tmp=$(mktemp "$meta/local/.run-child.XXXXXX") || return 1
    if ! jq --argjson pid "$pid" --arg started "$signature" \
        '.native_pid = $pid | .native_started = $started' "$meta/local/run-lease.json" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$meta/local/run-lease.json" || { rm -f "$tmp"; return 1; }
}

cs_run_child() {  # executable, arguments...
    local status=0
    _cs_run_gate=$(mktemp "$_cs_run_meta/local/.run-start.XXXXXX") || return 1
    # The child cannot enter the runtime until its PID is durably registered.
    # If the launcher dies before registration, the waiting child exits itself.
    # After registration, a surviving child keeps the lease live on recovery.
    "${BASH:-/bin/bash}" -c '
        gate=$1; shift
        trap "rm -f \"\$gate\"" EXIT
        while [ "$(cat "$gate" 2>/dev/null)" != run ]; do
            kill -0 "$CS_RUN_OWNER_PID" 2>/dev/null || exit 1
            sleep 0.02
        done
        rm -f "$gate"
        kill -0 "$CS_RUN_OWNER_PID" 2>/dev/null || exit 1
        jq -e --arg id "$CS_RUN_ID" ".run_id == \$id" "$CS_SESSION_META_DIR/local/run-lease.json" >/dev/null 2>&1 || exit 1
        exec "$@"
    ' ags-child "$_cs_run_gate" "$@" <&0 &
    _cs_run_child_pid=$!
    if ! cs_run_with_lease "$_cs_run_meta" _cs_run_record_child "$_cs_run_meta" "$_cs_run_child_pid"; then
        kill -TERM "$_cs_run_child_pid" 2>/dev/null || true
        wait "$_cs_run_child_pid" 2>/dev/null || true
        _cs_run_child_pid=""
        rm -f "$_cs_run_gate"
        _cs_run_gate=""
        return 1
    fi
    printf 'run\n' > "$_cs_run_gate"
    wait "$_cs_run_child_pid" || status=$?
    _cs_run_child_pid=""
    rm -f "$_cs_run_gate"
    _cs_run_gate=""
    return "$status"
}

_cs_run_unarchive() {  # meta_dir, name
    if [ -f "$1/archived" ]; then
        rm -f "$1/archived" || return 1
        printf 'Unarchived: %s\n' "$2"
    fi
}

# Internal compatibility alias for adapters adopting the orchestration API.
cs_run_native() { cs_run_child "$@"; }

cs_launch_session() {  # engine, name, directory, is_new, force, merge, intent
    local engine="$1" name="$2" directory="$3" is_new="$4" force="${5:-}"
    local merge="${6:-}" intent="${7:-auto}" status=0
    local _cs_run_meta="$directory/.cs" _cs_run_active=0 _cs_run_child_pid="" _cs_run_gate=""
    local saved_exit saved_int saved_term
    local CS_RUN_ID CS_RUN_ENGINE="$engine" CS_RUN_OWNER_PID="$$" CS_LEAD_PID="$$"
    CS_RUN_ID=$(_alloc_uuid) || return 1
    export CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID
    unset CS_COLLISION_FORCE
    [ -d "$directory" ] || { printf 'Error: Session directory does not exist: %s\n' "$directory" >&2; return 1; }
    case "$intent" in auto|resume|fresh) ;; *) printf 'Error: Unknown launch intent: %s\n' "$intent" >&2; return 2 ;; esac
    acquire_session_lock "$_cs_run_meta" "$force" "$name" || return $?
    _cs_run_active=1
    saved_exit=$(trap -p EXIT); saved_int=$(trap -p INT); saved_term=$(trap -p TERM)
    trap '_cs_run_cleanup' EXIT
    trap '_cs_run_signal 130' INT
    trap '_cs_run_signal 143' TERM
    cs_export_session_context "$name" "$directory" || status=$?
    unset CS_FRESH_REBIND CS_CLAUDE_SESSION_ID
    if [ "$status" -eq 0 ]; then
        cs_run_with_lease "$_cs_run_meta" _cs_run_unarchive "$_cs_run_meta" "$name" || status=$?
    fi
    if [ "$status" -eq 0 ]; then
        cs_engine_call "$engine" launch "$name" "$directory" "$is_new" "$force" "$merge" "$intent" || status=$?
    fi
    if [ "$status" -eq 0 ]; then
        cs_run_with_lease "$_cs_run_meta" _cs_set_local_state_unlocked "$_cs_run_meta/local/state" engine "$engine" || status=$?
    fi
    _cs_run_cleanup
    trap - EXIT INT TERM
    [ -z "$saved_exit" ] || eval "$saved_exit"
    [ -z "$saved_int" ] || eval "$saved_int"
    [ -z "$saved_term" ] || eval "$saved_term"
    return "$status"
}
