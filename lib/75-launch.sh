# ABOUTME: Claude launch preparation and native invocation under the shared run controller.
# ABOUTME: The final step of opening any session.

# True when a handoff's YAML frontmatter (line 1 "---" through the next "---")
# carries status: unconsumed. Scoped to the frontmatter so a body that quotes
# the contract line flush-left — the rotate skill's own doc does — never counts.
_handoff_is_unconsumed() {  # handoff_file
    awk '
        NR==1 {
            if ($0 != "---") { rc=1; closed=1; exit }
            next
        }
        !closed && $0 == "---" { rc = (matched ? 0 : 1); closed=1; exit }
        !closed && $0 == "status: unconsumed" { matched=1 }
        END { if (!closed) rc=1; exit rc }
    ' "$1" 2>/dev/null
}

# True when the handoff's parent: UUID appears in this checkout's session log,
# meaning this machine ran the conversation that wrote it. The log is
# machine-local by design, so a co-worker's handoff — and this user's own from a
# second machine — both read as absent. This is provenance for the offer to
# show, not a filter: the pick deliberately still offers a handoff from
# elsewhere, because continuing one on another machine is a working flow.
_handoff_is_local() {  # handoff_file, session_dir
    local log parent
    log="$(cs_private_dir "$2/.cs")/session.log" || return 1
    [ -f "$log" ] || return 1
    parent=$(awk '
        NR==1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        /^parent:[[:space:]]*/ {
            sub(/^parent:[[:space:]]*/, "")
            gsub(/[[:space:]\r]+$/, "")
            print; exit
        }
    ' "$1" 2>/dev/null)
    [ -n "$parent" ] || return 1
    # Anchored to the line session-start.sh writes, not a bare substring: the
    # bash-logger appends every command to this same file, so an unanchored
    # match reads a logged `claude --resume <uuid>` as proof this checkout ran
    # that conversation and drops the one warning shown before r.
    grep -Fq "Session started" "$log" 2>/dev/null \
        && grep -E -q "Session started \(.*ID: $parent\)" "$log" 2>/dev/null
}

# The handoff a launch offers: the armed one when the marker names an
# unconsumed handoff, otherwise the lexicographically last unconsumed file (the
# YYYY-MM-DD- prefix makes that the newest date). Prints the path, or nothing.
# Shared by the Claude and Codex launch prompts.
#
# .cs/handoffs/ is shared and nothing ever deletes a handoff, so a file
# belonging to another checkout keeps status: unconsumed indefinitely — the
# rotate skill will not supersede one whose parent is absent from this
# machine's session.log, and correctly so. Sorting last, it would shadow the
# handoff this machine armed and r would rotate into someone else's plan. An
# armed marker is an explicit choice, so it outranks the scan; a marker naming
# a spent or absent file is stale and the scan still answers. The marker names
# a basename, never a path: a separator would resolve outside the handoff store.
_pending_handoff_pick() {  # session_dir
    local session_dir="$1" pending="" hf armed handoffs
    # An encrypted session keeps its handoffs in its vault; a locked one
    # offers nothing (the open has already refused it).
    handoffs=$(cs_handoff_dir "$session_dir/.cs") || return 0
    for hf in "$handoffs"/*.md; do
        [ -f "$hf" ] || continue
        _handoff_is_unconsumed "$hf" || continue
        pending="$hf"
    done
    armed=$(_rotation_marker_basename "$session_dir")
    if [ -n "$armed" ] && [ -f "$handoffs/$armed" ] \
        && _handoff_is_unconsumed "$handoffs/$armed"; then
        pending="$handoffs/$armed"
    fi
    printf '%s' "$pending"
}

# The basename the pending-handoff marker names, or nothing when there is no
# marker or it names something with a path separator.
_rotation_marker_basename() {  # session_dir
    local marker armed=""
    marker="$(cs_private_dir "$1/.cs")/pending-handoff" || return 0
    [ -f "$marker" ] || return 0
    armed=$(tr -d '[:space:]' < "$marker" 2>/dev/null) || armed=""
    case "$armed" in */*|*\\*) armed="" ;; esac
    printf '%s' "$armed"
}

# The handoff an armed marker names while it is still unconsumed. A marker
# naming anything else is stale, and is dropped so a later /clear cannot trip
# over it. hooks/session-start.sh resolves Claude's marker the same way.
_rotation_armed_handoff() {  # session_dir
    local armed handoffs private
    handoffs=$(cs_handoff_dir "$1/.cs") || return 0
    private=$(cs_private_dir "$1/.cs") || return 0
    armed=$(_rotation_marker_basename "$1")
    if [ -n "$armed" ] && [ -f "$handoffs/$armed" ] \
        && _handoff_is_unconsumed "$handoffs/$armed"; then
        printf '%s' "$armed"
        return 0
    fi
    rm -f "$private/pending-handoff" 2>/dev/null || true
}

# Retire a handoff by flipping its frontmatter status. Only the first
# "status: unconsumed" line flips (the frontmatter's); a body quoting the
# contract line flush-left stays intact. A consumed handoff names its consumer.
_handoff_set_status() {  # handoff_file, status, [consumed_by]
    cs_write_atomic "$1" awk -v status="$2" -v by="${3:-}" '
        !flipped && $0 == "status: unconsumed" {
            print "status: " status
            if (by != "") print "consumed_by: " by
            flipped = 1
            next
        }
        { print }
    ' "$1" 2>/dev/null
}

# The last context usage stamped in this session, 0-100, or nothing.
# cs-statusline keys the stamp by SESSION NAME, not by conversation, so it is
# the newest render from any conversation opened here — usually the one being
# resumed, but not when a second conversation (a teammate, or one opened
# outside cs) rendered more recently. The card words it that way rather than
# claiming more than the file knows. Silent on every unusable shape: the stamp
# only exists where the status line is installed, so the readout is a bonus and
# never a reason to fail a launch. 10# because a stamp like 08 is a hard
# arithmetic error read as octal.
# The forcing ships on, so a machine that has never been told gets one notice
# at launch and never again. Marker under the config dir, beside the status
# line's caps answer; an unwritable config dir prints the notice every launch
# rather than aborting the launch, which is the harmless half of the trade.
_rotate_force_notice_file() {
    echo "${CS_CONFIG_DIR:-$HOME/.config/cs}/rotate-force-notice"
}

# Mirrors forceThreshold() in mods/cs/hooks/register.tsx: unset is the
# default, `off` (any case) and zero turn it off, digits move it, and anything
# else is the default rather than silence. KEEP IN SYNC with that resolver.
_rotate_force_threshold() {  # -> prints the percentage, or nothing when off
    local raw="${CS_ROTATE_FORCE_CTX-}"
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$raw" ] && { echo 80; return 0; }
    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
        off) return 0 ;;
    esac
    case "$raw" in
        *[!0-9]*) echo 80; return 0 ;;
        *) [ "$((10#$raw))" -eq 0 ] && return 0; echo "$((10#$raw))" ;;
    esac
}

_rotate_force_notice() {
    local pct f
    # The mod that forces is a function-hooks plugin: without the loader flag
    # (withheld by CS_NO_FUNCTION_HOOKS, or 0 from the shell) nothing rotates,
    # so there is nothing to announce and the marker must stay unspent.
    case "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-}" in ''|0) return 0 ;; esac
    pct="$(_rotate_force_threshold)"
    [ -n "$pct" ] || return 0
    f="$(_rotate_force_notice_file)"
    [ -f "$f" ] && return 0
    printf '%s\n' "ags now rotates a conversation on its own once it ends a turn past ${pct}% context: it writes a handoff, then counts down 20 seconds to the /clear (press 1 to go now, type anything to stop it)."
    printf '%s\n' "To turn that off, export CS_ROTATE_FORCE_CTX=off; to move it, set a percentage. Said once per machine."
    mkdir -p "$(dirname "$f")" 2>/dev/null && { printf '%s\n' "notified" > "$f"; } 2>/dev/null || true
}

_resume_context_pct() {  # session_dir
    local f="$1/.cs/local/context-pct" v=""
    [ -f "$f" ] || return 0
    v=$(tr -d '[:space:]' < "$f" 2>/dev/null || true)
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    # Assignment, not (( )): the latter returns 1 on a zero value, which under
    # set -e would end the launch on a legitimately empty context window.
    v=$((10#$v))
    [ "$v" -le 100 ] || return 0
    printf '%s' "$v"
}

# Drop a rotation marker the user declined to consume. Armed by the rotate
# skill for a /clear, or by an earlier r, it must not outlive the answer: left
# in place it would be consumed by an unrelated /clear hours later, injecting a
# handoff the user already passed on. Announced, because a silent removal turns
# the /clear route into a no-op the user cannot explain.
#
# Pass the handoff that is still pending AFTER this answer, empty when none is.
# Only then does pointing at r hold: an orphaned marker names a spent handoff,
# the r fallthrough is reached precisely because no handoff was offered, and d
# retires the one it had. Offering r in those cases sends the user back for
# something that no longer exists.
_disarm_rotation_marker() {  # session_dir [surviving_handoff]
    local marker
    marker="$(cs_private_dir "$1/.cs")/pending-handoff" || return 0
    [ -f "$marker" ] || return 0
    rm -f "$marker" 2>/dev/null || true
    # An explicit if: `[ ... ] && return 0` as the last command returns 1 when
    # the test fails, which set -e reads as this function failing.
    if [ -z "${2:-}" ]; then
        printf "${DIM}Rotation marker disarmed.${NC}\n"
        return 0
    fi
    printf "${DIM}Rotation marker disarmed; the handoff stays pending — answer r, or re-run the rotate skill.${NC}\n"
}

# A session whose .cs/claude-config exists keeps Claude Code's whole config
# dir there (transcripts, prompt history, .claude.json and its backups), so an
# encrypted session's conversation never lands in ~/.claude. The login stays
# the one the shell would use: CLAUDE_SECURESTORAGE_CONFIG_DIR names the
# keychain entry independently of the config dir, and empty selects the
# default entry. A value inherited from a parent launch into such a session is
# recognisable by its path and dropped, so a session without the link opens
# on the shell's own config.
_export_session_claude_config() {  # session_dir
    local config="$1/.cs/claude-config"
    case "${CLAUDE_CONFIG_DIR:-}" in
        */.cs/claude-config)
            unset CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR
            ;;
    esac
    [ -e "$config" ] || return 0
    _link_shared_claude_config "$config" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    # Claude Code keeps .claude.json beside the config dir by default, inside it
    # when CLAUDE_CONFIG_DIR is set.
    _seed_session_claude_json "$config" "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    export CLAUDE_SECURESTORAGE_CONFIG_DIR="${CLAUDE_SECURESTORAGE_CONFIG_DIR-${CLAUDE_CONFIG_DIR-}}"
    export CLAUDE_CONFIG_DIR="$config"
}

# The session's config dir shares the shell's settings, instructions and
# extensions by symlink, so hooks, skills and plugins behave as they do
# anywhere else. Only these names are shared: everything else Claude Code
# writes (projects/, history.jsonl, backups/, todos/) is born in the session's
# config dir and stays behind the vault. An entry already there is the
# session's own and is left alone.
_link_shared_claude_config() {  # session_config_dir, shell_config_dir
    local name
    for name in settings.json settings.local.json CLAUDE.md AGENTS.md rules skills \
        commands agents hooks plugins output-styles keybindings.json vale; do
        [ -e "$2/$name" ] || continue
        [ -e "$1/$name" ] || [ -L "$1/$name" ] && continue
        ln -s "$2/$name" "$1/$name" || error "could not link $1/$name to $2/$name."
    done
}

# The session's .claude.json starts once as a copy of the shell's, so the
# login's onboarding and preferences carry over, with every project's record
# dropped: each keeps that project's last prompt in plaintext. From then on it
# is the session's own. jq exits 0 on an empty file and prints nothing, so -e
# is what turns an empty or unreadable source into a refusal.
_seed_session_claude_json() {  # session_config_dir, shell_claude_json
    local dest="$1/.claude.json" tmp
    [ -e "$dest" ] || [ -L "$dest" ] && return 0
    [ -e "$2" ] || return 0
    tmp=$(mktemp "$1/.claude.json.XXXXXX") || error "could not create a temporary file in $1."
    if ! jq -e '.projects = {}' "$2" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        error "$2 is not a JSON object ags can copy into $1; fix it, then reopen."
    fi
    mv "$tmp" "$dest" || { rm -f "$tmp"; error "could not write $dest."; }
}

# One row of the pending-handoff answers: the key, a padded label, and a dim
# consequence column, in the already-open menu's layout.
_resume_menu_row() {  # key color label consequence
    printf '    %b%b%s%b  %b%-16s%b%b%s%b\n' \
        "$BOLD" "$2" "$1" "$NC" "$WHITE" "$3" "$NC" "$DIM" "$4" "$NC"
}

_cs_claude_adapter_dependencies() {
    # Preserve the existing binary-plus-arguments override.
    local claude_bin="${CLAUDE_CODE_BIN%% *}"
    command -v "$claude_bin" >/dev/null 2>&1 || printf '%s\n' claude-code
    return 0
}

_cs_claude_adapter_capabilities() {
    # These describe this integration, not every feature a runtime may offer.
    # rotation: handoff marker consumed by SessionStart, /clear rebinds.
    # spawn_brief: a spawned session's first turn reads .cs/brief.md.
    # memory_index: .cs/memory/MEMORY.md loads at every session start.
    # mail_delivery: hooks surface `ags -msg` mail inside the conversation.
    printf '%s\n' launch exact_resume startup_context feature_finish \
        rotation spawn_brief memory_index mail_delivery
}

_claude_native_id_valid() {  # native conversation ID
    [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

_cs_claude_adapter_launch() {
    _launch_claude_bound "$@"
}

launch_claude_code() {
    cs_launch_session claude "$@"
}

_launch_claude_bound() {
    # Claude Code downgrades its branding (logo, "thinking" animation) and statusline
    # truecolor to a muted palette when it detects tmux, regardless of actual color
    # support (anthropics/claude-code#35148). cs owns the environment before it execs
    # claude, so it restores the documented override here for every launch path,
    # unless the user has already set the variable themselves. (`if`, not `[ ] &&`,
    # so the false branch does not trip `set -e` at top level.)
    if [ -z "${CLAUDE_CODE_TMUX_TRUECOLOR+x}" ]; then
        export CLAUDE_CODE_TMUX_TRUECOLOR=1
    fi

    local session_name="$1"
    local session_dir="$2"
    local is_new="$3"
    local force="${4:-}"
    local merge_feature="${5:-}"
    local intent="${6:-auto}"

    # Terminal theme (and its real background RGB when known) for the statusline
    # and hooks, detected while cs still owns the tty and reused by the session
    # launched next.
    _export_term_theme
    # Refresh the palette now that the theme is known so everything below —
    # the collision menu and the launch banner — reads on a light canvas
    # (colors were first set at startup, defaulting to dark).
    setup_palette

    # The core acquired the lease and exported this run's session context.
    # A force selected in its collision menu also bypasses native duplicates.
    [ "${CS_COLLISION_FORCE:-}" = "1" ] && force="true"

    # Read the session's recorded UUID (allocated by create_session_structure
    # on new sessions or bound by migrate_session Phase 8 to a transcript on
    # disk). Used for both the CS_CLAUDE_SESSION_ID env export below and for
    # the spawn args at exec time. Empty on an existing session that has never
    # had a conversation, such as the first open after cs -adopt; the launch
    # below starts one and records it. Both recorded values reach claude's
    # argv, so each is checked here: a value that is not a UUID names no
    # conversation and counts as empty, a colour claude would reject passes no
    # colour. Neither is dropped without a line saying so.
    local claude_session_id claude_session_color
    claude_session_id=$(cs_binding_read "$session_dir" claude) || return 1
    if [ -n "$claude_session_id" ] && ! _claude_native_id_valid "$claude_session_id"; then
        # An explicit --resume names this binding, and nothing can stand in
        # for it. Any other open treats it as no conversation.
        if [ "$intent" = resume ]; then
            printf 'Error: Invalid Claude conversation binding in %s/.cs/local/state; repair it before launching.\n' "$session_dir" >&2
            return 1
        fi
        warn "ignoring claude_session_id in .cs/local/state: not a UUID, so it names no conversation"
        # Dropped from state too: SessionStart commits the staged conversation
        # only over the predecessor it names, and that is none.
        _unset_local_state "$session_dir/.cs/local/state" claude_session_id
        claude_session_id=""
    fi
    # No recorded conversation does not mean no conversation: a feature
    # worktree's open runs no migrate_session, so Phase 8 never looked, and a
    # dropped non-UUID leaves the slot empty with the transcript still on disk.
    # Look once at the folder's transcripts before calling the session unbound,
    # so a real conversation is offered rather than abandoned.
    if [ -z "$claude_session_id" ] && [ "$is_new" = "false" ]; then
        local _found
        _found=$(_discover_session_uuid_in "$(_claude_project_dir "$session_dir")")
        if _is_uuid "$_found"; then
            _set_local_state "$session_dir/.cs/local/state" claude_session_id "$_found"
            warn "Bound claude_session_id in .cs/local/state to $_found"
            claude_session_id="$_found"
        fi
    fi
    claude_session_color=$(_read_local_state "$session_dir/.cs/local/state" claude_session_color)
    if [ -n "$claude_session_color" ] && ! _is_session_color "$claude_session_color"; then
        warn "ignoring claude_session_color in .cs/local/state: not one of claude's colours"
        claude_session_color=""
    fi

    # Build the trailing positional prompt arg that applies the session's
    # color at launch. Claude has no --color CLI flag (verified through
    # 2.1.162); the slash command as a positional prompt is the only
    # mechanism. Slash commands at launch produce no transcript entry —
    # confirmed by grep against this session's own jsonl after a /color
    # invocation — so re-applying every launch is free.
    local color_arg=""
    [ -n "$claude_session_color" ] && color_arg="/color $claude_session_color"

    # Live-duplicate guard: refuse to spawn a second claude process for the
    # same session UUID. Mostly catches "I opened this in two tabs" accidents.
    # --force overrides. Tests stub `ps` via CS_PS_BIN to inject canned output;
    # production runs the real `ps`. Best-effort — ps failures fall through.
    #
    # The match uses a bash builtin (`[[ ... == *needle* ]]`) rather than
    # piping ps to grep, to avoid the classic grep-finds-itself bug: with
    # `ps -Ao args= | grep -F -- "$UUID"`, grep's own argv contains the
    # UUID and ps sees it, producing a false-positive self-match. The
    # builtin substring test runs entirely in-process and never exposes
    # the UUID as a subprocess argv.
    #
    # Skip when is_new=true: the UUID was just allocated by
    # create_session_structure milliseconds ago, so no other process can
    # be holding it. Spares the ps fork on fresh-spawn. An unbound session
    # has no UUID to match, so only the --name half runs for it.
    if [ "$force" != "true" ] && [ "$is_new" != "true" ]; then
        local _ps_out
        _ps_out=$("${CS_PS_BIN:-ps}" -Ao args= 2>/dev/null || true)
        # An in-app /clear rebinds the recorded UUID while the live process's
        # argv still names its launch UUID, so the UUID test alone goes blind.
        # --name is stable for the process's whole life. The trailing delimiter
        # keeps a name that prefixes another (sym vs sym-comfy-nodes) from
        # matching; the appended newline covers --name being the final argument.
        # The UUID counts only after a flag claude takes it with (--session-id
        # at launch, --resume or -r on a continue, --parent-session-id on a
        # teammate that outlived its lead and still writes to .cs/local/): a
        # Bash-tool child carries the same UUID in the shell snapshot it is
        # started from, and one left running in the background outlives the
        # conversation as an orphan. Each flag in both spellings, with a space
        # or with `=`.
        _ps_out="$_ps_out"$'\n'
        local _flag _hit=""
        if [ -n "$claude_session_id" ]; then
            for _flag in "--session-id " "--session-id=" "--resume " "--resume=" " -r " "--parent-session-id " "--parent-session-id="; do
                if [[ "$_ps_out" == *"$_flag$claude_session_id "* ]] \
                    || [[ "$_ps_out" == *"$_flag$claude_session_id"$'\n'* ]]; then
                    _hit=1; break
                fi
            done
        fi
        if [ -n "$_hit" ] \
            || [[ "$_ps_out" == *"--name $session_name "* ]] \
            || [[ "$_ps_out" == *"--name $session_name"$'\n'* ]]; then
            error "Session $session_name is already running elsewhere${claude_session_id:+ (UUID $claude_session_id)}. Use --force to override."
        fi
    fi

    # Set environment variables
    cs_export_session_context "$session_name" "$session_dir"
    # A pane claude opens itself (an agent-team teammate) is started by the
    # tmux server, which hands it the server's session environment, not the
    # lead's: the truecolor override cs exported for claude never reaches it,
    # so the teammate's status line renders in the muted 256-colour fallback.
    # Publish the value into the tmux session this launch runs in, so panes
    # split from it inherit it. Best-effort: a pane cs did not launch is the
    # documented fallback, not a failure.
    if [ -n "${TMUX:-}" ]; then
        _tmux set-environment CLAUDE_CODE_TMUX_TRUECOLOR "$CLAUDE_CODE_TMUX_TRUECOLOR" 2>/dev/null || true
    fi
    _iterm_tab_through_tmux
    # An adopted session's name lives only in the symlink pointing here, which a
    # hook walking up from the directory never sees. Record it on open, so
    # sessions adopted before cs wrote the key get it too. Only for those: an
    # ordinary session IS its directory, and a recorded name there would go
    # stale the moment the directory was renamed — outranking a basename that
    # is still right.
    if [ -L "$SESSIONS_ROOT/$session_name" ]; then
        cs_run_with_lease "$session_dir/.cs" _cs_set_local_state_unlocked "$session_dir/.cs/local/state" session_name "$session_name" || return 1
    fi
    # Prompt rewriting rides Claude Code's external-editor round-trip: ctrl+g
    # writes the composer buffer to a temp file, runs $EDITOR on it, and replaces
    # the composer with whatever comes back. Capture the real editor first so the
    # shim can hand it every file that is NOT a composer buffer.
    if [ "${CS_REWRITE_DISABLE:-}" != "1" ] && [ -x "$HOOKS_DEPLOY_DIR/prompt-rewriter.sh" ]; then
        export CS_REAL_EDITOR="${CS_REAL_EDITOR:-${VISUAL:-${EDITOR:-vi}}}"
        export EDITOR="$HOOKS_DEPLOY_DIR/prompt-rewriter.sh"
        export VISUAL="$EDITOR"
    fi
    # A feature worktree keeps its own task list, keyed like its conversation
    # to the full `base@task` name: the base's list is the base's work, and a
    # feature opening on it would show and edit tasks that are not its own.
    # Secrets still key to the base (cs_base, worktree local state only).
    local cs_base
    cs_base=$(_read_local_state "$session_dir/.cs/local/state" cs_base)
    export CLAUDE_CODE_TASK_LIST_ID="$session_name"
    # Claude Code 2.1.233+ withholds the Task tools on Opus 4.8, Sonnet 5 and
    # Fable 5 unless the session opts in. The rotation wake, the walk-away
    # drain and the rotate skill all address the native task list, so a cs
    # launch opts in; CS_NO_TASK_TOOLS=1 hands the choice back to Claude Code.
    if [ -z "${CS_NO_TASK_TOOLS:-}" ]; then
        export CLAUDE_CODE_ENABLE_TODO_TOOLS=1
    fi
    # Claude Code loads function-hooks plugins only behind this early-access
    # flag, and the rotate mod the installer deploys is one. A cs launch turns
    # them on for the session, keeping a value the shell already set (0 keeps
    # them off). CS_NO_FUNCTION_HOOKS=1 leaves the session without the flag
    # even when the shell carried one, as a nested launch inherits it.
    if [ -n "${CS_NO_FUNCTION_HOOKS:-}" ]; then
        unset CLAUDE_CODE_ENABLE_FUNCTION_HOOKS
    else
        export CLAUDE_CODE_ENABLE_FUNCTION_HOOKS="${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-1}"
    fi
    if [ -n "$cs_base" ]; then
        export CS_SECRETS_SESSION="$cs_base"
    fi
    # Export both names defensively: Claude Code's auto-memory resolver reads
    # CLAUDE_COWORK_MEMORY_PATH_OVERRIDE; the older CLAUDE_CODE_AUTO_MEMORY_PATH
    # is kept in case other Claude Code versions honor it instead.
    local memory_path="$session_dir/.cs/memory"
    export CLAUDE_CODE_AUTO_MEMORY_PATH="$memory_path"
    export CLAUDE_COWORK_MEMORY_PATH_OVERRIDE="$memory_path"
    _export_session_claude_config "$session_dir"
    # Expose the recorded session UUID to hooks. Hooks can use this to
    # reverse-look-up which cs session they're firing inside without having
    # to depend on $CLAUDE_CODE_SESSION_ID (set by Claude Code itself, but
    # only in-session) or walk the filesystem.
    if [ -n "$claude_session_id" ]; then
        export CS_CLAUDE_SESSION_ID="$claude_session_id"
    fi
    # Hooks identify the lead by the supervised native process's direct
    # parent and this run's lease; descendants cannot inherit ownership.
    export CS_LEAD_PID=$$

    # Where this cs is, for the mods: `$.process.run` takes no shell and the
    # claude process's PATH is not this shell's. Set on every launch, so a
    # value inherited from a parent launch is always replaced by this one's.
    local self_bin
    self_bin="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
    export CS_BIN="$self_bin"
    export AGS_BIN="$self_bin"

    # The cs-update mod draws the pending release's notes and runs the update
    # from inside the session. It gets the launch's verdict, never its own:
    # the version check_update_notify found newer than this cs. Absent when
    # nothing is pending, so the mod is silent by absence rather than by a
    # value it has to read; cleared first, since a nested launch inherits its
    # parent's verdict.
    unset CS_UPDATE_AVAILABLE
    if [ -n "$UPDATE_AVAILABLE" ]; then
        export CS_UPDATE_AVAILABLE="$UPDATE_AVAILABLE"
    fi

    # Spawn seed: tasks and a brief staged by ags -spawn for this session.
    # Consumed here, after the already-running guard and before any exec arm,
    # so a window that died before launching self-heals on the session's next
    # open. A stale seed (>1h) is set aside with its brief, never silently
    # armed days later.
    local spawn_kick=""
    local _seed="$SESSIONS_ROOT/.spawn/$session_name.seed"
    local _brief="$SESSIONS_ROOT/.spawn/$session_name.brief.md"
    if [ -f "$_seed" ]; then
        local _now _age
        _now=$(date +%s)
        _age=$(( _now - $(_epoch_mtime "$_seed") ))
        if [ "$_age" -gt 3600 ]; then
            mv "$_seed" "$_seed.stale" 2>/dev/null || true
            [ ! -f "$_brief" ] || mv "$_brief" "$_brief.stale" 2>/dev/null || true
            warn "Stale spawn seed set aside: $_seed.stale (re-run ags -spawn if still wanted)"
        else
            local _spawner="" _line _n=0 _first=1 _has_brief=0
            # The brief moves in before any task is queued, and a move that
            # fails stops the launch with the seed and brief still staged, so
            # the next open retries. Consuming the seed regardless would start
            # the session without the brief it was opened for, and leave the
            # brief to attach to a later spawn of the same name. errexit does
            # not see a failed left operand, so the abort is explicit.
            if [ -f "$_brief" ]; then
                # A directory in the brief's place would take the file INSIDE
                # it and the move would report success.
                [ ! -d "$session_dir/.cs/brief.md" ] \
                    || error "Spawn brief could not be delivered: $session_dir/.cs/brief.md is a directory (seed kept; remove it and re-open the session to retry)"
                mv "$_brief" "$session_dir/.cs/brief.md" \
                    || error "Spawn brief could not be delivered to $session_dir/.cs/brief.md (seed kept; re-open the session to retry)"
                _has_brief=1
            fi
            while IFS= read -r _line || [ -n "$_line" ]; do
                if [ "$_first" = 1 ]; then _spawner="$_line"; _first=0; continue; fi
                # Skip whitespace-only lines, not merely empty ones: _queue_add
                # trims and then errors on an empty body, which under errexit
                # would abort the whole session launch over a stray space in a
                # hand-edited seed.
                case "$_line" in *[![:space:]]*) : ;; *) continue ;; esac
                _queue_add "$session_dir/.cs/local" "$_line"
                _n=$((_n + 1))
            done < "$_seed"
            [ "$_n" -eq 0 ] || _queue_set_state "$session_dir/.cs/local" armed
            if [ "$_n" -gt 0 ] || [ "$_has_brief" = 1 ]; then
                local _work=""
                [ "$_has_brief" = 1 ] && _work="Your brief is .cs/brief.md: read it first."
                if [ "$_n" -gt 0 ]; then
                    _work="${_work:+$_work }Your walk-away queue is armed with $_n task(s); begin."
                else
                    _work="$_work Then begin."
                fi
                if [ -n "$_spawner" ]; then
                    printf '%s\n' "$_spawner" > "$session_dir/.cs/local/spawned-by"
                    spawn_kick="Spawned by $_spawner. $_work Send results with: ags -msg $_spawner -k result \"...\""
                else
                    spawn_kick="$_work"
                fi
            fi
            rm -f "$_seed"
        fi
    fi
    # Arming the ritual is an explicit action the user took seconds ago, so it
    # outranks a spawn seed staged earlier. The queue is already armed by this
    # point, so nothing is lost — but the drain is the Stop hook, which fires
    # at the first turn end, so do not promise it runs after the merge.
    local merge_kick=""
    [ -n "$merge_feature" ] && merge_kick="/finish $merge_feature"
    if [ -n "$merge_kick" ] && [ -n "$spawn_kick" ]; then
        warn "A walk-away queue is armed here; it will begin at the first turn end."
    fi
    # The kick prompt takes claude's single positional-prompt slot, displacing
    # the /color re-apply for this one launch (color returns next open).
    local launch_prompt="${merge_kick:-${spawn_kick:-$color_arg}}"

    # Status indicator. An engine's first conversation in an existing
    # workspace (no binding yet) and an explicit --fresh both start a new
    # conversation; labelling them "resuming" also put the previous
    # conversation's context figure on the card.
    local status_icon status_text
    if [ "$is_new" = "true" ] || [ -z "$claude_session_id" ]; then
        status_icon="+"
        status_text="new"
    elif [ "$intent" = fresh ]; then
        status_icon="+"
        status_text="fresh"
    else
        status_icon="↻"
        status_text="resuming"
    fi

    # Count secrets for this session
    local secret_count=0
    local secrets_bin
    if secrets_bin=$(find_secrets_script); then
        secret_count=$("$secrets_bin" list 2>/dev/null | grep -c "^  - " 2>/dev/null) || secret_count=0
        # Ensure it's a valid integer
        [[ "$secret_count" =~ ^[0-9]+$ ]] || secret_count=0
    fi

    # Display banner with gradient bar (rust → amber)
    # Gradient colors for left bar
    local BAR1='\033[38;2;230;74;25m▌'    # rust #e64a19
    local BAR2='\033[38;2;245;124;0m▌'    # dark orange #f57c00
    local BAR3='\033[38;2;255;152;0m▌'    # orange #ff9800
    local BAR4='\033[38;2;255;179;0m▌'    # amber #ffb300

    # One bar per row, and the card can reach five: version, session, path,
    # secrets-and-context, update. The last colour repeats rather than the index
    # running off the end — under `set -u` that is an unbound-variable abort of
    # the whole launch, not a missing bar.
    local BAR5='\033[38;2;255;193;7m▌'    # amber-light #ffc107
    local BAR6='\033[38;2;255;202;40m▌'   # amber-lighter #ffca28
    local bar_idx=0
    local bars=("$BAR1" "$BAR2" "$BAR3" "$BAR4" "$BAR5" "$BAR6")

    echo ""
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${ORANGE}ags${NC} ${GREEN}$VERSION${NC}"; ((++bar_idx))
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${WHITE}${BOLD}$session_name${NC} ${COMMENT}($status_icon $status_text)${NC} ${DIM}${ICON_HOST} $(hostname -s)${NC}"; ((++bar_idx))
    echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${GOLD}$session_dir${NC}"; ((++bar_idx))
    # Secrets and context are one short fact each, so they share a row rather
    # than costing the card two. Built as segments and emitted once: either can
    # be absent (no secrets stored; a new session, which has no conversation for
    # a context figure to describe), and the row appears whenever at least one
    # is present.
    local _seg_secrets="" _seg_ctx=""
    if [ "$secret_count" -gt 0 ]; then
        local secret_word="secret"
        [ "$secret_count" -gt 1 ] && secret_word="secrets"
        _seg_secrets="${COMMENT}${ICON_LOCK}${NC} ${YELLOW}$secret_count${NC} ${COMMENT}$secret_word${NC}"
    fi
    if [ "$status_text" = "resuming" ]; then
        local _card_ctx=""
        _card_ctx=$(_resume_context_pct "$session_dir")
        if [ -n "$_card_ctx" ]; then
            _seg_ctx="${COMMENT}${ICON_CTX}${NC} ${YELLOW}${_card_ctx}%${NC} ${COMMENT}context used${NC}"
        fi
    fi
    if [ -n "$_seg_secrets" ] || [ -n "$_seg_ctx" ]; then
        local _row="$_seg_secrets"
        # Literal glyph, not an escape: /bin/bash 3.2 (the floor) prints
        # `\u00b7` from echo -e as six characters, and every other middle dot
        # in cs is a literal for the same reason.
        if [ -n "$_seg_secrets" ] && [ -n "$_seg_ctx" ]; then
            _row="${_row}  ${DIM}·${NC}  ${_seg_ctx}"
        else
            _row="${_row}${_seg_ctx}"
        fi
        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${_row}"; ((++bar_idx))
    fi

    if [ -n "$UPDATE_AVAILABLE" ]; then
        # The update block continues the card's bar stack rather than starting
        # its own column: same bar, same one-space gutter, so it reads as the
        # last fact about this session and not as a separate widget.
        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${BOLD}${YELLOW}${ICON_UP}${NC} ${BOLD}${GREEN}$UPDATE_AVAILABLE${NC} ${BOLD}${COMMENT}available${NC} ${BOLD}${DIM}(you have $VERSION — run${NC} ${BOLD}${GOLD}ags -update${NC}${BOLD}${DIM})${NC}"; ((++bar_idx))
        local notes_cache="${CS_CACHE_DIR:-$HOME/.cache/cs}/update-notes-$UPDATE_AVAILABLE"
        # The cs-update mod draws these same notes in full inside the session
        # once function hooks are on, so printing them here too would be a
        # second copy of the same list. This card is the fallback for when
        # the mod is withheld: mirrors the export above (CS_NO_FUNCTION_HOOKS
        # set, or the flag pinned to 0) — it runs after that block, so the
        # exported value already carries both cases. KEEP IN SYNC with
        # _rotate_force_notice's identical check.
        local _mod_withheld=""
        case "${CLAUDE_CODE_ENABLE_FUNCTION_HOOKS:-}" in ''|0) _mod_withheld=1 ;; esac
        if [ -n "$_mod_withheld" ] && [ -s "$notes_cache" ]; then
            local card_w nver nsum indent wrap_w line first
            card_w=$(tput cols 2>/dev/null) || card_w=80
            case "$card_w" in ''|*[!0-9]*) card_w=80 ;; esac
            # "▌ " + the note's own 3-space indent, and a right margin so the
            # text never touches the edge. Wrapped on word boundaries with
            # `fold -s` instead of cut mid-word: a summary that stops at "that
            # re" reads as a rendering bug, and the cache holds full sentences.
            indent="     "
            wrap_w=$((card_w - ${#indent} - 2))
            [ "$wrap_w" -ge 24 ] || wrap_w=24
            # A bare bar between the "available" line and the notes: they are a
            # different kind of thing (what changed, versus what to run), and
            # run together they read as one wrapped paragraph.
            echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC}"
            while IFS=$'\t' read -r nver nsum; do
                [ -n "$nsum" ] || continue
                first=1
                # Continuation lines align under the summary, not under the
                # version, so a wrapped note reads as one paragraph.
                while IFS= read -r line; do
                    if [ -n "$first" ] && [ "$nver" != "+" ]; then
                        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${DIM}  ${NC}${GREEN}${nver}${NC} ${COMMENT}${line}${NC}"
                        first=""
                    else
                        echo -e "${bars[$((bar_idx < ${#bars[@]} ? bar_idx : ${#bars[@]} - 1))]}${NC} ${indent}${COMMENT}${line}${NC}"
                    fi
                done <<EOF
$(printf '%s\n' "$nsum" | fold -s -w "$wrap_w")
EOF
            done < "$notes_cache"
            ((++bar_idx))
        fi
    fi
    # One notice per machine that the forcing is on, after the card so it reads
    # as news about cs rather than a fact about this session.
    _rotate_force_notice

    echo ""

    # Set terminal tab title and color. The tab color is the session's
    # claude_session_color (same RGB as the statusline block); fall back to a
    # name hash only if no color is recorded.
    local _tab_color
    _tab_color=$(_session_color_rgb "$claude_session_color")
    set_tab_title "ags: $session_name" "${_tab_color:-auto:$session_name}" "$session_name"

    cd "$session_dir" || return 1

    # A new session with no recorded conversation stages its first identity
    # without asking. An existing one without a conversation is the resume
    # question's: it offers a pending handoff before starting fresh.
    if [ -z "$claude_session_id" ] && [ "$is_new" = "true" ]; then
        _exec_fresh_rebind "$session_dir" fresh "" "$spawn_kick" "$merge_kick"
        return $?
    fi

    # For existing sessions, ask if user wants to continue previous conversation.
    # The answer sets the id to resume; it goes to claude as one quoted argument.
    # An existing session with no recorded conversation has nothing to resume:
    # an engine's first open in an existing workspace, the first open after
    # ags -adopt, or records whose machine-local state did not travel. It takes
    # the fresh answer without asking, unless a rotation handoff is pending:
    # that is the user's call, so the offer is made with the rows that apply.
    # An explicit --fresh asks nothing.
    local resume_id=""
    if [ "$is_new" = "false" ] && [ "$intent" != fresh ]; then
        # cs records only the conversation it launched, so one started any other
        # way on this folder — a `/desktop` handoff, a claude opened on the
        # directory — leaves the recorded uuid naming an older conversation.
        # That uuid still resolves, so `--resume` can succeed: the launch would continue a superseded
        # prefix with nothing said. Name the newer one rather than switching to
        # it, which would hand the session to whatever was last opened here.
        if [ -n "$claude_session_id" ]; then
            local _proj _newest
            _proj=$(_claude_project_dir "$session_dir")
            # Suggest a newer conversation only when the recorded transcript
            # exists. Missing transcripts never authorize replacing a binding,
            # and reporting the repair target as a rival would be nonsense.
            if [ -f "$_proj/$claude_session_id.jsonl" ]; then
                _newest=$(_discover_session_uuid_in "$_proj")
                # "Newer" is a claim about the clock, so check it rather than
                # infer it from "discovery returned something else". Discovery
                # skips teammates and headless runs, so when the recorded slot
                # is itself a teammate's — the state this gate exists to stop — what comes
                # back is genuinely OLDER, and announcing it as newer would be
                # a lie built on a correct skip.
                if [ -n "$_newest" ] && [ "$_newest" != "$claude_session_id" ] \
                    && [ "$_proj/$_newest.jsonl" -nt "$_proj/$claude_session_id.jsonl" ]; then
                    printf "${DIM}A newer conversation was opened here outside cs:${NC} %s\n" "$_newest"
                    printf "${DIM}Resuming the recorded one instead. To continue the newer:${NC} claude --resume %s\n" "$_newest"
                fi
            fi
        fi

        # Deliberate rotation: an unconsumed handoff written by the rotate
        # skill adds a third answer (_pending_handoff_pick says which). An
        # encrypted session keeps its handoffs and the marker in its vault;
        # the open has already refused a locked one.
        local pending_handoff _marker_dir
        _marker_dir=$(cs_private_dir "$session_dir/.cs") && cs_handoff_dir "$session_dir/.cs" >/dev/null \
            || error "$session_name: .cs/private dangles after the open checked it (vault unmounted mid-launch?). Mount it, then reopen."
        pending_handoff=$(_pending_handoff_pick "$session_dir")
        # A spawned launch is unattended: take the default (resume) instead
        # of parking the tmux window on an interactive ask. So is an explicit
        # --resume, and an open with no terminal to ask on. Unbound, the
        # default is fresh, and a pending handoff waits for an attended open.
        if [ "$intent" = resume ] || [ -n "$spawn_kick" ] || ! cs_interactive; then
            response=""
            [ -n "$claude_session_id" ] || response="n"
        elif [ -z "$claude_session_id" ] && [ -z "$pending_handoff" ]; then
            response="n"
        else
            if [ -n "$pending_handoff" ]; then
                # Answering blind is the hazard this label exists for: r arms
                # the marker with this basename, and the next SessionStart flips
                # that file to consumed under this machine's UUID — on a
                # colleague's live rotation, that is their artifact being taken.
                local _origin=""
                _handoff_is_local "$pending_handoff" "$session_dir" \
                    || _origin=" ${DIM}(from another checkout)${NC}"
                printf "${DIM}Rotation handoff pending:${NC} %s%b\n" "$(basename "$pending_handoff")" "$_origin"
                # One answer per row, key first, laid out like the already-open
                # menu; the keys stay the letters the one-line ask used.
                echo
                if [ -n "$claude_session_id" ]; then
                    _resume_menu_row y "$GREEN" 'resume' 'continue the previous conversation · default'
                    _resume_menu_row r "$GOLD" 'from handoff' 'fresh conversation that picks up the handoff'
                    _resume_menu_row n "$COMMENT" 'fresh' 'fresh conversation; the handoff waits for later'
                    _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then resume'
                else
                    _resume_menu_row r "$GOLD" 'from handoff' 'fresh conversation that picks up the handoff'
                    _resume_menu_row n "$COMMENT" 'fresh' 'fresh conversation; the handoff waits for later · default'
                    _resume_menu_row d "$ORANGE" 'discard' 'retire the handoff, then start fresh'
                fi
                echo
                printf '    %b›%b ' "$GOLD" "$NC"
            else
                printf "${DIM}Continue previous conversation?${NC} [Y/n] "
            fi
            # Single keypress, no Enter needed (mirrors the collision menu).
            # ESC or EOF (piped close) cancels the launch; Enter takes the
            # default (resume) via the case's *) arm below.
            IFS= read -rsn1 response || { echo; exit 130; }
            echo
            case "$response" in $'\e') exit 130 ;; esac
        fi
        case "$response" in
            [nN]|[nN][oO])
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                resume_id=""
                ;;
            [rR])
                if [ -n "$pending_handoff" ]; then
                    mkdir -p "$_marker_dir"
                    printf '%s\n' "$(basename "$pending_handoff")" > "$_marker_dir/pending-handoff"
                    echo ""
                    # r is the user explicitly choosing the rotation handoff
                    # over resuming; a merge armed moments earlier must not
                    # silently override the choice they just made.
                    if [ -n "$merge_kick" ]; then
                        warn "Rotation handoff takes this launch; re-run: ags $session_name -finish $merge_feature"
                    fi
                    _exec_fresh_rebind "$session_dir" handoff "$(basename "$pending_handoff")" "$spawn_kick" ""
                    return $?
                fi
                # r without a pending handoff was never offered: treat as the
                # default resume answer, disarm included.
                _disarm_rotation_marker "$session_dir"
                resume_id="$claude_session_id"
                ;;
            [dD])
                # Nothing survives d: it retires the handoff it was offered, and
                # an orphaned marker had none to begin with.
                _disarm_rotation_marker "$session_dir"
                if [ -n "$pending_handoff" ]; then
                    _handoff_set_status "$pending_handoff" discarded || true
                    printf "${DIM}Handoff discarded:${NC} %s\n" "$(basename "$pending_handoff")"
                fi
                # d without a pending handoff was never offered: treat as the
                # default resume answer.
                resume_id="$claude_session_id"
                ;;
            *)
                # Also the unattended spawn path, which takes this default
                # without asking.
                _disarm_rotation_marker "$session_dir" "$pending_handoff"
                # --resume <uuid>, never --continue: the uuid names the exact
                # conversation, while --continue means "most recent" and may
                # resolve to a sibling Claude session the user ran in a
                # different terminal between cs launches. Empty on an unbound
                # session, which the fresh path below starts.
                resume_id="$claude_session_id"
                ;;
        esac
        echo ""
    fi

    if [ -n "$resume_id" ]; then
        # Resume errors keep the exact binding. Creating a replacement is
        # an explicit --fresh choice, independent of how quickly native exit occurs.
        local rc=0
        # shellcheck disable=SC2086
        cs_run_child $CLAUDE_CODE_BIN --name "$session_name" --resume "$resume_id" ${launch_prompt:+"$launch_prompt"} || rc=$?
        if [ "$rc" -ne 0 ]; then
            printf 'Could not resume the recorded Claude conversation; binding preserved. Retry or run: ags %s --engine claude --fresh\n' "$session_name" >&2
        fi
        return "$rc"
    else
        # Fresh-spawn path. Three sub-cases:
        #   - is_new=true: pass --session-id <pre-allocated-uuid> so claude
        #     adopts the UUID create_session_structure wrote into README.
        #   - is_new=false (an explicit --fresh, the user said n, or the session
        #     has no recorded conversation): stage a fresh UUID and pass it to
        #     native startup. SessionStart acknowledges and commits it.
        #   - is_new=true with no claude_session_id (create_session_structure
        #     always writes one; handled defensively): naked exec.
        if [ "$is_new" = "true" ] && [ -n "$claude_session_id" ]; then
            # shellcheck disable=SC2086
            cs_run_child $CLAUDE_CODE_BIN --name "$session_name" --session-id "$claude_session_id" ${launch_prompt:+"$launch_prompt"}
        elif [ "$is_new" = "false" ]; then
            _disarm_rotation_marker "$session_dir"
            # An explicit --fresh never asked anything, so it is not a decline.
            local _rebind_reason=declined-resume
            [ "$intent" = fresh ] && _rebind_reason=fresh
            [ -n "$claude_session_id" ] || _rebind_reason=fresh
            _exec_fresh_rebind "$session_dir" "$_rebind_reason" "" "$spawn_kick" "$merge_kick"
        else
            # shellcheck disable=SC2086
            cs_run_child $CLAUDE_CODE_BIN --name "$session_name" ${launch_prompt:+"$launch_prompt"}
        fi
    fi
}

# Follow a chain of symlinks to the file at its end, portably (BSD readlink
# has no -f before macOS 12.3). Prints the final path.
_resolve_symlink_file() {  # path
    local path="$1" target
    while [ -L "$path" ]; do
        target=$(readlink "$path") || break
        case "$target" in
            /*) path="$target" ;;
            *)  path="$(dirname "$path")/$target" ;;
        esac
    done
    printf '%s\n' "$path"
}

# Give a claude launched inside tmux under iTerm2 the tab it gets when iTerm2
# runs it directly: the progress loader along the top of the tab and the
# Claude icon beside its title. Neither reaches the tab on its own through tmux.
#
# Loader: Claude Code sends its progress escape (OSC 9;4, wrapped for tmux
# passthrough) only when TERM_PROGRAM names iTerm.app at 3.6.6 or later, and
# tmux replaces TERM_PROGRAM with its own name. iTerm2's real name and version
# are still in LC_TERMINAL and LC_TERMINAL_VERSION, so claude gets those.
# Claude Code also reads iTerm.app in TERM_PROGRAM with a TERM that is not
# screen* or tmux* as tmux -CC; that holds only when the attached client is in
# control mode, so in plain tmux with such a TERM claude keeps tmux's name.
#
# Icon: iTerm2 picks a tab's icon from the job's process name, and under tmux
# that name is the one tmux reports, the basename of the executable file. The
# native installer runs versions/<version> through a symlink, so the name is
# the version number. A hard link named claude to the same file carries the
# right name. It lives in a directory per version and goes when the installer
# removes that version; a launch that cannot make it runs claude as before.
# Only the default CLAUDE_CODE_BIN is linked, and only when it resolves to a
# versions/<version> file: a user-chosen binary or another install is run as
# given.
_iterm_tab_through_tmux() {
    [ -n "${TMUX:-}" ] && [ "${LC_TERMINAL:-}" = iTerm2 ] && [ -z "${CS_NO_ITERM2:-}" ] || return 0

    if [ "${TERM_PROGRAM:-}" != iTerm.app ] && [ -n "${LC_TERMINAL_VERSION:-}" ]; then
        local control_mode
        control_mode=$(_tmux display-message -p '#{client_control_mode}' 2>/dev/null) || control_mode=""
        case "$control_mode:${TERM:-}" in
            1:*|*:screen*|*:tmux*)
                export TERM_PROGRAM=iTerm.app
                export TERM_PROGRAM_VERSION="$LC_TERMINAL_VERSION"
                ;;
        esac
    fi

    [ "$CLAUDE_CODE_BIN" = claude ] || return 0
    local found real link
    found=$(command -v claude 2>/dev/null) || return 0
    real=$(_resolve_symlink_file "$found")
    # Only the native installer's versions/<version> file is self-contained;
    # an npm cli.js loads files beside it, which a hard link elsewhere loses.
    case "$real" in
        */versions/[0-9]*.[0-9]*.[0-9]*) ;;
        *) return 0 ;;
    esac
    # Every launch site expands CLAUDE_CODE_BIN unquoted, since a user value
    # may carry arguments, so a path with whitespace would split there.
    local links="${CS_DATA_DIR:-$HOME/.local/share/cs}/claude"
    case "$links" in *[[:space:]]*) return 0 ;; esac
    # One directory per version: a launch that resolved this version runs it
    # even if another launch links a newer one before this one execs.
    link="$links/$(basename "$real")/claude"
    if ! [ "$link" -ef "$real" ]; then
        mkdir -p "$(dirname "$link")" 2>/dev/null || return 0
        # Link beside the target name and rename over it, so a concurrent
        # launch never finds the name missing.
        ln -f "$real" "$link.$$" 2>/dev/null || return 0
        mv -f "$link.$$" "$link" 2>/dev/null || { rm -f "$link.$$"; return 0; }
    fi
    # A launch marks the directory it picked; another launch may still be
    # waiting to exec that link, at the resume prompt for one.
    touch "$(dirname "$link")" 2>/dev/null || true
    # A link keeps its file's data alive after the installer removes the
    # version; drop those nobody has picked for a day. A claude still running
    # from one keeps its copy. Two launches can prune the same directory, so
    # a removal that finds it gone is not an error.
    # Do not re-fix: a prune can still race a launch that picks the same
    # directory between find and rm, but only if the installer removes that
    # version's file in the same moment. It removes only versions that are
    # no longer current, and a launch only picks the current one (Codex
    # review round 3, accepted 2026-10-05).
    local old
    while IFS= read -r old; do
        [ -e "$(dirname "$real")/$(basename "$old")" ] && continue
        { rm -f "$old/claude"; rmdir "$old"; } 2>/dev/null || true
    done < <(find "$links" -mindepth 1 -maxdepth 1 -type d -mtime +1 2>/dev/null)
    CLAUDE_CODE_BIN="$link"
}

# Run secrets subcommand
