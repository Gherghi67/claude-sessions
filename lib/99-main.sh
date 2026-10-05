# ABOUTME: main(): the top-level command dispatch and the entry-point call.
# ABOUTME: Assembled last so 'main "$@"' runs after every definition.

main() {
    cs_import_session_context
    # cs IS the launch, and the hooks read that from the ABSENCE of this marker
    # (hooks/cs-resolve.sh preserves an inherited value rather than setting
    # one). A teammate's shell carries CS_RESOLVED_FROM=walk deliberately, so
    # without this an inherited marker rides into everything cs starts —
    # `ags -spawn` most of all — and that session's SessionEnd reads itself as a
    # walked-in front end and declines to clear its own lock. cs never reads the
    # variable, so dropping it here costs nothing and covers every exec path.
    unset CS_RESOLVED_FROM

    # A launcher that composes `<binary> -- <operands>` hands cs the POSIX
    # end-of-options separator, which the unknown-verb arm read as a command
    # nobody could have typed. Drop one, and read the rest exactly as before.
    if [ "${1:-}" = "--" ]; then
        shift
    fi

    if [ $# -eq 0 ]; then
        if [ -t 1 ]; then
            # Bare cs is the picker everywhere, a session directory included;
            # `cs .` is the explicit way to open the session you stand in.
            # `||`, not two statements: run_tui returns non-zero only when no
            # picker is installed, and under `set -e` a bare failing call would
            # end cs there — printing nothing at all on the machines that need
            # the help most.
            run_tui || show_help
        else
            echo "ags <name>        Create or resume a session"
            echo "ags -list         List all sessions"
            echo "ags -search       Search across sessions"
            echo "ags -help         Show full help"
            echo "ags -version      Show version"
        fi
        exit 0
    fi

    local cmd="$1"

    # `ags <verb> --help` before the arms: each one resolves a session or parses
    # its own arguments first, so the flag would arrive as data. -secrets is
    # exempt because it forwards to cs-secrets, which holds the reference for
    # its own verbs; a derived usage line would answer in that reference's place.
    case "$cmd" in
        -secrets) ;;
        -*) if _is_help_flag "${2:-}"; then show_verb_help "$cmd"; return $?; fi ;;
    esac

    # Handle subcommands (with - prefix)
    case "$cmd" in
        -h|-help|--help)
            show_help
            return 0
            ;;
        -v|-version|--version)
            echo "ags $VERSION"
            return 0
            ;;
        -tui)
            run_tui || error "The session manager (ags-tui) is not installed. Reinstall ags, or run 'ags -list'."
            return 0
            ;;
        -list|-ls)
            if _tui_bin >/dev/null 2>&1; then
                info "Hint: run bare 'ags' for the interactive session manager"
            fi
            shift
            list_sessions "$@"
            return 0
            ;;
        -remove|-rm)
            shift
            remove_session "$@"
            return 0
            ;;
        -adopt)
            if [ "${2:-}" = "--worktrees" ]; then
                shift 2
                adopt_worktrees "$@"
            else
                shift
                adopt_session "$@"
            fi
            return 0
            ;;
        -complete) # hidden: shell-completion plumbing, not a user-facing command
            cmd_complete "${2:-}"
            return 0
            ;;
        -codex-hook) # hidden: the command Codex runs from $CODEX_HOME/hooks.json, not typed by a user
            shift
            cmd_codex_hook "$@"
            return $?
            ;;
        -whoami)
            cmd_whoami
            return 0
            ;;
        -who)
            cmd_who
            return 0
            ;;
        -engine)
            shift
            cmd_engine "$@"
            return $?
            ;;
        -secrets)
            shift
            run_secrets "$@"
            return 0
            ;;
        -uninstall)
            run_uninstall
            return 0
            ;;
        -update)
            local update_arg="${2:-}"
            case "$update_arg" in
                --check|-c)
                    check_update
                    ;;
                --force|-f)
                    do_update "true"
                    ;;
                "")
                    do_update
                    ;;
                *)
                    error "Unknown option: $update_arg. Use 'ags -update [--check|--force]'"
                    ;;
            esac
            return 0
            ;;
        -search)
            shift
            search_sessions "$@"
            return 0
            ;;
        -checkpoint)
            shift
            run_checkpoint "$@"
            return 0
            ;;
        -narrative)
            shift
            run_narrative "$@"
            return 0
            ;;
        -queue)
            shift
            run_queue "$@"
            return 0
            ;;
        -msg)
            shift
            run_mail "$@"
            return 0
            ;;
        -spawn)
            shift
            run_spawn "$@"
            return 0
            ;;
        -conversations)
            shift
            run_conversations "$@"
            return 0
            ;;
        -status)
            shift
            run_status "$@"
            return 0
            ;;
        -live)
            cmd_live
            return 0
            ;;
        -usage)
            shift
            run_usage "$@"
            return $?
            ;;
        -tag)
            shift
            run_tag "$@"
            return $?
            ;;
        -encrypt)
            shift
            run_encrypt "$@"
            return $?
            ;;
        -archive)
            shift
            run_archive "$@"
            return $?
            ;;
        -unarchive)
            shift
            run_unarchive "$@"
            return $?
            ;;
        -doctor|-diag)
            run_doctor
            return $?
            ;;
        -detect-theme)
            detect_term_theme
            return 0
            ;;
        -statusline)
            shift
            run_statusline_cmd "$@"
            return $?
            ;;
        -*)
            error "Unknown command: $cmd. Run 'ags -help' for usage."
            ;;
    esac

    # `cs .` opens the session you are standing in, under the name cs knows it
    # by (an adopted project's cs name, not its directory's). Resolved here so
    # the lock, migration and launch are the ones `ags <name>` gets. Never
    # adopts: a directory that is not a session is refused, not made into one.
    if [ "$cmd" = "." ]; then
        cmd=$(_session_name_for_dir "$PWD") \
            || error "Not an agent-sessions session: $PWD. Run 'ags -adopt <name>' to make it one, or bare 'ags' to pick a session."
    fi

    local session_name="$cmd"
    local force_flag=""
    local merge_feature=""
    local explicit_engine=""
    local launch_intent=auto

    # Validate inputs
    local wt_base="" wt_task=""
    if cs_split_worktree_name "$session_name"; then
        wt_base="$CS_WT_BASE"
        wt_task="$CS_WT_TASK"
    else
        validate_session_name "$session_name"
    fi

    # Parse session subcommands with a while loop to support flag combinations
    shift  # Remove session name / cmd
    # The separator can arrive here too, between the session and its flags.
    # Only in this position: further in, `--` is a word in a verb's own
    # arguments — a mail body may legitimately contain one.
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    # `ags <name> <verb> --help` — same reasoning as the global form above,
    # including the -secrets exemption.
    case "${1:-}" in
        -secrets) ;;
        -*) if _is_help_flag "${2:-}"; then show_verb_help "$1"; return $?; fi ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --engine)
                [ $# -ge 2 ] && [ -n "$2" ] || error "--engine needs claude or codex"
                cs_engine_known "$2" || error "Unknown engine: $2. Choose claude or codex."
                explicit_engine="$2"
                shift 2
                ;;
            --engine=*)
                explicit_engine="${1#--engine=}"
                cs_engine_known "$explicit_engine" || error "--engine needs claude or codex"
                shift
                ;;
            -secrets)
                shift
                export CS_SESSION_NAME="$session_name"
                # Worktree secrets live under the base session's namespace
                # (no launched session ever uses cs:<base>@<task>:*); a plain
                # session name is its own target.
                export CS_SECRETS_SESSION="${wt_base:-$session_name}"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_secrets "$@"
                return 0
                ;;
            -queue)
                shift
                export CS_SESSION_NAME="$session_name"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_queue "$@"
                return 0
                ;;
            -msg)
                shift
                # Send-only: the positional session is the TARGET. The sender's
                # own identity comes from the caller's environment (or none).
                # A bare or lone-'log' invocation is a read attempt aimed at
                # the send-only arm; catch it before 'log' becomes a body.
                if [ $# -eq 0 ]; then
                    error "ags $session_name -msg sends mail and needs a body; to read mail, run 'ags -msg' inside that session"
                fi
                if [ $# -eq 1 ] && [ "$1" = "log" ]; then
                    error "ags $session_name -msg is send-only; to read the mail log, run 'ags -msg log' inside that session"
                fi
                # 'thread' names a reading command and always takes an argument,
                # so the lone-word shape above cannot catch it: unguarded,
                # `cs freya -msg thread a3f9c1` silently mails freya the words
                # "thread a3f9c1". Quoting the body into one argument still
                # sends it.
                case "${1:-}" in
                    thread)
                        error "ags $session_name -msg is send-only; to read a thread, run 'ags -msg thread ${2:-<id>}' inside that session"
                        ;;
                esac
                run_mail "$session_name" "$@"
                return 0
                ;;
            -conversations)
                shift
                export CS_SESSION_NAME="$session_name"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_conversations "$@"
                return 0
                ;;
            -narrative)
                shift
                # Reachable from outside any session — the picker shells out
                # this way. A worktree session's directory is literally
                # "<base>@<task>" under the sessions root and carries its own
                # .cs, so one path serves both forms: a worktree rotates its
                # OWN narrative, unlike -secrets, which routes a worktree to
                # the base's namespace. Guarded on cs's own is_session_dir, not
                # on bare existence: an adopted session is a symlink into the
                # user's project, and a dangling one passes -L but has no .cs
                # behind it, so the failure would surface as rotate_narrative's
                # "run from inside a session" — which answers the global form
                # and misnames this one's fault.
                is_session_dir "$SESSIONS_ROOT/$session_name" \
                    || error "No such session: $session_name"
                export CS_SESSION_NAME="$session_name"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_narrative "$@"
                return 0
                ;;
            -usage)
                shift
                export CS_SESSION_NAME="$session_name"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_usage "$session_name" "$@"
                return 0
                ;;
            -tag)
                shift
                export CS_SESSION_NAME="$session_name"
                export CS_SESSION_DIR="$SESSIONS_ROOT/$session_name"
                export CS_SESSION_META_DIR="$SESSIONS_ROOT/$session_name/.cs"
                run_tag "$@"
                return 0
                ;;
            -features)
                shift
                run_features "$session_name" "$@"
                return 0
                ;;
            -integrate-feature) # hidden: driven by skills/finish/scripts/finish.sh, not typed by a user
                shift
                [ -n "${1:-}" ] || error "Usage: ags <base> -integrate-feature <task> <sha> [--from-remote] -- <gate command...>"
                # Validate <base>@<feature> the same way the launch path does, so a
                # task name with path separators is rejected before any
                # filesystem lookup.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                integrate_feature_worktree "$session_name" "$@"
                return 0
                ;;
            -retire-feature) # hidden: driven by skills/finish/scripts/finish.sh, not typed by a user
                shift
                [ -n "${1:-}" ] || error "Usage: ags <base> -retire-feature <task> <sha> [--force]"
                # Validate <base>@<feature> the same way the launch path does,
                # so a task name with path separators (which would build an
                # escaping worktree path) is rejected before any filesystem
                # lookup. cs_split_worktree_name errors on a bad base or task.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                retire_feature_worktree "$session_name" "$@"
                return 0
                ;;
            -finish)
                shift
                [ -n "${1:-}" ] || error "Usage: ags <base> -finish <feature>"
                # Validate the same way the launch path does, so a feature name with
                # path separators is rejected before any filesystem lookup.
                cs_split_worktree_name "$session_name@$1" >/dev/null
                merge_feature="$1"
                shift
                ;;
            --fresh|--resume)
                local selected_intent="${1#--}"
                [ "$launch_intent" = auto ] || [ "$launch_intent" = "$selected_intent" ] \
                    || error "--fresh and --resume cannot be combined"
                launch_intent="$selected_intent"
                shift
                ;;
            --force)
                force_flag="true"
                shift
                ;;
            *)
                error "Unknown session command: $1. Use -secrets, -queue, -msg, -narrative, -conversations, -usage, -tag, -features, -finish, --engine, --fresh, --resume, or --force."
                ;;
        esac
    done

    local session_dir="$SESSIONS_ROOT/$session_name"
    local engine
    engine=$(_session_engine "$session_dir" "$explicit_engine")
    if [ -n "$merge_feature" ] && ! cs_engine_supports "$engine" feature_finish; then
        error "-finish requires Claude. Use: ags $session_name --engine claude -finish $merge_feature"
    fi

    # An explicit resume must never create a workspace or allocate a binding
    # during migration. Validate before any workspace preparation changes.
    if [ "$launch_intent" = resume ]; then
        [ -d "$session_dir" ] || error "Cannot resume: session $session_name does not exist"
        local resume_binding
        resume_binding=$(cs_binding_read "$session_dir" "$engine") \
            || error "Cannot read the recorded $engine conversation; repair the binding before resuming"
        [ -n "$resume_binding" ] || error "Cannot resume: no recorded $engine conversation for $session_name. Use --fresh."
    fi

    check_dependencies "$engine"

    # Check for updates (non-blocking)
    check_update_notify

    # Define paths (resolve symlinks for adopted sessions so Claude Code
    # sees the original project path, preserving conversation continuity)
    if [ -L "$session_dir" ]; then
        session_dir="$(_resolve_symlink_dir "$session_dir")"
    fi
    local is_new="false"
    # Workspace adapters read the dynamically scoped intent during migration.
    # shellcheck disable=SC2034
    local CS_LAUNCH_INTENT="$launch_intent"

    if [ -n "$wt_base" ]; then
        # Worktree session: create from the base, or open the existing one.
        local base_dir
        base_dir=$(_resolve_session_dir "$wt_base")
        if [ ! -e "$base_dir" ]; then
            error "Base session not found: $wt_base"
        fi
        # Checked on the base first: a worktree of an encrypted session is
        # refused whether its vault is mounted or not, and a worktree's own
        # copies of its links dangle with nothing to mount, so "mount it"
        # would mislead.
        _refuse_worktree_of_encrypted_base "$wt_base" "$base_dir"
        if [ ! -d "$session_dir" ]; then
            is_new="true"
            # The base's vault links are refused above, so this catches a
            # regular file where one belongs, or plaintext ags files beside a
            # .cs/private made by hand.
            _refuse_unmounted_meta "$wt_base" "$base_dir"
            confirm_clean_worktree_base "$base_dir" "$wt_base"
            session_dir=$(create_worktree_session "$base_dir" "$wt_base" "$wt_task" "$engine")
        else
            # A worktree whose own checkout carries vault links refuses by
            # name while they dangle; a base's links never get this far.
            _refuse_unmounted_meta "$session_name" "$session_dir"
            # The backfill a base session gets from migrate_session, which the
            # worktree path below deliberately skips: an older worktree, or one
            # from a clone, still arrives at the umask's mode.
            _harden_session_meta "$session_dir"
            chmod 700 "$session_dir" 2>/dev/null || true
            local pinned head_branch
            pinned=$(_read_local_state "$session_dir/.cs/local/state" task_branch)
            head_branch=$(git -C "$session_dir" branch --show-current 2>/dev/null || echo "")
            if [ -n "$pinned" ] && [ "$head_branch" != "$pinned" ]; then
                warn "Worktree HEAD is '$head_branch' but this feature expects '$pinned' (did something run git switch here?)"
            fi
            # No migrate_session here: worktree checkouts never predate the
            # worktree feature, and its CLAUDE.md rewrite must never touch a
            # project's own file (ignored-.cs repos track their real CLAUDE.md).
            # Mail and queue migration DO run: a worktree can hold a legacy
            # inbox.jsonl or queue file from the shipped versions, and both
            # conversions touch only .cs/local — never project files.
            migrate_mailbox "$session_dir"
            _queue_convert_legacy "$session_dir/.cs/local"
            cs_engine_call "$engine" prepare_workspace "$session_dir" worktree
        fi
    elif [ ! -d "$session_dir" ]; then
        is_new="true"
        create_session_structure "$session_dir" "$engine"
        # cs created this directory, so its mode is cs's to set. The adopt path
        # deliberately does not do this: there the root is the user's own
        # project, and only the .cs tree inside it belongs to cs.
        chmod 700 "$session_dir" 2>/dev/null || true

        # Initialize local git repo by default
        (
            cd "$session_dir" || exit 0
            create_session_gitignore "$session_dir"
            git init -q 2>/dev/null || true
            # cs writes its bookkeeping files with LF. A global core.autocrlf
            # rewrites the checked-out .gitignore to CRLF — every pattern then
            # carries a trailing \r and matches nothing, so files meant to be
            # ignored surface as untracked.
            git config core.autocrlf false 2>/dev/null || true
            git branch -M main 2>/dev/null || true
            setup_merge_attributes "$session_dir"
            git add -A 2>/dev/null || true
            git commit -q -m "Initial session structure" 2>/dev/null || true
        )
    else
        _run_pre_open "$session_name" "$session_dir"
        _refuse_unmounted_meta "$session_name" "$session_dir"
        migrate_session "$session_dir" "$engine"
    fi

    if [ -n "$merge_feature" ]; then
        local _known
        _known=$(_worktree_features "$session_name")
        case "
$_known
" in
            *"
$merge_feature
"*) ;;
            *) error "No feature worktree '$merge_feature' of '$session_name'. List them with: ags $session_name -features" ;;
        esac
    fi

    cs_launch_session "$engine" "$session_name" "$session_dir" "$is_new" "$force_flag" "$merge_feature" "$launch_intent"
}

main "$@"
