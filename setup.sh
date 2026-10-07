#!/bin/sh
# ABOUTME: One-command installation of this checkout's Claude and Codex integrations.
# ABOUTME: Builds local artifacts, delegates deployment, and persists the user command path.
set -eu

usage() {
    cat <<'EOF'
Usage: sh /path/to/agent-sessions/setup.sh [--skip-tui-build] [--no-carry-over]

Installs ags and the Claude/Codex integrations from this checkout.
Uses an isolated profile; leaves existing cs commands and configuration alone.
Defaults to both on a fresh install; remembers the previous selection.
Builds the optional session picker when Cargo is available.
Use --skip-tui-build to skip compiling the picker.
Carries your own ~/.claude and ~/.codex setup into the profile (read only;
see scripts/ags-carry-over.sh). Use --no-carry-over, or AGS_CARRY_OVER=0,
to skip that.

Requires bash, git, jq, and Python 3 (for Codex).
Install and authenticate Claude Code and Codex CLI separately.
CS_INSTALL_ENGINES can select claude, codex, or claude,codex.
EOF
}

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }

build_tui=1
carry_over=1
for argument in "$@"; do
    case "$argument" in
        '') ;;
        --skip-tui-build) build_tui=0 ;;
        --no-carry-over) carry_over=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "${AGS_CARRY_OVER:-1}" in 0|no|false) carry_over=0 ;; esac

: "${HOME:?HOME must be set}"
checkout_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
cd "$checkout_dir"
[ -f build.sh ] && [ -f install.sh.in ] && [ -d lib ] && [ -f scripts/ags-profile.sh ] \
    || fail 'Keep setup.sh inside the agent-sessions checkout; this build is not published yet.'

profile_home="$HOME/.local/share/agent-sessions/home"
if [ -z "${CS_INSTALL_ENGINES:-}" ] && [ -f "$profile_home/.local/bin/.cs-install-engines" ]; then
    CS_INSTALL_ENGINES=$(cat "$profile_home/.local/bin/.cs-install-engines")
fi
CS_INSTALL_ENGINES=${CS_INSTALL_ENGINES:-claude,codex}
case "$CS_INSTALL_ENGINES" in
    claude|codex|claude,codex|codex,claude) ;;
    *) fail 'CS_INSTALL_ENGINES must be claude, codex, or claude,codex.' ;;
esac
export CS_INSTALL_ENGINES

missing=''
for dependency in bash git jq; do
    command -v "$dependency" >/dev/null 2>&1 || missing="$missing $dependency"
done
case ",$CS_INSTALL_ENGINES," in
    *,codex,*) command -v python3 >/dev/null 2>&1 || missing="$missing python3" ;;
esac
[ -z "$missing" ] || fail "Install these prerequisites, then rerun setup.sh:$missing"

# The profile's sessions lived in .claude-sessions, a name left from when every
# session was a Claude one; the launcher now points CS_SESSIONS_ROOT at
# sessions/. A running session holds the old path in its environment, so the
# one-time move waits until no profile command runs.
old_sessions="$profile_home/.claude-sessions"
new_sessions="$profile_home/sessions"

sessions_move_pending() {
    [ -e "$old_sessions" ] || [ -L "$old_sessions" ]
}

check_sessions_move() {
    if [ -e "$new_sessions" ] || [ -L "$new_sessions" ]; then
        fail "Both $old_sessions and $new_sessions exist. Move the sessions you keep into sessions/, remove .claude-sessions, then rerun setup.sh."
    fi
    profile_bin="$(cd -P "$profile_home" && pwd)/.local/bin/"
    # List the processes before searching them, so the search is not listed.
    processes=$(ps -A -o pid= -o command=) || fail 'Could not list processes to check for running ags sessions.'
    running=$(printf '%s\n' "$processes" | grep -F "$profile_bin" || true)
    [ -z "$running" ] || fail "These ags processes still use $old_sessions:
$running
End them (bring a suspended one back with fg first), then rerun setup.sh."
}

# Claude names a transcript folder after the session's physical path, with
# every character but a letter or digit turned into '-'.
claude_project_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

rekey_moved_session() {  # old_dir new_dir old_root new_root
    projects="$profile_home/.claude/projects"
    from="$projects/$(claude_project_key "$1")"
    to="$projects/$(claude_project_key "$2")"
    if [ -d "$from" ] && [ ! -e "$to" ]; then
        mv "$from" "$to" \
            || printf 'Warning: could not move the Claude transcripts of %s from %s.\n' "$2" "$from" >&2
    fi
    # A linked worktree's .git file and its repository's record of it both hold
    # absolute paths, and the repository may have moved along with it.
    [ -f "$2/.git" ] || return 0
    gitdir=$(sed -n 's/^gitdir: //p' "$2/.git")
    case "$gitdir" in
        "$3"/*) gitdir="$4/${gitdir#"$3"/}" ;;
        /*) ;;
        *) gitdir="$2/$gitdir" ;;
    esac
    git --git-dir="${gitdir%/worktrees/*}" worktree repair "$2" >/dev/null 2>&1 \
        || printf 'Warning: could not repair the git worktree at %s; run git worktree repair there.\n' "$2" >&2
}

# Claude and Codex remember a trusted folder by its path.
rekey_trusted_folders() {  # old_root new_root
    claude_state="$profile_home/.claude/.claude.json"
    if [ -f "$claude_state" ] && rekeyed=$(jq --arg old "$1/" --arg new "$2/" '
            if (.projects | type) == "object" then
                .projects |= with_entries(if (.key | startswith($old))
                    then .key = $new + .key[($old | length):] else . end)
            else . end' "$claude_state"); then
        printf '%s\n' "$rekeyed" > "$claude_state"
    fi
    codex_config="$profile_home/.codex/config.toml"
    if [ -f "$codex_config" ] && rekeyed=$(awk -v old="[projects.\"$1/" -v new="[projects.\"$2/" '
            index($0, old) == 1 { $0 = new substr($0, length(old) + 1) } { print }' "$codex_config"); then
        printf '%s\n' "$rekeyed" > "$codex_config"
    fi
}

move_sessions_root() {
    check_sessions_move
    old_root=$(cd -P "$old_sessions" && pwd)
    mv "$old_sessions" "$new_sessions"
    new_root=$(cd -P "$new_sessions" && pwd)
    printf 'Moved the profile sessions to %s\n' "$new_sessions"
    # A .claude-sessions symlink moved only the link; its sessions kept their paths.
    [ "$old_root" != "$new_root" ] || return 0
    for session in "$new_sessions"/*; do
        # Likewise a symlinked session: its directory stays where it is.
        [ -d "$session" ] && [ ! -L "$session" ] || continue
        rekey_moved_session "$old_root/${session##*/}" "$new_root/${session##*/}" "$old_root" "$new_root"
    done
    rekey_trusted_folders "$old_root" "$new_root"
}

# Refuse before the build; the move itself happens after the install succeeds.
if sessions_move_pending; then
    check_sessions_move
fi

printf 'Building agent-sessions from %s\n' "$checkout_dir"
bash ./build.sh

if [ "$build_tui" -eq 1 ]; then
    if command -v cargo >/dev/null 2>&1; then
        printf 'Building the optional session picker...\n'
        cargo build --release --locked --manifest-path "$checkout_dir/tui/Cargo.toml"
    else
        printf 'Cargo is unavailable; installing the CLI without compiling the picker.\n'
        printf 'To add the picker later, install Rust and rerun this script.\n'
    fi
fi

# The deployment script uses SHELL to print shell-specific completion guidance.
SHELL=${SHELL:-/bin/sh}
export SHELL
mkdir -p "$profile_home" "$HOME/.local/bin"

# The launcher exports CODEX_HOME as the profile's .codex, and Codex refuses a
# CODEX_HOME that does not exist, so a first Codex launch could never reach
# its login. Private like ~/.codex. Made before the install, which deploys
# Codex's skills into it.
case ",$CS_INSTALL_ENGINES," in
    *,codex,*) mkdir -p "$profile_home/.codex" && chmod 700 "$profile_home/.codex" ;;
esac

# A link an earlier carry-over made, named like a skill this install now
# deploys, would have install.sh copy ags's files through it into ~/.claude or
# ~/.codex. Drop such links, and dangling ones, first; this only ever removes
# links into the user's own directories, so it runs even with --no-carry-over.
bash ./scripts/ags-carry-over.sh --prune

# install.sh lays files out under HOME, so it runs inside the profile. The
# launcher it deploys keeps the user's HOME, hence the absolute hook paths.
# CODEX_HOME is set for the same reason: one inherited from the caller's shell
# would deploy the profile's skills into the user's own Codex.
HOME="$profile_home" XDG_CONFIG_HOME="$profile_home/.config" CS_HOOK_PATHS=absolute \
    XDG_DATA_HOME="$profile_home/.local/share" XDG_CACHE_HOME="$profile_home/.cache" \
    CODEX_HOME="$profile_home/.codex" \
    PATH="$profile_home/.local/bin:$PATH" bash ./install.sh

# The profile's Claude starts from a fresh config, and Claude Code gives a fresh
# config its fullscreen renderer, which takes trackpad gestures such as iTerm2's
# two-finger tab swipe. Carry the user's own display mode over once; a mode
# chosen later inside the profile (/tui) is left alone. Codex-only installs
# have no profile settings.json, so nothing is created for them.
user_settings="$HOME/.claude/settings.json"
profile_settings="$profile_home/.claude/settings.json"
if [ -f "$user_settings" ] && [ -f "$profile_settings" ] \
    && user_tui=$(jq -er '.tui | strings' "$user_settings" 2>/dev/null) \
    && ! jq -e 'has("tui")' "$profile_settings" >/dev/null 2>&1 \
    && carried=$(jq --arg tui "$user_tui" '.tui = $tui' "$profile_settings" 2>/dev/null); then
    printf '%s\n' "$carried" > "$profile_settings"
    printf 'Carried your Claude display mode (tui: %s) into the profile.\n' "$user_tui"
fi

# The rest of the user's own setup follows: instructions, agents, skills and
# commands by link, hooks, plugins, MCP servers and preferences by merge. It
# only reads ~/.claude and ~/.codex, and a failure leaves the install as it is.
if [ "$carry_over" -eq 1 ]; then
    bash ./scripts/ags-carry-over.sh \
        || printf 'Warning: the carry-over stopped; rerun it with: bash %s/scripts/ags-carry-over.sh\n' "$checkout_dir" >&2
fi

# Move the sessions just before the launchers that point at the new root, so
# a failed install leaves the old launchers and the old root together.
if sessions_move_pending; then
    move_sessions_root
fi

# Expose only ags names. Replace wrapper files atomically rather than copying
# through a possible symlink to the user's existing command.
for command_name in ags ags-secrets ags-codex-thread ags-statusline ags-subagent-statusline ags-tui; do
    [ -x "$profile_home/.local/bin/$command_name" ] || continue
    wrapper_tmp=$(mktemp "$HOME/.local/bin/.ags-wrapper.XXXXXX")
    cp scripts/ags-profile.sh "$wrapper_tmp"
    chmod 755 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$HOME/.local/bin/$command_name"
done

add_command_path() {
    startup_file=$1
    if [ -f "$startup_file" ] && grep -Fqx '# >>> agent-sessions PATH >>>' "$startup_file"; then
        return
    fi
    mkdir -p "$(dirname "$startup_file")"
    cat >> "$startup_file" <<'EOF'

# >>> agent-sessions PATH >>>
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< agent-sessions PATH <<<
EOF
    printf 'Added the command path to %s\n' "$startup_file"
}

# A child script cannot change its parent's PATH. Save it for future shells
# without replacing user configuration or adding another block on reinstall.
case "${SHELL##*/}" in
    zsh) add_command_path "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
        add_command_path "$HOME/.bashrc"
        if [ -f "$HOME/.bash_profile" ]; then
            add_command_path "$HOME/.bash_profile"
        elif [ -f "$HOME/.bash_login" ]; then
            add_command_path "$HOME/.bash_login"
        else
            add_command_path "$HOME/.profile"
        fi
        ;;
    *) add_command_path "$HOME/.profile" ;;
esac

"$HOME/.local/bin/ags" -version
printf '\nInstalled. Open a new terminal, then run:\n'
printf '  ags my-project --engine codex\n  ags my-project --engine claude\n'
printf 'Experimental profile: %s\n' "$profile_home"
printf 'Claude and Codex keep their own login and configuration files in this profile.\n'
printf 'Your original cs commands, Claude settings, and sessions are unchanged by setup.\n'
for runtime in claude codex; do
    case ",$CS_INSTALL_ENGINES," in
        *,"$runtime",*)
            if ! command -v "$runtime" >/dev/null 2>&1; then
                printf 'The %s CLI is not on PATH; install and authenticate it before launching that engine.\n' "$runtime"
            fi
            ;;
    esac
done
