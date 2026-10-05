#!/bin/sh
# ABOUTME: One-command installation of this checkout's Claude and Codex integrations.
# ABOUTME: Builds local artifacts, delegates deployment, and persists the user command path.
set -eu

usage() {
    cat <<'EOF'
Usage: sh /path/to/agent-sessions/setup.sh [--skip-tui-build]

Installs ags and the Claude/Codex integrations from this checkout.
Uses an isolated profile; leaves existing cs commands and configuration alone.
Defaults to both on a fresh install; remembers the previous selection.
Builds the optional session picker when Cargo is available.
Use --skip-tui-build to skip compiling the picker.

Requires bash, git, jq, and Python 3 (for Codex).
Install and authenticate Claude Code and Codex CLI separately.
CS_INSTALL_ENGINES can select claude, codex, or claude,codex.
EOF
}

fail() { printf 'Error: %s\n' "$1" >&2; exit 1; }

build_tui=1
case "${1:-}" in
    '') ;;
    --skip-tui-build) build_tui=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

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
printf 'Claude and Codex use separate configuration and login in this profile.\n'
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
