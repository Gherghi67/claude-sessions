#!/bin/sh
# ABOUTME: Starts code-sessions, a fork of cs, against its own profile: configuration, sessions, secrets and caches.
# ABOUTME: Installed as code-sessions and ccs; inside the profile the fork runs as cs, and the original cs stays independent.
set -eu
profile_home=$(CDPATH='' cd -P "$(dirname "$0")/../share/code-sessions/home" && pwd)

case "${1:-}" in
    -update|-uninstall)
        printf 'code-sessions updates from its checkout: rerun setup.sh there.\n' >&2
        exit 1 ;;
    .|-adopt|-checkpoint|-narrative)
        # These operations use the current directory. Keep the original cs's
        # projects out of the profile, including nested directories, except
        # one the profile has itself (a link in its sessions root).
        probe=$(pwd -P)
        case "$probe/" in
            "$profile_home/"*) ;;
            *)
                while [ "$probe" != / ]; do
                    if [ -d "$probe/.cs" ]; then
                        ours=
                        for entry in "$profile_home/sessions"/*; do
                            [ -L "$entry" ] || continue
                            if [ "$(CDPATH='' cd -P "$entry" 2>/dev/null && pwd)" = "$probe" ]; then
                                ours=1
                                break
                            fi
                        done
                        [ -z "$ours" ] || break
                        printf 'This is a workspace of the original cs. Use cs here, or copy it into code-sessions with scripts/cs-to-code-sessions.py.\n' >&2
                        exit 1
                    fi
                    probe=${probe%/*}
                    [ -n "$probe" ] || probe=/
                done ;;
        esac ;;
esac

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
# cs -encrypt names a container after its session alone, and the original cs
# keeps its own in ~/.local/share/cs/vaults: a session both have would share one.
export CS_DATA_DIR="$profile_home/.local/share/cs"
# cs -spawn uses a tmux server of its own. A window runs with its server's
# environment, so on the default one, which the original cs -spawn and the
# user's tmux start too, a spawned code-sessions window ran as the original cs,
# and a server code-sessions started handed this profile to the original's.
export CS_TMUX_SOCKET=code-sessions CS_TMUX_SESSION=code-sessions
# The default macOS keychain backend shares cs:<session>:<name> keys globally.
# Use the profile's encrypted-file backend instead of that shared namespace.
export CS_SECRETS_BACKEND=encrypted CS_SECRETS_DIR="$profile_home/.cs-secrets" CS_NO_UPDATE_CHECK=1
unset CS_SESSION_NAME CS_SESSION_DIR CS_SESSION_META_DIR CS_ACTOR
unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR
# Inside the profile `cs` is code-sessions: its bin comes first on PATH, and
# CODE_SESSIONS_HOME tells cs (and tools such as branch-out) which one runs.
export PATH="$profile_home/.local/bin:$PATH"
export CODE_SESSIONS_HOME="$profile_home" CS_BIN="$profile_home/.local/bin/cs"
exec "$profile_home/.local/bin/cs" "$@"
