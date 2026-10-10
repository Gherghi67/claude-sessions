#!/bin/sh
# ABOUTME: One-command installation of code-sessions (a fork of cs) from this checkout, into its own profile.
# ABOUTME: Builds, moves an older ags profile over once, installs, and puts the code-sessions and ccs launchers on PATH.
set -eu

usage() {
    cat <<'EOF'
Usage: sh /path/to/code-sessions/setup.sh [--skip-tui-build] [--no-carry-over]

Installs code-sessions, a fork of cs, and its Claude/Codex integrations from
this checkout into its own profile, started as code-sessions or ccs. Inside
the profile the fork runs as cs; your original cs commands, configuration and
sessions are left alone. An ags profile from before the rename
(~/.local/share/agent-sessions/home) is moved over once.
Defaults to both on a fresh install; remembers the previous selection.
Builds the optional session picker when Cargo is available.
Use --skip-tui-build to skip compiling the picker.
Carries your own ~/.claude and ~/.codex setup into the profile (read only;
see scripts/carry-over.sh). Use --no-carry-over, or CS_CARRY_OVER=0,
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
case "${CS_CARRY_OVER:-1}" in 0|no|false) carry_over=0 ;; esac

: "${HOME:?HOME must be set}"
checkout_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
cd "$checkout_dir"
[ -f build.sh ] && [ -f install.sh.in ] && [ -d lib ] && [ -f scripts/code-sessions-profile.sh ] \
    || fail 'Keep setup.sh inside the code-sessions checkout; this build is not published yet.'

profile_home="$HOME/.local/share/code-sessions/home"
# Before the rename the profile lived here, with ags launchers in ~/.local/bin.
old_profile_home="$HOME/.local/share/agent-sessions/home"
engines_file="$profile_home/.local/bin/.cs-install-engines"
[ -e "$profile_home" ] || engines_file="$old_profile_home/.local/bin/.cs-install-engines"
if [ -z "${CS_INSTALL_ENGINES:-}" ] && [ -f "$engines_file" ]; then
    CS_INSTALL_ENGINES=$(cat "$engines_file")
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
    processes=$(ps -A -o pid= -o command=) || fail 'Could not list processes to check for running code-sessions sessions.'
    running=$(printf '%s\n' "$processes" | grep -F "$profile_bin" || true)
    [ -z "$running" ] || fail "These code-sessions processes still use $old_sessions:
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

# ---- the one-time move of the ags profile ---------------------------------
# The fork was called ags (agent-sessions) before it became code-sessions. Its
# profile moves over whole: sessions, Claude and Codex logins and history,
# secrets. Files that name the profile by its absolute path are rewritten, the
# Claude transcript folders named after a session inside it are renamed, and
# the launchers and helpers called ags give way to the cs ones install.sh puts
# there.
profile_move_pending() {
    [ -d "$old_profile_home" ] && [ ! -L "$old_profile_home" ]
}

check_profile_move() {
    if [ -e "$profile_home" ] || [ -L "$profile_home" ]; then
        fail "Both $old_profile_home and $profile_home exist. Keep one: move what you need from the old ags profile, remove it, then rerun setup.sh."
    fi
    old_bin="$(cd -P "$old_profile_home" && pwd)/.local/bin/"
    # List the processes before searching them, so the search is not listed.
    processes=$(ps -A -o pid= -o command=) || fail 'Could not list processes to check for running ags sessions.'
    running=$(printf '%s\n' "$processes" | grep -F "$old_bin" || true)
    [ -z "$running" ] || fail "These ags processes still run from $old_profile_home:
$running
End them (bring a suspended one back with fg first), then rerun setup.sh."
}

# Every occurrence of $2 in a file becomes $3, as plain text; the file keeps
# its inode and mode. Paths hold no awk escapes, so -v passes them as they are.
replace_in_file() {  # file, from, to
    [ -f "$1" ] && [ ! -L "$1" ] || return 0
    grep -qF -- "$2" "$1" 2>/dev/null || return 0
    replaced=$(mktemp "$1.move.XXXXXX") || return 1
    awk -v from="$2" -v to="$3" '{
        out = ""; line = $0
        while ((at = index(line, from)) > 0) {
            out = out substr(line, 1, at - 1) to
            line = substr(line, at + length(from))
        }
        print out line
    }' "$1" > "$replaced" && cat "$replaced" > "$1"
    status=$?
    rm -f "$replaced"
    return $status
}

# A session's CLAUDE.local.md tells the agent to run `ags -secrets` and the
# like, and after the move there is no ags. The protocol said ags where cs's
# says cs and nothing else differed, so these phrases are all it takes, from
# the first cs sentinel on: what the user wrote above the protocol stays.
reword_ags_protocol() {  # CLAUDE.local.md
    [ -f "$1" ] && [ ! -L "$1" ] || return 0
    grep -q '<!-- cs:' "$1" 2>/dev/null || return 0
    reworded=$(mktemp "$1.move.XXXXXX") || return 1
    awk '
        function swap(line, f, t,   out, at) {
            out = ""
            while ((at = index(line, f)) > 0) {
                out = out substr(line, 1, at - 1) t
                line = substr(line, at + length(f))
            }
            return out line
        }
        BEGIN {
            n = split("managed by agent-sessions (ags).|`ags -|$(ags -|the ags session store|" \
                "(ags redirects via|tombstone — ags treats|ags does not copy your first prompt", from, "|")
            split("managed by the cs tool.|`cs -|$(cs -|the cs session store|" \
                "(cs redirects via|tombstone — cs treats|cs does not copy your first prompt", to, "|")
        }
        index($0, "<!-- cs:") { protocol = 1 }
        protocol { for (i = 1; i <= n; i++) $0 = swap($0, from[i], to[i]) }
        { print }' "$1" > "$reworded" || { rm -f "$reworded"; return 1; }
    if cmp -s "$1" "$reworded"; then
        rm -f "$reworded"
        return 0
    fi
    cat "$reworded" > "$1"
    status=$?
    rm -f "$reworded"
    return $status
}

rewrite_profile_path() {  # file, old profile, new profile
    replace_in_file "$1" "$2/.local/bin/ags-" "$3/.local/bin/cs-" \
        && replace_in_file "$1" "$2/.local/bin/ags" "$3/.local/bin/cs" \
        && replace_in_file "$1" "$2/" "$3/"
}

move_profile() {
    old_real=$(cd -P "$old_profile_home" && pwd)
    mkdir -p "$(dirname "$profile_home")"
    mv "$old_profile_home" "$profile_home"
    new_real=$(cd -P "$profile_home" && pwd)
    rmdir "$(dirname "$old_profile_home")" 2>/dev/null || true
    printf 'Moved the ags profile to %s\n' "$profile_home"

    # The commands were ags, ags-statusline and so on, with cs links to them.
    # install.sh writes cs and its helpers next; a cs link left here would
    # carry that write into the old ags file.
    for old_command in "$profile_home"/.local/bin/ags "$profile_home"/.local/bin/ags-* \
        "$profile_home"/.local/bin/cs "$profile_home"/.local/bin/cs-*; do
        case "${old_command##*/}" in
            ags|ags-*) [ -e "$old_command" ] || [ -L "$old_command" ] || continue ;;
            *) [ -L "$old_command" ] || continue ;;
        esac
        rm -f "$old_command"
    done
    rm -f "$profile_home/.zsh/completions/_ags" "$profile_home/.bash_completion.d/ags.bash"
    for engine_dir in .claude .codex; do
        if [ -f "$profile_home/$engine_dir/.ags-carried-hooks.json" ] \
            && [ ! -e "$profile_home/$engine_dir/.carried-hooks.json" ]; then
            mv "$profile_home/$engine_dir/.ags-carried-hooks.json" "$profile_home/$engine_dir/.carried-hooks.json"
        fi
    done

    # Settings, hooks, trust and history name the profile by its path, and
    # its helpers by their ags names. Trust and transcripts use the physical
    # path, hooks the one install.sh was given; install.sh recognises its own
    # hooks only by the path it writes, so each spelling keeps its own. The
    # physical one goes first: once rewritten it no longer holds the other.
    for config in .claude/settings.json .claude/.claude.json .claude/history.jsonl \
        .claude/plugins/installed_plugins.json .claude/plugins/known_marketplaces.json \
        .claude/agents-sidebar-status/original-statusline .claude/.carried-hooks.json \
        .codex/hooks.json .codex/config.toml .codex/.carried-hooks.json; do
        rewrite_profile_path "$profile_home/$config" "$old_real" "$new_real" \
            && { [ "$old_profile_home" = "$old_real" ] \
                || rewrite_profile_path "$profile_home/$config" "$old_profile_home" "$profile_home"; } \
            || printf 'Warning: could not rewrite the profile path in %s\n' "$profile_home/$config" >&2
    done

    # Claude names a transcript folder after the session's physical path.
    old_key=$(claude_project_key "$old_real")
    new_key=$(claude_project_key "$new_real")
    for project in "$profile_home/.claude/projects/$old_key"*; do
        [ -d "$project" ] || continue
        renamed="$profile_home/.claude/projects/$new_key${project##*/"$old_key"}"
        if [ -e "$renamed" ]; then
            printf 'Warning: %s already exists; the transcripts in %s stay where they are.\n' "$renamed" "$project" >&2
            continue
        fi
        mv "$project" "$renamed"
    done

    # A worktree session inside the profile names its repository by path.
    for session in "$profile_home"/sessions/* "$profile_home"/work/*; do
        [ -d "$session" ] && [ ! -L "$session" ] && [ -f "$session/.git" ] || continue
        gitdir=$(sed -n 's/^gitdir: //p' "$session/.git")
        case "$gitdir" in
            "$old_real"/*) gitdir="$new_real/${gitdir#"$old_real"/}" ;;
            /*) ;;
            *) gitdir="$session/$gitdir" ;;
        esac
        git --git-dir="${gitdir%/worktrees/*}" worktree repair "$session" >/dev/null 2>&1 \
            || printf 'Warning: could not repair the git worktree at %s; run git worktree repair there.\n' "$session" >&2
    done

    # Every session, a linked one in its own folder too, and its features.
    for session in "$profile_home"/sessions/* "$profile_home"/work/*; do
        [ -d "$session" ] || continue
        reword_ags_protocol "$session/CLAUDE.local.md" \
            || printf 'Warning: could not reword the session protocol in %s\n' "$session/CLAUDE.local.md" >&2
    done

    # Caches keyed on the old paths rebuild themselves.
    rm -rf "$profile_home/.cache/cs/git" "$profile_home/.cache/cs/org"
}

# ---- the profile's secrets into the keychain ---------------------------------
# The profile kept its secrets in an encrypted file per session, <session>.enc,
# until the launcher gave it the keychain as the original cs has, with items
# named code-sessions:<session>:<name>. Each file moves over once, through the
# profile's own cs-secrets: never onto a keychain item of the same name, and
# not while the session or one of its features is open, since an agent there
# still reads the file. A file is removed once it holds nothing.
profile_secrets() {  # backend ('' lets cs-secrets pick), cs-secrets arguments...
    secrets_backend=$1
    shift
    env -u CS_SECRETS_BACKEND -u CS_SECRETS_KEYCHAIN_PREFIX -u CS_SESSION_NAME -u CLAUDE_SESSION_NAME \
        ${secrets_backend:+CS_SECRETS_BACKEND=$secrets_backend} \
        CS_SECRETS_KEYCHAIN_PREFIX=code-sessions CS_SECRETS_DIR="$profile_home/.cs-secrets" \
        "$profile_home/.local/bin/cs-secrets" "$@"
}

profile_secret_names() {  # backend, session
    listing=$(profile_secrets "$1" --session "$2" list 2>/dev/null) || return 1
    printf '%s\n' "$listing" | sed -n 's/^  - //p'
}

# A session holds .cs/session.lock with the pid of its running agent.
secrets_session_open() {  # session
    for lock in "$profile_home/sessions/$1/.cs/session.lock" "$profile_home/sessions/$1"@*/.cs/session.lock; do
        [ -f "$lock" ] || continue
        lock_pid=$(head -n 1 "$lock" | tr -cd '0-9')
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

move_secrets_to_keychain() {
    for store in "$profile_home/.cs-secrets"/*.enc; do
        [ -f "$store" ] || continue
        # Only where cs-secrets picks the keychain; elsewhere the files are the store.
        profile_secrets '' backend 2>/dev/null | grep -q '^Storage backend: keychain$' || return 0
        secrets_session=${store##*/}
        secrets_session=${secrets_session%.enc}
        if secrets_session_open "$secrets_session"; then
            printf 'Left the secrets of %s in %s: the session is open. Close it, then rerun setup.sh.\n' \
                "$secrets_session" "$store"
            continue
        fi
        if ! old_names=$(profile_secret_names encrypted "$secrets_session") \
            || ! keychain_names=$(profile_secret_names keychain "$secrets_session"); then
            printf 'Warning: could not read the secrets of %s; they stay in %s.\n' "$secrets_session" "$store" >&2
            continue
        fi
        # Secret names are letters, digits, '_' and '-', so they split on spaces.
        clash=''
        for name in $old_names; do
            if printf '%s\n' "$keychain_names" | grep -Fqx -- "$name"; then
                clash="$clash $name"
            fi
        done
        if [ -n "$clash" ]; then
            printf 'Left the secrets of %s in %s: the keychain already has%s under code-sessions:%s.\n' \
                "$secrets_session" "$store" "$clash" "$secrets_session"
            continue
        fi
        # migrate-backend deletes from the file only what it stored, and only
        # when it stored them all; what is left is read back below.
        if [ -n "$old_names" ]; then
            profile_secrets keychain --session "$secrets_session" \
                migrate-backend keychain --from encrypted --delete-source >/dev/null 2>&1 || true
        fi
        if ! left=$(profile_secret_names encrypted "$secrets_session"); then
            printf 'Warning: could not read %s back; check it, then rerun setup.sh.\n' "$store" >&2
        elif [ -n "$left" ]; then
            printf 'Warning: these secrets of %s did not reach the keychain and stay in %s: %s. Rerun setup.sh.\n' \
                "$secrets_session" "$store" "$(printf '%s' "$left" | tr '\n' ' ')" >&2
        else
            rm -f "$store"
            if [ -n "$old_names" ]; then
                printf 'Moved the secrets of %s into the keychain, as code-sessions:%s:<name>.\n' \
                    "$secrets_session" "$secrets_session"
            fi
        fi
    done
}

# Refuse before the build; the moves themselves happen after the build.
if profile_move_pending; then
    check_profile_move
fi
if sessions_move_pending; then
    check_sessions_move
fi

printf 'Building code-sessions from %s\n' "$checkout_dir"
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

if profile_move_pending; then
    move_profile
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
# deploys, would have install.sh copy cs's files through it into ~/.claude or
# ~/.codex. Drop such links, and dangling ones, first; this only ever removes
# links into the user's own directories, so it runs even with --no-carry-over.
bash ./scripts/carry-over.sh --prune

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
    bash ./scripts/carry-over.sh \
        || printf 'Warning: the carry-over stopped; rerun it with: bash %s/scripts/carry-over.sh\n' "$checkout_dir" >&2
fi

# Move the sessions just before the launchers that point at the new root, so
# a failed install leaves the old launchers and the old root together.
if sessions_move_pending; then
    move_sessions_root
fi

move_secrets_to_keychain

# The launchers are code-sessions and its short name ccs; cs on PATH stays the
# original's. Replace each atomically rather than copying through a possible
# symlink.
for command_name in code-sessions ccs; do
    wrapper_tmp=$(mktemp "$HOME/.local/bin/.code-sessions-wrapper.XXXXXX")
    cp scripts/code-sessions-profile.sh "$wrapper_tmp"
    chmod 755 "$wrapper_tmp"
    mv -f "$wrapper_tmp" "$HOME/.local/bin/$command_name"
done

# The ags launchers from before the rename, and only those: each is this
# checkout's old wrapper, which names the old profile.
for command_name in ags ags-secrets ags-codex-thread ags-statusline ags-subagent-statusline ags-tui; do
    old_launcher="$HOME/.local/bin/$command_name"
    [ -f "$old_launcher" ] && [ ! -L "$old_launcher" ] || continue
    grep -qF 'share/agent-sessions/home' "$old_launcher" 2>/dev/null || continue
    rm -f "$old_launcher"
    printf 'Removed the old launcher %s
' "$old_launcher"
done

add_command_path() {
    startup_file=$1
    # Before the rename the block was called agent-sessions; it does the same.
    if [ -f "$startup_file" ] && { grep -Fqx '# >>> code-sessions PATH >>>' "$startup_file" \
        || grep -Fqx '# >>> agent-sessions PATH >>>' "$startup_file"; }; then
        return
    fi
    mkdir -p "$(dirname "$startup_file")"
    cat >> "$startup_file" <<'EOF'

# >>> code-sessions PATH >>>
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< code-sessions PATH <<<
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

"$HOME/.local/bin/code-sessions" -version
printf '\nInstalled. Open a new terminal, then run:\n'
printf '  ccs my-project --engine codex\n  ccs my-project --engine claude\n'
printf 'ccs is short for code-sessions. Inside a session cs is code-sessions; in a terminal cs stays the original.\n'
printf 'Profile: %s\n' "$profile_home"
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
