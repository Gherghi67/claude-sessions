#!/bin/sh
# ABOUTME: Runs experimental commands against their own configuration, registry and caches.
# ABOUTME: Installed under ags names only; the user's original cs stays independent.
set -eu
command_name=${0##*/}
profile_home=$(CDPATH='' cd -P "$(dirname "$0")/../share/agent-sessions/home" && pwd)

if [ "$command_name" = ags ]; then
    case "${1:-}" in
        -update|-uninstall)
            printf 'Experimental ags: rerun setup.sh to update; the shared installer is disabled here.\n' >&2
            exit 1 ;;
        .|-adopt|-checkpoint|-narrative)
            # These operations use the current directory. Keep old cs projects
            # out of the experimental profile, including nested directories,
            # except one ags has itself (scripts/cs-to-ags.py hands one over).
            probe=$(pwd -P)
            case "$probe/" in
                "$profile_home/"*) ;;
                *)
                    while [ "$probe" != / ]; do
                        if [ -d "$probe/.cs" ]; then
                            ags_has=
                            for entry in "$profile_home/sessions"/*; do
                                [ -L "$entry" ] || continue
                                if [ "$(CDPATH='' cd -P "$entry" 2>/dev/null && pwd)" = "$probe" ]; then
                                    ags_has=1
                                    break
                                fi
                            done
                            [ -z "$ags_has" ] || break
                            printf 'This is an existing cs workspace. Use cs here, or hand it to ags with scripts/cs-to-ags.py.\n' >&2
                            exit 1
                        fi
                        probe=${probe%/*}
                        [ -n "$probe" ] || probe=/
                    done ;;
            esac ;;
    esac
fi

# HOME stays the user's own. macOS finds the login keychain through HOME, so a
# relocated HOME left Claude Code with no keychain to save its OAuth login in,
# and hid ~/.ssh and every other credential from the session. Each tool is
# pointed at the profile through the directory variable it honours instead.
export CLAUDE_CONFIG_DIR="$profile_home/.claude" CODEX_HOME="$profile_home/.codex"
export CS_INSTALL_DIR="$profile_home/.local/bin"
export CS_SESSIONS_ROOT="$profile_home/sessions" CS_CLAUDE_DIR="$profile_home/.claude"
export CS_HOOKS_DIR="$profile_home/.claude/hooks/cs" CS_TRANSCRIPTS_DIR="$profile_home/.claude/projects"
export CS_COMMANDS_DIR="$profile_home/.claude/commands" CS_SKILLS_DIR="$profile_home/.claude/skills"
export CS_CONFIG_DIR="$profile_home/.config/cs" CS_CACHE_DIR="$profile_home/.cache/cs"
# ags -encrypt names a container after its session alone, and stable cs keeps
# its own in ~/.local/share/cs/vaults: a session both have would share one.
export CS_DATA_DIR="$profile_home/.local/share/cs"
# ags -spawn uses a tmux server of its own. A window runs with its server's
# environment, so on the default one, which stable cs -spawn and the user's
# tmux start too, a spawned ags ran as stable cs, and a server ags started
# handed this profile to stable's windows.
export CS_TMUX_SOCKET=ags CS_TMUX_SESSION=ags
# The default macOS keychain backend shares cs:<session>:<name> keys globally.
# Use the profile's encrypted-file backend instead of that shared namespace.
export CS_SECRETS_BACKEND=encrypted CS_SECRETS_DIR="$profile_home/.cs-secrets" CS_NO_UPDATE_CHECK=1
unset CS_SESSION_NAME CS_SESSION_DIR CS_SESSION_META_DIR CS_ACTOR
unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
export PATH="$profile_home/.local/bin:$PATH"
export AGS_BIN="$profile_home/.local/bin/ags" CS_BIN="$profile_home/.local/bin/ags"
exec "$profile_home/.local/bin/$command_name" "$@"
