# ABOUTME: ags -switch: a rotate that also moves the session to the other engine (Claude <-> Codex).
# ABOUTME: The verb arms pending-switch; the run settles it at exit and main re-execs ags under the target.

# The flow. The switch skill runs rotate's steps (a handoff written and armed
# in pending-handoff), then `ags -switch [engine] [--resume]` checks the target
# and writes <private dir>/pending-switch naming this run. The user exits the
# CLI. cs_launch_session settles the switch before its cleanup, while the lease
# is held and an encrypted session's vault is still mounted (_switch_settle);
# main then re-execs ags for the target from the environment this launch began
# with (_switch_relaunch): `<name> --engine <target> --from-handoff` for a fresh
# conversation, or `--resume`, which feeds the handoff to the target's recorded
# conversation as its first message. No transcript crosses engines: the handoff
# carries the work, as it does for a rotate.
#
# pending-switch is key=value lines, written atomically:
#   engine=<target>  mode=fresh|resume  handoff=<basename>  run=<CS_RUN_ID>
# The run that wrote it is the only one that consumes it, once.

# The file, in .cs/local or an encrypted session's .cs/private. Fails while
# the vault is locked, as cs_private_dir does.
_switch_file() {  # session_dir
    local private
    private=$(cs_private_dir "$1/.cs") || return 1
    printf '%s/pending-switch\n' "$private"
}

# One field of a pending switch, or nothing. The value is everything after the
# first '=', so a handoff name holding one survives.
_switch_field() {  # file, key
    awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$1" 2>/dev/null || true
}

# With two engines, "the other one". Written over the registry so a test
# adapter never makes a third engine everyone's default.
_switch_other_engine() {  # engine
    local registered
    for registered in "${CS_ENGINE_IDS[@]}"; do
        [ "$registered" = "$1" ] && continue
        printf '%s\n' "$registered"
        return 0
    done
    return 1
}

# How the user leaves each CLI. /clear cannot change engines; only an exit
# hands control back to the ags that relaunches.
_switch_quit_command() {  # engine
    case "$1" in
        claude) printf '/exit\n' ;;
        codex) printf '/quit\n' ;;
        *) printf 'its own exit command\n' ;;
    esac
}

# The installer records which engines it set up (skills, hooks). No record is
# an install from before the choice existed, which set up both.
_switch_engine_installed() {  # engine
    local engines
    engines=$(cat "${CS_INSTALL_DIR:-$HOME/.local/bin}/.cs-install-engines" 2>/dev/null) || return 0
    [ -n "$engines" ] || return 0
    [[ ",$engines," == *",$1,"* ]]
}

# The two ways back, for every outcome that leaves the handoff armed.
_switch_reopen_hint() {  # session_name, target, previous_engine
    printf '  ags %s --engine %s --from-handoff\n  ags %s --engine %s\n' "$1" "$2" "$1" "$3"
}

# An encrypted session keeps its handoffs and marker in .cs/private (linked
# into the vault), as cs_private_dir and cs_handoff_dir decide.
_switch_session_encrypted() {  # session_dir
    [ -e "$1/.cs/private" ] || [ -L "$1/.cs/private" ]
}

# Whether an engine's rotation can start from a handoff kept in the vault.
# Codex's cannot yet: its launch's r path and its session-start hook read and
# write .cs/handoffs and .cs/local/pending-handoff, so it would miss the
# handoff, leave the marker armed, and name the handoff (the session's topic)
# in plaintext.
_switch_engine_reads_vault() {  # engine
    [ "$1" != codex ]
}

_switch_usage() {
    error "Usage: ags -switch [--check] [claude|codex] [--resume], or ags -switch cancel"
}

# ags -switch [--check] [claude|codex] [--resume] | cancel
# Run from inside the conversation, after the handoff is written and armed.
# Every refusal is one line naming the fix. --check runs all of them except the
# armed-handoff one and writes nothing: the skill asks before writing a handoff.
cmd_switch() {
    local target="" mode=fresh check="" arg
    if [ "${1:-}" = cancel ]; then
        [ $# -eq 1 ] || _switch_usage
        _switch_cancel
        return $?
    fi
    for arg in "$@"; do
        case "$arg" in
            --check) check=1 ;;
            --resume) mode=resume ;;
            -*) _switch_usage ;;
            *)
                [ -z "$target" ] || _switch_usage
                target="$arg"
                ;;
        esac
    done

    local session_dir="${CS_SESSION_DIR:-}" name="${CS_SESSION_NAME:-}"
    [ -n "$session_dir" ] && [ -d "$session_dir/.cs" ] \
        || error "ags -switch runs inside an ags session; open one with: ags <name>"
    [ -n "$name" ] || name=$(basename "$session_dir")
    # The launcher consumes only the switch its own run wrote, so a shell
    # without a run (or with a stale one) would arm something nothing takes.
    [ -n "${CS_RUN_ID:-}" ] \
        || error "ags -switch runs inside the conversation ags launched; open the session with: ags $name"
    jq -e --arg id "$CS_RUN_ID" '.run_id == $id' "$session_dir/.cs/local/run-lease.json" >/dev/null 2>&1 \
        || error "No live ags run of $name matches this shell's CS_RUN_ID; run ags -switch from the conversation ags launched"
    local file
    file=$(_switch_file "$session_dir") \
        || error "$name's vault is locked (.cs/private $(cs_private_state "$session_dir/.cs")); mount it, then run ags -switch again"

    local current
    current=$(_cs_current_engine) || exit 1
    if [ -z "$target" ]; then
        target=$(_switch_other_engine "$current") \
            || error "No other engine to switch to from $current"
    fi
    cs_engine_known "$target" || error "Unknown engine: $target. Choose claude or codex."
    [ "$target" != "$current" ] \
        || error "This conversation already runs under $current; use the rotate skill to start fresh in the same engine"
    _switch_engine_installed "$target" \
        || error "$target is not set up by this ags install; reinstall with CS_INSTALL_ENGINES=claude,codex, then switch"
    local missing
    missing=$(cs_engine_call "$target" dependencies) || exit 1
    [ -z "$missing" ] \
        || error "Cannot switch to $target: ${missing//$'\n'/ } not found; install it, then run ags -switch again"
    cs_engine_supports "$target" rotation \
        || error "Cannot switch to $target: its adapter has no rotation support to start from the handoff; use the rotate skill instead"
    if _switch_session_encrypted "$session_dir" && ! _switch_engine_reads_vault "$target"; then
        error "Cannot switch to $target: this session is encrypted, and $target does not read handoffs from .cs/private yet; use the rotate skill to continue in $current"
    fi
    # The relaunch opens the session again, and an encrypted one refuses with
    # plaintext leftovers beside its vault (a Codex run writes its session.log
    # to .cs/local). Asked now, before the skill writes a handoff for nothing.
    local refusal
    if _switch_session_encrypted "$session_dir" \
        && ! refusal=$( (_refuse_unmounted_meta "$name" "$session_dir") 2>&1 ); then
        refusal=$(printf '%s' "$refusal" | sed $'s/\033\\[[0-9;]*m//g; s/^Error: //' | head -1)
        error "Cannot switch to $target: ags would not reopen the session. $refusal"
    fi
    if [ -f "$file" ]; then
        error "A switch to $(_switch_field "$file" engine) is already pending; exit this CLI to take it, or run: ags -switch cancel"
    fi

    if [ -n "$check" ]; then
        printf 'ags can switch %s from %s to %s (%s).\n' "$name" "$current" "$target" "$mode"
        return 0
    fi

    local handoff
    handoff=$(_rotation_armed_handoff "$session_dir")
    [ -n "$handoff" ] \
        || error "No rotation handoff is armed; write and arm one first (rotate's steps 1-9), then run ags -switch again"
    cs_write_atomic "$file" printf 'engine=%s\nmode=%s\nhandoff=%s\nrun=%s\n' \
        "$target" "$mode" "$handoff" "$CS_RUN_ID" \
        || error "Could not write $file"
    local how="a fresh $target conversation"
    [ "$mode" = fresh ] || how="$target's last conversation"
    printf 'Switch armed: exit this CLI with %s, and ags reopens %s in %s from %s.\n' \
        "$(_switch_quit_command "$current")" "$name" "$how" "$handoff"
}

# Drops the pending switch and nothing else: the handoff stays armed, so a
# /clear in this engine still continues from it.
_switch_cancel() {
    local session_dir="${CS_SESSION_DIR:-}" file target
    [ -n "$session_dir" ] && [ -d "$session_dir/.cs" ] \
        || error "ags -switch cancel runs inside an ags session"
    file=$(_switch_file "$session_dir") \
        || error "The vault is locked (.cs/private $(cs_private_state "$session_dir/.cs")); mount it, then run ags -switch cancel again"
    if [ ! -f "$file" ]; then
        printf 'No switch is pending.\n'
        return 0
    fi
    target=$(_switch_field "$file" engine)
    rm -f "$file" || error "Could not remove $file"
    printf 'Switch to %s cancelled; the handoff stays armed, so /clear here continues from it.\n' "${target:-the other engine}"
}

# Called by cs_launch_session as a run starts, with the lease held: any pending
# switch is a previous run's, left by a launcher that ended without settling it
# (a closed terminal). Left in place it would turn the mod's countdown into an
# /exit and refuse every later switch.
_switch_run_start() {  # session_dir
    local file
    # A switch relaunch: the handoff it comes to carry, for its settle.
    if [ -n "${_cs_switched_from:-}" ]; then
        _cs_switch_carry=$(_rotation_armed_handoff "$1")
    fi
    file=$(_switch_file "$1") || return 0
    [ -f "$file" ] || return 0
    rm -f "$file" 2>/dev/null || return 0
    printf "${DIM:-}Dropped a pending engine switch an earlier run left behind.${NC:-}\n"
}

# Called by cs_launch_session after the CLI exits, before cleanup releases the
# lease and detaches an encrypted session's vault. Best-effort: it decides and
# says why, and never fails the run. A relaunch is left in _cs_switch_* for
# main, which execs it once cs_launch_session has returned.
_switch_settle() {  # session_name, session_dir, engine, run_status
    local name="$1" dir="$2" engine="$3" status="$4"
    local file target mode handoff run handoffs missing binding refusal

    # A switch relaunch whose CLI failed: its handoff goes back to armed unless
    # the conversation evidently ran. Either way this run has spoken for the
    # relaunch, so main's exit guard (for failures before the run) stays quiet.
    if [ -n "${_cs_switched_from:-}" ]; then
        [ "$status" -eq 0 ] || _switch_relaunch_failed "$name" "$dir" "$engine"
        _cs_switch_reported=1
    fi

    file=$(_switch_file "$dir") || return 0
    [ -f "$file" ] || return 0
    run=$(_switch_field "$file" run)
    # Another run's switch is not this run's to take.
    [ -n "$run" ] && [ "$run" = "${CS_RUN_ID:-}" ] || return 0
    target=$(_switch_field "$file" engine)
    mode=$(_switch_field "$file" mode)
    handoff=$(_switch_field "$file" handoff)
    # Consumed once, whatever happens next.
    rm -f "$file" 2>/dev/null || true

    if ! cs_engine_known "$target" || [ "$target" = "$engine" ]; then
        printf 'Not switching: the pending switch names no other engine (%s).\n' "${target:-none}" >&2
        return 0
    fi
    if [ "$status" -ne 0 ]; then
        printf 'Not switching to %s: %s exited with status %s; the handoff %s stays armed. Reopen with either:\n' \
            "$target" "$engine" "$status" "$handoff" >&2
        _switch_reopen_hint "$name" "$target" "$engine" >&2
        return 0
    fi
    handoffs=$(cs_handoff_dir "$dir/.cs") || return 0
    case "$handoff" in ''|*/*|*\\*) handoff="" ;; esac
    if [ -z "$handoff" ] || [ ! -f "$handoffs/$handoff" ] || ! _handoff_is_unconsumed "$handoffs/$handoff"; then
        printf "${DIM:-}Not switching to %s: the handoff %s was already taken (a /clear in %s continues from it).${NC:-}\n" \
            "$target" "${handoff:-it named}" "$engine"
        return 0
    fi
    missing=$(cs_engine_call "$target" dependencies 2>/dev/null) || missing="$target"
    if [ -n "$missing" ]; then
        printf 'Not switching to %s: %s not found; the handoff %s stays armed. Reopen with either:\n' \
            "$target" "${missing//$'\n'/ }" "$handoff" >&2
        _switch_reopen_hint "$name" "$target" "$engine" >&2
        return 0
    fi
    # The relaunch opens the session again, and an encrypted one with
    # plaintext leftovers beside its vault (a Codex run writes its session.log
    # to .cs/local) would be refused after its pre-open has taken over the
    # exit trap. Ask now, while the handoff can still be named.
    if ! refusal=$( (_refuse_unmounted_meta "$name" "$dir") 2>&1 ); then
        printf 'Not switching to %s: the session would not reopen.\n%s\nThe handoff %s stays armed. Fix that, then reopen with either:\n' \
            "$target" "$refusal" "$handoff" >&2
        _switch_reopen_hint "$name" "$target" "$engine" >&2
        return 0
    fi
    if [ "$mode" = resume ]; then
        binding=$(cs_binding_read "$dir" "$target" 2>/dev/null) || binding=""
        if ! _is_uuid "$binding"; then
            printf "${DIM:-}No recorded %s conversation to resume; starting a fresh one from the handoff.${NC:-}\n" "$target"
            mode=fresh
        fi
    else
        mode=fresh
    fi
    _cs_switch_next="$target"
    _cs_switch_next_mode="$mode"
    _cs_switch_prev="$engine"
    _cs_switch_handoff="$handoff"
    # Keep an encrypted session's vault mounted across the re-exec: the pid
    # stays a listed holder, so the relaunch's pre-open joins the mounted vault
    # instead of asking for the password again.
    _cs_switch_vault_meta="${CS_OPENED_VAULT_META:-}"
    CS_OPENED_VAULT_META=""
    return 0
}

# Taken by main as a launch begins, before anything is exported or changed:
# a relaunch starts from this environment, umask and directory, not from the
# finished run's (its CS_RUN_*, session context, the Claude launch's EDITOR
# shim, Codex's umask 077).
_switch_snapshot() {
    local var
    _cs_switch_env=()
    _cs_switch_env_names=$'\n'
    for var in $(compgen -e); do
        _cs_switch_env+=("$var=${!var-}")
        _cs_switch_env_names="$_cs_switch_env_names$var"$'\n'
    done
    _cs_switch_umask=$(umask)
    _cs_switch_pwd="$PWD"
    case "$0" in
        /*) _cs_switch_self="$0" ;;
        */*) _cs_switch_self="$PWD/$0" ;;
        *) _cs_switch_self=$(command -v "$0" 2>/dev/null) || _cs_switch_self="" ;;
    esac
}

# Called by main after cs_launch_session returns. Without a settled switch it
# returns at once; otherwise it replaces this process with `ags` for the
# target, so the relaunch runs the target's own open steps (dependencies,
# migration or the worktree path, the adapter's launch) under a new run.
_switch_relaunch() {  # session_name
    [ -n "${_cs_switch_next:-}" ] || return 0
    # Putting the environment back exports every snapshot entry, and a user
    # variable named like a local here (a "target" or "name" in their shell)
    # would overwrite it. So the exec's argv, umask and directory are all
    # settled first, in _cs_sw_ locals.
    local _cs_sw_name="$1" _cs_sw_target="$_cs_switch_next" _cs_sw_from="${_cs_switch_prev:-}"
    local _cs_sw_umask="${_cs_switch_umask:-022}" _cs_sw_pwd="${_cs_switch_pwd:-/}"
    local _cs_sw_var _cs_sw_entry _cs_sw_rc=0
    local -a _cs_sw_argv
    if [ -n "${_cs_switch_self:-}" ] && [ -f "$_cs_switch_self" ] && [ -n "${BASH:-}" ]; then
        _cs_sw_argv=("$BASH" "$_cs_switch_self" "$_cs_sw_name" --engine "$_cs_sw_target")
        if [ "${_cs_switch_next_mode:-fresh}" = resume ]; then
            _cs_sw_argv+=(--resume --switched-from "$_cs_sw_from")
            printf "${DIM:-}Switching %s to %s: resuming its last conversation with %s.${NC:-}\n" "$_cs_sw_name" "$_cs_sw_target" "${_cs_switch_handoff:-the handoff}"
        else
            _cs_sw_argv+=(--from-handoff --switched-from "$_cs_sw_from")
            printf "${DIM:-}Switching %s to %s: a fresh conversation from %s.${NC:-}\n" "$_cs_sw_name" "$_cs_sw_target" "${_cs_switch_handoff:-the handoff}"
        fi
        for _cs_sw_var in $(compgen -e); do
            case "${_cs_switch_env_names:-}" in
                *$'\n'"$_cs_sw_var"$'\n'*) ;;
                *) unset "$_cs_sw_var" 2>/dev/null || true ;;
            esac
        done
        for _cs_sw_entry in ${_cs_switch_env[@]+"${_cs_switch_env[@]}"}; do
            export "$_cs_sw_entry" 2>/dev/null || true
        done
        # Even when the shell that started this launch carried them (ags run
        # from inside another session), they name a run that is not this one.
        unset CS_RUN_ID CS_RUN_ENGINE CS_RUN_OWNER_PID CS_LEAD_PID CS_FRESH_REBIND CS_CLAUDE_SESSION_ID 2>/dev/null || true
        umask "$_cs_sw_umask" 2>/dev/null || true
        cd "$_cs_sw_pwd" 2>/dev/null || cd / 2>/dev/null || true
        shopt -s execfail
        exec "${_cs_sw_argv[@]}" || _cs_sw_rc=$?
    fi
    # Only a failed exec gets here: give the vault back and say how to reopen.
    CS_OPENED_VAULT_META="${_cs_switch_vault_meta:-}"
    if declare -F _detach_opened_vault >/dev/null; then _detach_opened_vault || true; fi
    printf 'Could not relaunch ags for %s (status %s); the handoff %s stays armed. Reopen with either:\n' \
        "$_cs_sw_target" "${_cs_sw_rc:-1}" "${_cs_switch_handoff:-}" >&2
    _switch_reopen_hint "$_cs_sw_name" "$_cs_sw_target" "$_cs_sw_from" >&2
    return 1
}

# One notice for a switch relaunch that did not reach its CLI, from whichever
# path saw it first: the run's settle, or the guard below when an open step
# ended ags before the run began.
_switch_failed_notice() {  # session_name, target, previous_engine, handoff
    [ -z "${_cs_switch_reported:-}" ] || return 0
    _cs_switch_reported=1
    printf 'The switch to %s did not start; the handoff %s stays armed. Reopen with either:\n' "$2" "$4" >&2
    _switch_reopen_hint "$1" "$2" "$3" >&2
}

# A switch relaunch whose CLI exited with an error. The handoff it came to
# carry (taken as the run started) is still unconsumed when the CLI never
# reached it: Claude's fresh path leaves it to SessionStart. The resume path
# and Codex's r path spend it before the CLI starts, so it is put back while
# nothing shows the conversation ran: no session start logged since, and no
# newer handoff armed by a rotation inside it. A conversation that ran keeps
# what it took, and this says nothing.
_switch_relaunch_failed() {  # session_name, session_dir, engine
    local name="$1" dir="$2" engine="$3" handoff handoffs private armed
    # Unset when the run ended before its launch, which then spent nothing.
    handoff=${_cs_switch_carry-$(_rotation_armed_handoff "$dir")}
    [ -n "$handoff" ] || return 0
    handoffs=$(cs_handoff_dir "$dir/.cs") || return 0
    private=$(cs_private_dir "$dir/.cs") || return 0
    armed=$(_rotation_marker_basename "$dir")
    [ -z "$armed" ] || [ "$armed" = "$handoff" ] || return 0
    if ! _handoff_is_unconsumed "$handoffs/$handoff"; then
        [ "${_cs_switch_spent:-}" = "$handoff" ] || return 0
        [ "$(_switch_logged_starts "$dir")" = "${_cs_switch_starts:-}" ] || return 0
        _switch_unspend_handoff "$handoffs/$handoff" "${_cs_switch_spent_by:-}" || return 0
    fi
    if [ "$armed" != "$handoff" ]; then
        cs_write_atomic "$private/pending-handoff" printf '%s\n' "$handoff" || true
    fi
    _switch_failed_notice "$name" "$engine" "$_cs_switched_from" "$handoff"
}

# Where a launch spends the handoff before its CLI starts (the resume path
# below, Codex's r path): what a switch relaunch's settle needs to put it back
# if the CLI never takes it up.
_switch_note_spent() {  # session_dir, handoff, consumer_id
    _cs_switch_spent="$2"
    _cs_switch_spent_by="$3"
    _cs_switch_starts=$(_switch_logged_starts "$1")
}

# How many conversation starts this checkout's session logs hold: Claude's
# SessionStart logs to the private dir, Codex's hook to .cs/local. A count
# that grew while the CLI ran means it reached its conversation.
_switch_logged_starts() {  # session_dir
    local private total more
    total=$(grep -c 'Session started' "$1/.cs/local/session.log" 2>/dev/null) || total=0
    if private=$(cs_private_dir "$1/.cs") && [ "$private" != "$1/.cs/local" ]; then
        more=$(grep -c 'Session started' "$private/session.log" 2>/dev/null) || more=0
        total=$((total + more))
    fi
    printf '%s\n' "$total"
}

# Undoes a launch's spend: the frontmatter says unconsumed again and drops its
# consumed_by line. Only while that line still names the given consumer.
_switch_unspend_handoff() {  # handoff_file, consumer
    [ -n "$2" ] || return 1
    awk -v by="$2" '
        NR == 1 { if ($0 != "---") exit 1; next }
        $0 == "---" { closed = 1; exit }
        $0 == "status: consumed" { spent = 1 }
        $0 == "consumed_by: " by { named = 1 }
        END { exit !(closed && spent && named) }
    ' "$1" 2>/dev/null || return 1
    cs_write_atomic "$1" awk -v by="$2" '
        NR == 1 { front = 1; print; next }
        front && $0 == "---" { front = 0 }
        front && $0 == "status: consumed" { print "status: unconsumed"; next }
        front && $0 == "consumed_by: " by { next }
        { print }
    ' "$1" 2>/dev/null
}

# The "(from another checkout)" label the resume menu shows before r, for a
# --from-handoff that takes the scan's pick instead of the armed handoff: the
# newest unconsumed file can be another checkout's live rotation. The caller
# prints it with %b.
_switch_handoff_origin() {  # handoff_file, session_dir
    [ "$(basename "$1")" != "$(_rotation_marker_basename "$2")" ] || return 0
    _handoff_is_local "$1" "$2" && return 0
    printf ' %s(from another checkout)%s' "${DIM:-}" "${NC:-}"
}

# Called by main once its flags are read. A switch relaunch runs the target's
# open steps before its run, and any of them can end ags through error() (a
# pre-open hook that refuses, a migration, the lock): the handoff is still
# armed then, so an exit trap names the ways back. cs_launch_session saves and
# restores the trap around the run. An encrypted session's pre-open replaces
# it, which is why _switch_settle asks whether the session would reopen before
# it relaunches.
_switch_guard_relaunch() {  # session_name, target_engine
    [ -n "${_cs_switched_from:-}" ] || return 0
    _cs_switch_guard_name="$1"
    _cs_switch_guard_engine="$2"
    _cs_switch_guard_from="$_cs_switched_from"
    trap '_switch_guard_exit $?' EXIT
}

_switch_guard_exit() {  # exit_status
    local handoff
    [ "$1" -ne 0 ] || return 0
    handoff=$(_rotation_armed_handoff "$SESSIONS_ROOT/$_cs_switch_guard_name" 2>/dev/null) || handoff=""
    [ -n "$handoff" ] || return 0
    _switch_failed_notice "$_cs_switch_guard_name" "$_cs_switch_guard_engine" "$_cs_switch_guard_from" "$handoff"
}

# Refusal for --from-handoff with nothing to start from, shared by both
# adapters' launches.
_switch_no_handoff_message() {  # session_name
    printf 'No rotation handoff is pending in %s. Start a fresh conversation with: ags %s --fresh\n' "$1" "$1"
}

# A --resume relaunch: the resumed conversation gets the armed handoff as its
# first message. SessionStart consumes a handoff only on a fresh conversation,
# so the launch spends it here, just before the CLI starts, naming the resumed
# conversation as its consumer; the marker goes too, so a later /clear in that
# conversation cannot rotate into it again. An encrypted session's handoff name
# is its topic and stays out of argv: the message points at consumed_by instead.
# The prompt lands in the caller's variable named by the third argument.
_switch_resume_handoff() {  # session_dir, consumer_id, variable
    local dir="$1" consumer="$2" handoff handoffs private from prompt
    handoff=$(_rotation_armed_handoff "$dir")
    if [ -z "$handoff" ]; then
        printf "${DIM:-}No armed handoff to carry into the resumed conversation; resuming without it.${NC:-}\n"
        return 0
    fi
    handoffs=$(cs_handoff_dir "$dir/.cs") || return 0
    private=$(cs_private_dir "$dir/.cs") || return 0
    _switch_note_spent "$dir" "$handoff" "$consumer"
    _handoff_set_status "$handoffs/$handoff" consumed "$consumer" || true
    rm -f "$private/pending-handoff" 2>/dev/null || true
    from="${_cs_switched_from:-another engine}"
    if [ "$handoffs" = "$dir/.cs/handoffs" ]; then
        prompt="This conversation resumes after the session ran under $from. Read .cs/handoffs/$handoff first: it carries the work done since you last ran here. Then continue from its next step."
    else
        prompt="This conversation resumes after the session ran under $from. Read the handoff in .cs/private/handoffs/ whose frontmatter says consumed_by: $consumer first: it carries the work done since you last ran here. Then continue from its next step."
    fi
    printf "${DIM:-}Continuing from handoff:${NC:-} %s\n" "$handoff"
    printf -v "$3" '%s' "$prompt"
}
