#!/usr/bin/env bash
# ABOUTME: Exercises the one-command setup against isolated checkouts and homes.
# ABOUTME: Covers deployment, shell configuration, and failures before deployment.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
REPO="$SCRIPT_DIR/.."

stage_checkout() {
    local payload
    CHECKOUT="$TEST_TMPDIR/checkout with spaces"
    PROFILE="$(cd -P "$HOME" && pwd)/.local/share/code-sessions/home"
    OLD_PROFILE="$(cd -P "$HOME" && pwd)/.local/share/agent-sessions/home"
    mkdir -p "$CHECKOUT/bin" "$CHECKOUT/tui" "$TEST_TMPDIR/tools"
    cp "$REPO/setup.sh" "$REPO/build.sh" "$REPO/install.sh.in" "$CHECKOUT/"
    for payload in lib hooks skills mods completions scripts; do
        cp -R "$REPO/$payload" "$CHECKOUT/"
    done
    for payload in cs-secrets cs-codex-thread cs-statusline cs-subagent-statusline; do
        cp "$REPO/bin/$payload" "$CHECKOUT/bin/"
    done
    cp "$REPO/tui/Cargo.toml" "$REPO/tui/Cargo.lock" "$CHECKOUT/tui/"
    # Avoid downloading or compiling dependencies; exercise the wrapper's
    # build invocation and the real installer's selection of the built picker.
    cat > "$TEST_TMPDIR/tools/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CS_SETUP_CARGO_LOG"
[ "${CS_SETUP_CARGO_FAIL:-0}" -eq 0 ] || exit 7
mkdir -p tui/target/release
printf '#!/bin/sh\nprintf "picker fixture\\n"\n' > tui/target/release/cs-tui
chmod +x tui/target/release/cs-tui
EOF
    chmod +x "$TEST_TMPDIR/tools/cargo"
}

run_setup() {
    (
        unset ZDOTDIR CS_INSTALL_ENGINES
        cd "$TEST_TMPDIR"
        PATH="$TEST_TMPDIR/tools:$PATH" SHELL="${TEST_SHELL:-/bin/zsh}" \
            CS_SETUP_CARGO_LOG="$TEST_TMPDIR/cargo.log" \
            sh "$CHECKOUT/setup.sh" "$@"
    ) > "$TEST_TMPDIR/setup.log" 2>&1 || {
        cat "$TEST_TMPDIR/setup.log"
        return 1
    }
}

test_setup_builds_and_installs_both_engines_from_any_directory() {
    stage_checkout
    # The caller's own Codex home must not receive the profile's skills.
    CODEX_HOME="$HOME/user-codex" run_setup || return 1
    assert_eq 'claude,codex' "$(cat "$PROFILE/.local/bin/.cs-install-engines")" || return 1
    assert_file_contains "$TEST_TMPDIR/cargo.log" 'build --release --locked --manifest-path' || return 1
    local tool
    for tool in code-sessions ccs; do
        [ -x "$HOME/.local/bin/$tool" ] || { echo "Missing launcher: $tool"; return 1; }
    done
    for tool in cs cs-secrets cs-codex-thread cs-statusline cs-subagent-statusline cs-tui; do
        [ -x "$PROFILE/.local/bin/$tool" ] && [ ! -L "$PROFILE/.local/bin/$tool" ] \
            || { echo "Missing profile executable: $tool"; return 1; }
    done
    # cs on PATH stays the original's: setup puts nothing of its own there.
    assert_not_exists "$HOME/.local/bin/cs" || return 1
    assert_not_exists "$HOME/.local/bin/ags" || return 1
    assert_eq 'picker fixture' "$("$PROFILE/.local/bin/cs-tui")" || return 1
    jq -e '.hooks.SessionStart | length > 0' "$PROFILE/.claude/settings.json" >/dev/null || return 1
    jq -e 'has("tui") | not' "$PROFILE/.claude/settings.json" >/dev/null || return 1
    # The launcher points CODEX_HOME here, and Codex refuses one that does not exist.
    [ -d "$PROFILE/.codex" ] || { echo "  FAIL: no profile CODEX_HOME"; return 1; }
    assert_eq 700 "$(stat -f '%Lp' "$PROFILE/.codex" 2>/dev/null || stat -c '%a' "$PROFILE/.codex")" || return 1
    assert_file_exists "$PROFILE/.codex/skills/finish/agents/openai.yaml" || return 1
    assert_file_exists "$PROFILE/.claude/skills/finish/agents/openai.yaml" || return 1
    assert_not_exists "$HOME/user-codex" "setup deploys into the profile's CODEX_HOME, not the caller's" || return 1
    assert_not_exists "$HOME/.codex" || return 1
    assert_not_exists "$HOME/.claude" || return 1
    assert_output_contains "$("$HOME/.local/bin/ccs" -version)" '(code-sessions, a fork of cs)' || return 1
    assert_eq "$("$HOME/.local/bin/ccs" -version)" "$("$HOME/.local/bin/code-sessions" -version)" || return 1
    # Test the saved path as a new shell would read it.
    PATH=/usr/bin:/bin /bin/sh -c '. "$HOME/.zshrc"; command -v ccs' > "$TEST_TMPDIR/resolved"
    assert_eq "$HOME/.local/bin/ccs" "$(cat "$TEST_TMPDIR/resolved")"
}

test_setup_reinstall_preserves_user_configuration_and_path_is_unique() {
    stage_checkout
    printf '# my existing settings\n' > "$HOME/.zshrc"
    run_setup || return 1
    run_setup --skip-tui-build || return 1
    assert_file_contains "$HOME/.zshrc" '# my existing settings' || return 1
    assert_eq 1 "$(grep -c '^# >>> code-sessions PATH >>>$' "$HOME/.zshrc")" || return 1
    assert_eq 1 "$(wc -l < "$TEST_TMPDIR/cargo.log" | tr -d ' ')"
}

test_setup_configures_bash_login_and_interactive_shells() {
    stage_checkout
    printf '# keep my login settings\n' > "$HOME/.bash_profile"
    TEST_SHELL=/bin/bash run_setup --skip-tui-build || return 1
    assert_file_contains "$HOME/.bash_profile" '# keep my login settings' || return 1
    assert_file_contains "$HOME/.bash_profile" '# >>> code-sessions PATH >>>' || return 1
    assert_file_contains "$HOME/.bashrc" '# >>> code-sessions PATH >>>' || return 1
    assert_not_exists "$HOME/.profile"
}

test_setup_respects_a_custom_zsh_startup_directory() {
    stage_checkout
    local startup_dir="$HOME/my zsh settings"
    mkdir -p "$startup_dir"
    printf '# my custom zsh settings\n' > "$startup_dir/.zshrc"
    ZDOTDIR="$startup_dir" SHELL=/bin/zsh CS_INSTALL_ENGINES=claude,codex \
        sh "$CHECKOUT/setup.sh" --skip-tui-build > "$TEST_TMPDIR/setup.log" 2>&1 || {
            cat "$TEST_TMPDIR/setup.log"
            return 1
        }
    assert_file_contains "$startup_dir/.zshrc" '# my custom zsh settings' || return 1
    assert_file_contains "$startup_dir/.zshrc" '# >>> code-sessions PATH >>>' || return 1
    assert_not_exists "$HOME/.zshrc"
}

test_setup_reinstall_remembers_a_codex_only_selection() {
    stage_checkout
    SHELL=/bin/sh CS_INSTALL_ENGINES=codex \
        sh "$CHECKOUT/setup.sh" --skip-tui-build > "$TEST_TMPDIR/setup.log" 2>&1 || {
            cat "$TEST_TMPDIR/setup.log"
            return 1
        }
    run_setup --skip-tui-build || return 1
    assert_eq codex "$(cat "$PROFILE/.local/bin/.cs-install-engines")" || return 1
    assert_not_exists "$HOME/.claude" || return 1
    [ -x "$PROFILE/.local/bin/cs-codex-thread" ]
}

# The profile's Claude starts from a fresh config, and Claude Code gives a fresh
# config its fullscreen renderer. That renderer takes trackpad gestures such as
# iTerm2's two-finger tab swipe, so setup carries the user's own choice over.
test_setup_carries_the_users_claude_display_mode_into_the_profile() {
    stage_checkout
    mkdir -p "$HOME/.claude"
    printf '{"tui":"default","theme":"custom:mine"}\n' > "$HOME/.claude/settings.json"
    cp "$HOME/.claude/settings.json" "$TEST_TMPDIR/user-settings"
    run_setup --skip-tui-build || return 1
    assert_eq default "$(jq -r '.tui' "$PROFILE/.claude/settings.json")" || return 1
    # The theme stays the profile's own; the carry-over leaves it too.
    assert_eq null "$(jq -r '.theme' "$PROFILE/.claude/settings.json")" || return 1
    jq -e '.hooks.SessionStart | length > 0' "$PROFILE/.claude/settings.json" >/dev/null || return 1
    cmp "$TEST_TMPDIR/user-settings" "$HOME/.claude/settings.json" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'tui: default'
}

test_setup_keeps_a_display_mode_chosen_inside_the_profile() {
    stage_checkout
    mkdir -p "$HOME/.claude"
    printf '{"tui":"default"}\n' > "$HOME/.claude/settings.json"
    run_setup --skip-tui-build || return 1
    local settings="$PROFILE/.claude/settings.json" chosen
    chosen=$(jq '.tui = "fullscreen"' "$settings") && printf '%s\n' "$chosen" > "$settings"
    run_setup --skip-tui-build || return 1
    assert_eq fullscreen "$(jq -r '.tui' "$settings")"
}

seed_stable_install() {
    local file
    mkdir -p "$HOME/.local/bin" "$HOME/.claude/hooks/cs" "$HOME/.claude/commands" \
        "$HOME/.claude/skills/cs" "$HOME/.config/cs" "$HOME/.cache/cs" \
        "$HOME/.claude-sessions/stable-project/.cs" "$HOME/.bash_completion.d" "$HOME/.zsh/completions"
    for file in cs cs-secrets cs-statusline cs-subagent-statusline cs-codex-thread cs-tui; do
        printf '#!/bin/sh\nprintf "stable %s\\n"\n' "$file" > "$HOME/.local/bin/$file"
        chmod +x "$HOME/.local/bin/$file"
    done
    printf 'claude\n' > "$HOME/.local/bin/.cs-install-engines"
    printf '{"hooks":{"SessionStart":[]},"custom":"keep this"}\n' > "$HOME/.claude/settings.json"
    printf 'stable hook\n' > "$HOME/.claude/hooks/cs/session-start.sh"
    printf 'stable command\n' > "$HOME/.claude/commands/wrap.md"
    printf 'stable mod\n' > "$HOME/.claude/skills/cs/register.tsx"
    printf 'stable preference\n' > "$HOME/.config/cs/statusline-caps"
    printf 'stable cache\n' > "$HOME/.cache/cs/update-check"
    printf 'stable notes\n' > "$HOME/.claude-sessions/stable-project/.cs/summary.md"
    printf 'stable completion\n' > "$HOME/.bash_completion.d/cs.bash"
    printf 'stable completion\n' > "$HOME/.zsh/completions/_cs"
}

stable_snapshot() {
    find "$HOME/.claude" "$HOME/.claude-sessions" "$HOME/.config" "$HOME/.cache" \
        "$HOME/.bash_completion.d" "$HOME/.zsh" "$HOME/.local/bin" \
        \( -path "$HOME/.local/bin/code-sessions" -o -path "$HOME/.local/bin/ccs" \) -prune \
        -o -type f -exec shasum {} \; | sort
}

test_setup_and_reinstall_preserve_the_entire_stable_install() {
    stage_checkout
    seed_stable_install
    stable_snapshot > "$TEST_TMPDIR/before"
    run_setup || return 1
    run_setup --skip-tui-build || return 1
    stable_snapshot > "$TEST_TMPDIR/after"
    cmp "$TEST_TMPDIR/before" "$TEST_TMPDIR/after" || return 1
    assert_eq 'stable cs' "$("$HOME/.local/bin/cs" -version)"
}

test_public_launchers_keep_the_users_home_and_point_tools_at_the_profile() {
    stage_checkout
    seed_stable_install
    run_setup --skip-tui-build || return 1
    cat > "$PROFILE/.local/bin/cs" <<'EOF'
#!/bin/sh
printf '%s\n' "$HOME" "$CLAUDE_CONFIG_DIR" "$CODEX_HOME" "$CS_SESSIONS_ROOT" "$CS_INSTALL_DIR" \
    "$CS_CONFIG_DIR" "$CS_CACHE_DIR" "$CS_DATA_DIR" "$CS_SECRETS_DIR" "${XDG_CONFIG_HOME:-unset}" \
    "${CS_TMUX_SOCKET:-unset}" "${CS_TMUX_SESSION:-unset}" "${CS_SECRETS_BACKEND:-unset}" \
    "${CODE_SESSIONS_HOME:-unset}" "$CS_BIN" "$(command -v cs)"
mkdir -p "$CS_CACHE_DIR"
printf 'experimental cache\n' > "$CS_CACHE_DIR/update-check"
EOF
    chmod +x "$PROFILE/.local/bin/cs"
    local output
    output=$(CS_SESSIONS_ROOT="$HOME/.claude-sessions" CLAUDE_CONFIG_DIR="$HOME/.claude" \
        CODEX_HOME="$HOME/.codex" CS_SECRETS_BACKEND=keychain PATH="$HOME/.local/bin:$PATH" \
        "$HOME/.local/bin/ccs" -version)
    # HOME stays the user's: macOS finds the login keychain through it, and ~/.ssh
    # and the rest of the user's credentials stay visible to the session. Every
    # tool is pointed at the profile through its own directory variable, and the
    # generic XDG roots are left alone so gh, git and friends keep their config.
    # cs -spawn opens its windows on a tmux server of its own, and secrets stay
    # in the profile's encrypted store, out of the keychain's shared cs:<session>
    # namespace, whatever the caller's shell says. Inside, cs is code-sessions:
    # CODE_SESSIONS_HOME says so, and the profile's bin comes first on PATH.
    assert_eq "$HOME"$'\n'"$PROFILE/.claude"$'\n'"$PROFILE/.codex"$'\n'"$PROFILE/sessions"$'\n'"$PROFILE/.local/bin"$'\n'"$PROFILE/.config/cs"$'\n'"$PROFILE/.cache/cs"$'\n'"$PROFILE/.local/share/cs"$'\n'"$PROFILE/.cs-secrets"$'\n'unset$'\n'code-sessions$'\n'code-sessions$'\n'encrypted$'\n'"$PROFILE"$'\n'"$PROFILE/.local/bin/cs"$'\n'"$PROFILE/.local/bin/cs" "$output" || return 1
    assert_eq 'stable cache' "$(cat "$HOME/.cache/cs/update-check")" || return 1
    assert_eq 'experimental cache' "$(cat "$PROFILE/.cache/cs/update-check")" || return 1
    local status=0
    (cd "$HOME/.claude-sessions/stable-project" && "$HOME/.local/bin/ccs" .) \
        > "$TEST_TMPDIR/refusal" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/refusal" 'workspace of the original cs' || return 1
    status=0
    "$HOME/.local/bin/ccs" -update > "$TEST_TMPDIR/refusal" 2>&1 || status=$?
    assert_eq 1 "$status"
}

# A project the profile has by a link in its sessions root keeps its .cs/: the
# directory commands work there, nested folders too.
test_launcher_runs_directory_commands_in_a_project_the_profile_has() {
    stage_checkout
    seed_stable_install
    run_setup --skip-tui-build || return 1
    printf '#!/bin/sh\necho "profile cs $*"\n' > "$PROFILE/.local/bin/cs"
    chmod +x "$PROFILE/.local/bin/cs"
    local project="$TEST_TMPDIR/moved-project"
    mkdir -p "$project/.cs" "$project/src" "$TEST_TMPDIR/other-project/.cs" "$PROFILE/sessions"
    ln -s "$project" "$PROFILE/sessions/moved"
    ln -s "$TEST_TMPDIR/elsewhere" "$PROFILE/sessions/dangling"
    local output
    output=$(cd "$project/src" && "$HOME/.local/bin/ccs" -checkpoint list) || return 1
    assert_eq 'profile cs -checkpoint list' "$output" || return 1
    output=$(cd "$project" && "$HOME/.local/bin/ccs" .) || return 1
    assert_eq 'profile cs .' "$output" || return 1
    local status=0
    (cd "$TEST_TMPDIR/other-project" && "$HOME/.local/bin/ccs" .) > "$TEST_TMPDIR/refusal" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/refusal" 'scripts/cs-to-code-sessions.py'
}

test_setup_registers_profile_hooks_by_absolute_path() {
    stage_checkout
    seed_stable_install
    run_setup --skip-tui-build || return 1
    # The launcher keeps the user's HOME, so a `~/.claude/hooks/cs/...` command
    # would run the stable install's hooks: every registration names the
    # profile's own file, and a reinstall replaces rather than duplicates it.
    local commands cmd
    commands=$(jq -r '.hooks[][] | .hooks[]?.command' "$PROFILE/.claude/settings.json" | sort -u)
    [ -n "$commands" ] || { echo "  FAIL: no hook commands registered"; return 1; }
    local dir
    while IFS= read -r cmd; do
        case "$cmd" in
            /*.sh) ;;
            *) echo "  FAIL: hook command is not an absolute path: $cmd"; return 1 ;;
        esac
        [ -f "$cmd" ] || { echo "  FAIL: $cmd is registered but not deployed"; return 1; }
        # The installer spells the path as HOME was given; PROFILE is physical.
        dir=$(cd -P "$(dirname "$cmd")" && pwd)
        [ "$dir" = "$PROFILE/.claude/hooks/cs" ] || { echo "  FAIL: hook command is outside the profile: $cmd"; return 1; }
    done <<< "$commands"
    run_setup --skip-tui-build || return 1
    assert_eq 1 "$(jq '[.hooks[][] | .hooks[]?.command | select(endswith("/session-start.sh"))] | length' "$PROFILE/.claude/settings.json")"
}

test_direct_installer_refuses_to_replace_original_cs() {
    stage_checkout
    seed_stable_install
    (cd "$CHECKOUT" && bash build.sh) >/dev/null || return 1
    local status=0
    SHELL=/bin/sh bash "$CHECKOUT/install.sh" > "$TEST_TMPDIR/refusal" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/refusal" 'The original cs is installed' || return 1
    assert_eq 'stable cs' "$("$HOME/.local/bin/cs" -version)"
}

test_public_launcher_creates_a_first_session_in_the_private_profile() {
    stage_checkout
    seed_stable_install
    stable_snapshot > "$TEST_TMPDIR/before"
    run_setup --skip-tui-build || return 1
    cat > "$TEST_TMPDIR/tools/claude-fixture" <<'EOF'
#!/bin/sh
printf '%s\n' "$PWD" "$HOME" "$CLAUDE_CONFIG_DIR" > "$CS_LAUNCH_LOG"
EOF
    chmod +x "$TEST_TMPDIR/tools/claude-fixture"
    CLAUDE_CODE_BIN="$TEST_TMPDIR/tools/claude-fixture" CS_LAUNCH_LOG="$TEST_TMPDIR/launch.log" \
        "$HOME/.local/bin/ccs" first-test-session --engine claude > "$TEST_TMPDIR/launch-output" 2>&1 || {
            cat "$TEST_TMPDIR/launch-output"
            return 1
        }
    assert_dir "$PROFILE/sessions/first-test-session/.cs" || return 1
    # The claude the launcher starts keeps the user's HOME and reads its
    # configuration from the profile.
    assert_eq "$PROFILE/sessions/first-test-session"$'\n'"$HOME"$'\n'"$PROFILE/.claude" "$(cat "$TEST_TMPDIR/launch.log")" || return 1
    assert_not_exists "$PROFILE/.claude-sessions" || return 1
    stable_snapshot > "$TEST_TMPDIR/after"
    cmp "$TEST_TMPDIR/before" "$TEST_TMPDIR/after"
}

# Claude's transcript folder name for a working directory: every character
# but a letter or digit becomes '-'.
claude_project_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# An earlier build kept the profile's sessions in .claude-sessions: a session
# directory, a symlinked one, a worktree whose repository is a session beside
# it, and a worktree of a repository outside the root.
seed_old_profile_sessions() {
    local home old
    home=$(cd -P "$HOME" && pwd)
    old="$PROFILE/.claude-sessions"
    mkdir -p "$old/ask/.cs" "$home/work/linked/.cs" "$PROFILE/.codex" || return 1
    printf 'ask notes\n' > "$old/ask/.cs/summary.md"
    ln -s "$home/work/linked" "$old/linked"
    git init -q "$old/base" && git -C "$old/base" commit -q --allow-empty -m init \
        && git -C "$old/base" worktree add -q -b task "$old/base@task" || return 1
    git init -q "$home/work/ext" && git -C "$home/work/ext" commit -q --allow-empty -m init \
        && git -C "$home/work/ext" worktree add -q -b feature "$old/ext@feature" || return 1
    local dir
    for dir in "$old/ask" "$old/base@task" "$home/work/linked"; do
        mkdir -p "$PROFILE/.claude/projects/$(claude_project_key "$dir")"
        printf '{}\n' > "$PROFILE/.claude/projects/$(claude_project_key "$dir")/transcript.jsonl"
    done
    jq -n --arg ask "$old/ask" --arg linked "$home/work/linked" \
        '{other: 1, projects: {($ask): {hasTrustDialogAccepted: true}, ($linked): {hasTrustDialogAccepted: true}}}' \
        > "$PROFILE/.claude/.claude.json"
    printf '[projects."%s"]\ntrust_level = "trusted"\n\n[projects."%s"]\ntrust_level = "trusted"\n' \
        "$old/ask" "$home/work/linked" > "$PROFILE/.codex/config.toml"
}

# scripts/carry-over.sh has its own suite; these pin how setup runs it.
test_setup_carries_the_users_own_setup_unless_opted_out() {
    stage_checkout
    mkdir -p "$HOME/.claude/skills/my-skill"
    printf 'mine\n' > "$HOME/.claude/skills/my-skill/SKILL.md"
    run_setup --skip-tui-build --no-carry-over || return 1
    assert_not_exists "$PROFILE/.claude/skills/my-skill" "--no-carry-over" || return 1
    CS_CARRY_OVER=0 run_setup --skip-tui-build || return 1
    assert_not_exists "$PROFILE/.claude/skills/my-skill" "CS_CARRY_OVER=0" || return 1
    run_setup --skip-tui-build || return 1
    assert_eq "$HOME/.claude/skills/my-skill" "$(readlink "$PROFILE/.claude/skills/my-skill")" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'linked claude/skills/my-skill'
}

# A link an earlier carry-over made to a skill of the user's, before
# code-sessions shipped one of that name: the install must not copy its files
# through it.
test_setup_never_installs_through_a_carried_link() {
    stage_checkout
    mkdir -p "$HOME/.claude/skills/finish"
    printf 'my own finish\n' > "$HOME/.claude/skills/finish/SKILL.md"
    run_setup --skip-tui-build || return 1
    rm -rf "$PROFILE/.claude/skills/finish"
    ln -s "$HOME/.claude/skills/finish" "$PROFILE/.claude/skills/finish"
    run_setup --skip-tui-build --no-carry-over || return 1
    assert_eq 'my own finish' "$(cat "$HOME/.claude/skills/finish/SKILL.md")" || return 1
    assert_not_exists "$HOME/.claude/skills/finish/agents" || return 1
    [ -d "$PROFILE/.claude/skills/finish" ] && [ ! -L "$PROFILE/.claude/skills/finish" ] \
        || { echo "  FAIL: the profile's finish is not its own directory"; return 1; }
    assert_file_exists "$PROFILE/.claude/skills/finish/agents/openai.yaml"
}

test_setup_moves_an_existing_profile_sessions_root() {
    stage_checkout
    seed_old_profile_sessions || return 1
    local home new projects
    home=$(cd -P "$HOME" && pwd)
    new="$PROFILE/sessions" projects="$PROFILE/.claude/projects"
    run_setup --skip-tui-build || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'Moved the profile sessions' || return 1
    assert_not_exists "$PROFILE/.claude-sessions" || return 1
    assert_eq 'ask notes' "$(cat "$new/ask/.cs/summary.md")" || return 1
    assert_eq "$home/work/linked" "$(readlink "$new/linked")" || return 1
    # Transcripts follow the directories that moved; a symlinked session's stay.
    assert_file_exists "$projects/$(claude_project_key "$new/ask")/transcript.jsonl" || return 1
    assert_file_exists "$projects/$(claude_project_key "$new/base@task")/transcript.jsonl" || return 1
    assert_file_exists "$projects/$(claude_project_key "$home/work/linked")/transcript.jsonl" || return 1
    assert_not_exists "$projects/$(claude_project_key "$PROFILE/.claude-sessions/ask")" || return 1
    # Both worktrees stay connected to their repositories.
    assert_eq task "$(git -C "$new/base@task" rev-parse --abbrev-ref HEAD)" || return 1
    git -C "$new/base" worktree list --porcelain | grep -Fqx "worktree $new/base@task" \
        || { echo "  FAIL: base does not list its moved worktree"; return 1; }
    assert_eq feature "$(git -C "$new/ext@feature" rev-parse --abbrev-ref HEAD)" || return 1
    git -C "$home/work/ext" worktree list --porcelain | grep -Fqx "worktree $new/ext@feature" \
        || { echo "  FAIL: ext does not list its moved worktree"; return 1; }
    # Trust follows the moved directory and nothing else.
    assert_eq "$(printf '%s\n' "$home/work/linked" "$new/ask" | LC_ALL=C sort)" \
        "$(jq -r '.projects | keys[]' "$PROFILE/.claude/.claude.json" | LC_ALL=C sort)" || return 1
    assert_eq 1 "$(jq -r '.other' "$PROFILE/.claude/.claude.json")" || return 1
    grep -Fqx "[projects.\"$new/ask\"]" "$PROFILE/.codex/config.toml" \
        && grep -Fqx "[projects.\"$home/work/linked\"]" "$PROFILE/.codex/config.toml" \
        || { cat "$PROFILE/.codex/config.toml"; echo "  FAIL: Codex trust not moved"; return 1; }
    # A rerun finds nothing left to move.
    run_setup --skip-tui-build || return 1
    assert_file_not_contains "$TEST_TMPDIR/setup.log" 'Moved the profile sessions' || return 1
    assert_eq 'ask notes' "$(cat "$new/ask/.cs/summary.md")"
}

test_setup_does_not_move_sessions_while_a_profile_command_runs() {
    stage_checkout
    mkdir -p "$PROFILE/.claude-sessions/ask/.cs" "$PROFILE/.local/bin"
    printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$PROFILE/.local/bin/cs"
    chmod +x "$PROFILE/.local/bin/cs"
    "$PROFILE/.local/bin/cs" ask &
    local pid=$! tries=0 status=0
    until ps -p "$pid" -o command= | grep -Fq "$PROFILE/.local/bin/cs"; do
        tries=$((tries + 1))
        [ "$tries" -lt 50 ] || { kill "$pid"; echo "  FAIL: fixture never started"; return 1; }
        sleep 0.1
    done
    run_setup --skip-tui-build > /dev/null || status=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" "^ *$pid .*/.local/bin/cs ask" || return 1
    assert_dir "$PROFILE/.claude-sessions/ask/.cs" || return 1
    assert_not_exists "$PROFILE/sessions" || return 1
    # Refused before the build, so nothing was deployed.
    assert_not_exists "$CHECKOUT/bin/cs" || return 1
    assert_not_exists "$HOME/.local/bin/ccs"
}

test_setup_does_not_merge_two_sessions_roots() {
    stage_checkout
    mkdir -p "$PROFILE/.claude-sessions/old-one/.cs" "$PROFILE/sessions/new-one/.cs"
    local status=0
    run_setup --skip-tui-build > /dev/null || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'Both .* exist' || return 1
    assert_dir "$PROFILE/.claude-sessions/old-one/.cs" || return 1
    assert_dir "$PROFILE/sessions/new-one/.cs" || return 1
    assert_not_exists "$PROFILE/sessions/old-one"
}

# Before the rename the fork was ags, with its profile in
# ~/.local/share/agent-sessions/home and ags launchers in ~/.local/bin.
seed_ags_profile() {
    local home old
    home=$(cd -P "$HOME" && pwd)
    old="$OLD_PROFILE"
    mkdir -p "$old/.local/bin" "$old/sessions/ask/.cs" "$home/work/linked/.cs" "$old/.codex" \
        "$old/.claude/hooks/cs" "$old/.cs-secrets" "$old/.zsh/completions" "$old/.cache/cs/git" || return 1
    printf '#!/bin/sh\necho old ags\n' > "$old/.local/bin/ags"
    printf '#!/bin/sh\necho old statusline\n' > "$old/.local/bin/ags-statusline"
    chmod +x "$old/.local/bin/ags" "$old/.local/bin/ags-statusline"
    ln -s ags "$old/.local/bin/cs"
    ln -s ags-statusline "$old/.local/bin/cs-statusline"
    printf 'claude,codex\n' > "$old/.local/bin/.cs-install-engines"
    printf 'old completion\n' > "$old/.zsh/completions/_ags"
    printf 'ask notes\n' > "$old/sessions/ask/.cs/summary.md"
    ln -s "$home/work/linked" "$old/sessions/linked"
    # The protocol said ags; what the user wrote above it is theirs.
    cat > "$old/sessions/ask/CLAUDE.local.md" <<'EOF'
My notes: try `ags -secrets` here first.
<!-- cs:session-protocol -->
This is a Claude Code session managed by agent-sessions (ags). Session metadata lives in the .cs/ directory.
`ags -conversations` shows the session's conversation chain.
Secrets live in the ags session store, never in a project file. `ags -secrets set`
Consume a secret inline — `some-command --token "$(ags -secrets get API_KEY)"` —
Claude's built-in memory writes durable facts to `.cs/memory/` (ags redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`)
keep the `cs:wrap-cues` HTML comment as a tombstone — ags treats the sentinel's presence as "managed, do not re-add."
<!-- cs:wrap-cues -->
EOF
    printf '<!-- cs:session-protocol -->\nmanaged by agent-sessions (ags).\n' > "$home/work/linked/CLAUDE.local.md"
    printf 'sealed\n' > "$old/.cs-secrets/ask.enc"
    printf 'stale\n' > "$old/.cache/cs/git/$(claude_project_key "$old/sessions/ask")"
    mkdir -p "$old/.claude/projects/$(claude_project_key "$old/sessions/ask")"
    printf '{}\n' > "$old/.claude/projects/$(claude_project_key "$old/sessions/ask")/transcript.jsonl"
    # The old install wrote its hooks under HOME as setup spelled it, maybe a
    # symlinked spelling; Claude keys trust and transcripts by the physical path.
    local installed="$HOME/.local/share/agent-sessions/home"
    jq -n --arg sl "$installed/.local/bin/ags-statusline" --arg hook "$installed/.claude/hooks/cs/session-start.sh" \
        '{statusLine: {type: "command", command: $sl},
          hooks: {SessionStart: [{hooks: [{type: "command", command: $hook}]}]}}' \
        > "$old/.claude/settings.json"
    jq -n --arg ask "$old/sessions/ask" --arg linked "$home/work/linked" \
        '{other: 1, projects: {($ask): {hasTrustDialogAccepted: true}, ($linked): {hasTrustDialogAccepted: true}}}' \
        > "$old/.claude/.claude.json"
    printf '[projects."%s"]\ntrust_level = "trusted"\n' "$old/sessions/ask" > "$old/.codex/config.toml"
    jq -n --arg c "$installed/.local/bin/ags -codex-hook session-start" \
        '{hooks: {SessionStart: [{hooks: [{type: "command", command: $c}]}]}}' > "$old/.codex/hooks.json"
    printf '{"carried": true}\n' > "$old/.codex/.ags-carried-hooks.json"
    printf '{"display":"hi","project":"%s"}\n' "$old/sessions/ask" > "$old/.claude/history.jsonl"
    mkdir -p "$HOME/.local/bin"
    local name
    for name in ags ags-tui; do
        printf '#!/bin/sh\nprofile_home=$(cd -P "$(dirname "$0")/../share/agent-sessions/home" && pwd)\n' \
            > "$HOME/.local/bin/$name"
        chmod +x "$HOME/.local/bin/$name"
    done
    printf '#!/bin/sh\necho mine\n' > "$HOME/.local/bin/ags-mine"
    chmod +x "$HOME/.local/bin/ags-mine"
}

test_setup_moves_the_ags_profile_over() {
    stage_checkout
    seed_stable_install
    seed_ags_profile || return 1
    stable_snapshot | grep -v -e '/\.local/bin/ags' > "$TEST_TMPDIR/before"
    local home new old
    home=$(cd -P "$HOME" && pwd)
    new="$PROFILE" old="$OLD_PROFILE"
    run_setup --skip-tui-build || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'Moved the ags profile' || return 1
    assert_not_exists "$old" || return 1
    assert_not_exists "$(dirname "$old")" "the emptied agent-sessions folder goes too" || return 1
    # Sessions, links, secrets and engines came along.
    assert_eq 'ask notes' "$(cat "$new/sessions/ask/.cs/summary.md")" || return 1
    assert_eq "$home/work/linked" "$(readlink "$new/sessions/linked")" || return 1
    assert_eq sealed "$(cat "$new/.cs-secrets/ask.enc")" || return 1
    assert_eq 'claude,codex' "$(cat "$new/.local/bin/.cs-install-engines")" || return 1
    # The commands are cs's now, real files, and nothing named ags is left.
    [ -f "$new/.local/bin/cs" ] && [ ! -L "$new/.local/bin/cs" ] || { echo "  FAIL: profile cs is not its own file"; return 1; }
    grep -q '^CS_FORK="code-sessions"' "$new/.local/bin/cs" || { echo "  FAIL: profile cs is not code-sessions"; return 1; }
    assert_not_exists "$new/.local/bin/ags" || return 1
    assert_not_exists "$new/.local/bin/ags-statusline" || return 1
    assert_not_exists "$new/.zsh/completions/_ags" || return 1
    assert_not_exists "$new/.cache/cs/git" || return 1
    # Transcripts and trust follow the session's new path.
    assert_file_exists "$new/.claude/projects/$(claude_project_key "$new/sessions/ask")/transcript.jsonl" || return 1
    assert_not_exists "$new/.claude/projects/$(claude_project_key "$old/sessions/ask")" || return 1
    assert_eq "$(printf '%s\n' "$home/work/linked" "$new/sessions/ask" | LC_ALL=C sort)" \
        "$(jq -r '.projects | keys[]' "$new/.claude/.claude.json" | LC_ALL=C sort)" || return 1
    assert_eq 1 "$(jq -r '.other' "$new/.claude/.claude.json")" || return 1
    grep -Fqx "[projects.\"$new/sessions/ask\"]" "$new/.codex/config.toml" \
        || { cat "$new/.codex/config.toml"; echo "  FAIL: Codex trust not moved"; return 1; }
    assert_eq "$new/sessions/ask" "$(jq -r '.project' "$new/.claude/history.jsonl")" || return 1
    # The session protocol says cs now, in a linked session's own folder too.
    cat > "$TEST_TMPDIR/protocol" <<'EOF'
My notes: try `ags -secrets` here first.
<!-- cs:session-protocol -->
This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
`cs -conversations` shows the session's conversation chain.
Secrets live in the cs session store, never in a project file. `cs -secrets set`
Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —
Claude's built-in memory writes durable facts to `.cs/memory/` (cs redirects via `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE`)
keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
<!-- cs:wrap-cues -->
EOF
    cmp "$TEST_TMPDIR/protocol" "$new/sessions/ask/CLAUDE.local.md" || return 1
    assert_eq "$(printf '<!-- cs:session-protocol -->\nmanaged by the cs tool.')" \
        "$(cat "$home/work/linked/CLAUDE.local.md")" || return 1
    # No file names the old profile; the hooks are registered once, by the new path.
    local leftover
    leftover=$(grep -rlF -e "$old" -e "$HOME/.local/share/agent-sessions" "$new/.claude/settings.json" \
        "$new/.claude/.claude.json" "$new/.codex/hooks.json" "$new/.codex/config.toml" 2>/dev/null || true)
    [ -z "$leftover" ] || { echo "  FAIL: still naming the old profile: $leftover"; return 1; }
    # install.sh registers its status line under HOME as setup spells it, which
    # may be a symlinked spelling of the same directory.
    local status_line
    status_line=$(jq -r '.statusLine.command' "$new/.claude/settings.json")
    assert_eq "$new/.local/bin/cs-statusline" \
        "$(cd -P "$(dirname "$status_line")" 2>/dev/null && pwd)/${status_line##*/}" || return 1
    assert_eq 1 "$(jq '[.hooks[][] | .hooks[]?.command | select(endswith("/session-start.sh"))] | length' "$new/.claude/settings.json")" || return 1
    assert_eq 1 "$(jq '[.hooks.SessionStart[] | .hooks[]?.command | select(test("-codex-hook session-start"))] | length' "$new/.codex/hooks.json")" || return 1
    assert_file_exists "$new/.codex/.carried-hooks.json" || return 1
    assert_not_exists "$new/.codex/.ags-carried-hooks.json" || return 1
    # The old launchers go; a file of the user's that only shares the prefix stays,
    # and so does the original cs.
    assert_not_exists "$HOME/.local/bin/ags" || return 1
    assert_not_exists "$HOME/.local/bin/ags-tui" || return 1
    assert_eq mine "$("$HOME/.local/bin/ags-mine")" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" "Removed the old launcher $HOME/.local/bin/ags" || return 1
    stable_snapshot | grep -v -e '/\.local/bin/ags' > "$TEST_TMPDIR/after"
    cmp "$TEST_TMPDIR/before" "$TEST_TMPDIR/after" || return 1
    # A rerun finds nothing left to move.
    run_setup --skip-tui-build || return 1
    assert_file_not_contains "$TEST_TMPDIR/setup.log" 'Moved the ags profile' || return 1
    assert_eq 'ask notes' "$(cat "$new/sessions/ask/.cs/summary.md")"
}

test_setup_does_not_move_the_ags_profile_while_it_runs() {
    stage_checkout
    seed_ags_profile || return 1
    printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$OLD_PROFILE/.local/bin/ags"
    "$OLD_PROFILE/.local/bin/ags" ask &
    local pid=$! tries=0 status=0
    until ps -p "$pid" -o command= | grep -Fq "$OLD_PROFILE/.local/bin/ags"; do
        tries=$((tries + 1))
        [ "$tries" -lt 50 ] || { kill "$pid"; echo "  FAIL: fixture never started"; return 1; }
        sleep 0.1
    done
    run_setup --skip-tui-build > /dev/null || status=$?
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" "^ *$pid .*/.local/bin/ags ask" || return 1
    assert_eq 'ask notes' "$(cat "$OLD_PROFILE/sessions/ask/.cs/summary.md")" || return 1
    assert_not_exists "$PROFILE" || return 1
    # Refused before the build, so nothing was deployed.
    assert_not_exists "$CHECKOUT/bin/cs" || return 1
    assert_not_exists "$HOME/.local/bin/ccs"
}

test_setup_does_not_merge_the_ags_profile_into_an_existing_one() {
    stage_checkout
    seed_ags_profile || return 1
    mkdir -p "$PROFILE/sessions/new-one/.cs"
    local status=0
    run_setup --skip-tui-build > /dev/null || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'Both .* exist' || return 1
    assert_dir "$OLD_PROFILE/sessions/ask/.cs" || return 1
    assert_dir "$PROFILE/sessions/new-one/.cs" || return 1
    assert_not_exists "$PROFILE/sessions/ask"
}

test_setup_missing_dependency_stops_before_install_or_shell_changes() {
    stage_checkout
    local dependency status=0
    mkdir -p "$TEST_TMPDIR/restricted-path"
    for dependency in dirname bash git python3; do
        ln -s "$(command -v "$dependency")" "$TEST_TMPDIR/restricted-path/$dependency"
    done
    PATH="$TEST_TMPDIR/restricted-path" CS_INSTALL_ENGINES=claude,codex \
        /bin/sh "$CHECKOUT/setup.sh" > "$TEST_TMPDIR/setup.log" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/setup.log" 'prerequisites.*jq' || return 1
    assert_not_exists "$HOME/.local/bin" || return 1
    assert_not_exists "$HOME/.zshrc" || return 1
    assert_not_exists "$CHECKOUT/bin/cs"
}

test_setup_failed_picker_build_stops_before_deployment() {
    stage_checkout
    local status=0
    PATH="$TEST_TMPDIR/tools:$PATH" CS_INSTALL_ENGINES=claude,codex \
        CS_SETUP_CARGO_LOG="$TEST_TMPDIR/cargo.log" CS_SETUP_CARGO_FAIL=1 \
        sh "$CHECKOUT/setup.sh" > "$TEST_TMPDIR/setup.log" 2>&1 || status=$?
    assert_eq 7 "$status" || return 1
    assert_not_exists "$HOME/.local/bin" || return 1
    assert_not_exists "$HOME/.zshrc"
}

run_test test_setup_builds_and_installs_both_engines_from_any_directory
run_test test_setup_reinstall_preserves_user_configuration_and_path_is_unique
run_test test_setup_configures_bash_login_and_interactive_shells
run_test test_setup_respects_a_custom_zsh_startup_directory
run_test test_setup_reinstall_remembers_a_codex_only_selection
run_test test_setup_carries_the_users_claude_display_mode_into_the_profile
run_test test_setup_keeps_a_display_mode_chosen_inside_the_profile
run_test test_setup_carries_the_users_own_setup_unless_opted_out
run_test test_setup_never_installs_through_a_carried_link
run_test test_setup_moves_an_existing_profile_sessions_root
run_test test_setup_does_not_move_sessions_while_a_profile_command_runs
run_test test_setup_does_not_merge_two_sessions_roots
run_test test_setup_moves_the_ags_profile_over
run_test test_setup_does_not_move_the_ags_profile_while_it_runs
run_test test_setup_does_not_merge_the_ags_profile_into_an_existing_one
run_test test_setup_missing_dependency_stops_before_install_or_shell_changes
run_test test_setup_failed_picker_build_stops_before_deployment
run_test test_setup_and_reinstall_preserve_the_entire_stable_install
run_test test_public_launchers_keep_the_users_home_and_point_tools_at_the_profile
run_test test_launcher_runs_directory_commands_in_a_project_the_profile_has
run_test test_setup_registers_profile_hooks_by_absolute_path
run_test test_direct_installer_refuses_to_replace_original_cs
run_test test_public_launcher_creates_a_first_session_in_the_private_profile
report_results
