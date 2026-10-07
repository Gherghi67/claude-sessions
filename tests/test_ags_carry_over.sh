#!/usr/bin/env bash
# ABOUTME: Exercises scripts/ags-carry-over.sh against a fake ~/.claude, ~/.codex and ags profile.
# ABOUTME: Covers links, skips, merges, reruns, Codex hook trust, the sidebar bridge and secrecy.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
CARRY="$REPO/scripts/ags-carry-over.sh"
# shellcheck source=lib/01-manifests.sh
source "$REPO/lib/01-manifests.sh"

CLAUDE_SECRET=FIXTURE-SECRET-CLAUDE-7f3a
CODEX_SECRET=FIXTURE-SECRET-CODEX-91bd

# Codex's trust hash, computed apart from the script under test: sha256 of
# the handler group's compact sorted-key JSON, Codex's defaults filled in.
codex_hash() {  # event_name, command, [timeout], [matcher]
    /usr/bin/python3 -c '
import hashlib, json, sys
d = {"event_name": sys.argv[1], "hooks": [{"async": False, "command": sys.argv[2],
     "timeout": int(sys.argv[3]), "type": "command"}]}
if sys.argv[4]:
    d["matcher"] = sys.argv[4]
print(hashlib.sha256(json.dumps(d, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
' "$1" "$2" "${3:-600}" "${4:-}"
}

# The trusted_hash a config.toml holds for one hook key, or nothing.
trusted() {  # config, key
    awk -v h="[hooks.state.\"$2\"]" '$0 == h {getline; sub(/^[^"]*"/, ""); sub(/".*/, ""); print}' "$1"
}

# Trust a hook in a config.toml the way Codex records a review: a key trusted
# before is trusted anew, never twice.
trust() {  # config, key, hash
    awk -v h="[hooks.state.\"$2\"]" '$0 == h { skip = 1; next } skip && /^\[/ { skip = 0 } !skip' "$1" > "$1.tmp" \
        && mv "$1.tmp" "$1"
    printf '\n[hooks.state."%s"]\ntrusted_hash = "sha256:%s"\n' "$2" "$3" >> "$1"
    assert_eq 1 "$(grep -c -F "[hooks.state.\"$2\"]" "$1")" "one trust table for $2"
}

# Rewrite a JSON file through a jq filter.
jq_edit() {  # file, filter
    jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# What setup.sh leaves: ags's own skills and mods, hooks, status line, a
# Codex hook it trusts, and a few entries of the profile's own.
seed_profile() {
    PROFILE="$HOME/.local/share/agent-sessions/home"
    local skill
    mkdir -p "$PROFILE/.local/bin" "$PROFILE/.claude/commands" "$PROFILE/.claude/plugins" \
        "$PROFILE/.claude/skills/cs/.claude-plugin" "$PROFILE/.codex/skills"
    printf 'claude,codex\n' > "$PROFILE/.local/bin/.cs-install-engines"
    for skill in "${CS_SKILLS[@]}"; do
        mkdir -p "$PROFILE/.claude/skills/$skill" "$PROFILE/.codex/skills/$skill"
        printf 'ags %s\n' "$skill" > "$PROFILE/.claude/skills/$skill/SKILL.md"
        printf 'ags %s\n' "$skill" > "$PROFILE/.codex/skills/$skill/SKILL.md"
    done
    jq -n --arg p "$PROFILE" '{
        model: "opus", theme: "dark", effortLevel: "high",
        statusLine: {type: "command", command: "\($p)/.local/bin/ags-statusline", refreshInterval: 60},
        hooks: {SessionStart: [{hooks: [{type: "command", command: "\($p)/.claude/hooks/cs/session-start.sh", timeout: 30}]}]},
        enabledPlugins: {"clangd-lsp@official": true}}' > "$PROFILE/.claude/settings.json"
    printf '{"numStartups":3,"mcpServers":{"profile-own":{"type":"stdio","command":"/bin/echo"}}}\n' \
        > "$PROFILE/.claude/.claude.json"
    chmod 600 "$PROFILE/.claude/.claude.json"
    jq -n --arg p "$PROFILE" '{version: 2, plugins: {"clangd-lsp@official": [{scope: "user",
        installPath: "\($p)/.claude/plugins/cache/official/clangd-lsp/1.0.0", version: "1.0.0"}]}}' \
        > "$PROFILE/.claude/plugins/installed_plugins.json"
    printf '[tui]\nscreen_reader_detection_done = true\n\n[mcp_servers.profile-own]\ncommand = "/bin/echo"\n' \
        > "$PROFILE/.codex/config.toml"
    _codex_hooks_register "$PROFILE/.codex" "$(_codex_hook_command "$PROFILE/.local/bin/ags")"
}

# The user's own setup, with something of every kind the carry-over sorts:
# entries to link, names ags installs, backups, cs hooks, secrets.
seed_user() {
    local U="$HOME/.claude" X="$HOME/.codex" name
    mkdir -p "$U/agents" "$U/commands" "$U/skills/my-skill" "$U/skills/finish" "$U/skills/cs" \
        "$U/skills/synced" "$U/skills/.trash" "$U/workflows" "$U/themes" \
        "$U/plugins/cache/official/tool/1.0.0/.claude-plugin" "$U/plugins/marketplaces/official" \
        "$X/skills/codex-skill" "$X/skills/wrap" "$X/agents"
    printf 'my instructions\n' > "$U/CLAUDE.md"
    printf 'agent\n' > "$U/agents/helper.md"
    printf 'old\n' > "$U/agents/helper.md.pre-edit"
    printf 'mine\n' > "$U/commands/mine.md"
    printf 'old\n' > "$U/commands/mine.md.pre-any-session"
    for name in "${RETIRED_COMMANDS[@]}"; do printf 'stable cs\n' > "$U/commands/$name"; done
    printf 'my skill\n' > "$U/skills/my-skill/SKILL.md"
    # Backups of a skill are directories too: only the name gives them away.
    mkdir -p "$U/skills/my-skill.pre-move" "$U/skills/my-skill.bak" "$X/skills/codex-skill.before-edit"
    printf 'old\n' > "$U/skills/my-skill.pre-move/SKILL.md"
    printf 'old\n' > "$U/skills/my-skill.bak/SKILL.md"
    printf 'old\n' > "$X/skills/codex-skill.before-edit/SKILL.md"
    printf 'stable finish\n' > "$U/skills/finish/SKILL.md"
    printf 'flow\n' > "$U/workflows/flow.js"
    printf '{}\n' > "$U/themes/mine.json"
    jq -n '{model: "sonnet", theme: "light", tui: "default", effortLevel: "xhigh",
        alwaysThinkingEnabled: true, disableAllHooks: true,
        permissions: {defaultMode: "auto", allow: ["Bash(ls:*)"]},
        hooks: {SessionStart: [{hooks: [{type: "command", command: "~/.claude/hooks/cs/session-start.sh"}]}],
                UserPromptSubmit: [{hooks: [{type: "command", command: "/opt/bin/hinter hint", timeout: 5}]}]},
        enabledPlugins: {"tool@official": true, "clangd-lsp@official": false},
        statusLine: {type: "command", command: "/opt/sidebar/plugin/statusline-bridge.sh", refreshInterval: 1}}' \
        > "$U/settings.json"
    jq -n --arg s "$CLAUDE_SECRET" '{numStartups: 99, mcpServers: {
        remote: {type: "http", url: "https://mcp.example.test/x", headers: {Authorization: "Bearer \($s)"}},
        "profile-own": {type: "stdio", command: "/bin/false"}}}' > "$HOME/.claude.json"
    printf '{"name":"tool"}\n' > "$U/plugins/cache/official/tool/1.0.0/.claude-plugin/plugin.json"
    printf 'catalog\n' > "$U/plugins/marketplaces/official/marketplace.json"
    jq -n --arg u "$U" '{version: 2, plugins: {"tool@official": [{scope: "user",
        installPath: "\($u)/plugins/cache/official/tool/1.0.0", version: "1.0.0"}]}}' \
        > "$U/plugins/installed_plugins.json"
    jq -n --arg u "$U" '{official: {source: {source: "github", repo: "example/official"},
        installLocation: "\($u)/plugins/marketplaces/official"}}' > "$U/plugins/known_marketplaces.json"
    printf 'codex instructions\n' > "$X/AGENTS.md"
    printf 'codex skill\n' > "$X/skills/codex-skill/SKILL.md"
    printf 'stable wrap\n' > "$X/skills/wrap/SKILL.md"
    printf 'name = "helper"\n' > "$X/agents/helper.toml"
    jq -n '{hooks: {
        SessionStart: [{hooks: [{type: "command", command: "/opt/bin/emit SessionStart"}]}],
        Stop: [{hooks: [{type: "command", command: "/opt/bin/emit Stop", timeout: 10}]}],
        SessionEnd: [{hooks: [{type: "command", command: "/opt/bin/emit SessionEnd", timeout: 10}]}]}}' > "$X/hooks.json"
    {
        printf 'model = "gpt"\n\n[mcp_servers.remote]\nurl = "https://mcp.example.test/codex"\n\n'
        printf '[mcp_servers.remote.env]\nTOKEN = "%s"\n\n' "$CODEX_SECRET"
        printf '[mcp_servers.profile-own]\ncommand = "/bin/false"\n\n'
        printf '[mcp_servers.local]\ncommand = "node"\nargs = [\n  "server.js",\n  "[not a header]",\n]\n\n'
        printf '[sandbox_workspace_write]\nwritable_roots = ["/tmp/sidebar-tasks"]\n\n'
        printf '[hooks.state."%s:session_start:0:0"]\ntrusted_hash = "sha256:%s"\n\n' \
            "$X/hooks.json" "$(codex_hash session_start "/opt/bin/emit SessionStart")"
        # Codex holds a SessionEnd hook to 3 seconds and hashes that.
        printf '[hooks.state."%s:session_end:0:0"]\ntrusted_hash = "sha256:%s"\n' \
            "$X/hooks.json" "$(codex_hash session_end "/opt/bin/emit SessionEnd" 3)"
    } > "$X/config.toml"
}

seed() {
    seed_profile
    seed_user
}

carry() {  # args...
    bash "$CARRY" "$@" > "$TEST_TMPDIR/carry.out" 2>&1 || { cat "$TEST_TMPDIR/carry.out"; return 1; }
}

# Every file and link under the profile, with content hashes and link targets.
profile_snapshot() {
    (cd "$PROFILE" && find . \( -type f -o -type l \) | sort | while IFS= read -r f; do
        if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"
        else printf 'F %s %s\n' "$f" "$(shasum < "$f" | cut -c1-40)"; fi
    done)
}

# Neither a file nor a link: assert_not_exists alone passes a dangling link.
assert_absent() {  # path, [message]
    if [ -e "$1" ] || [ -L "$1" ]; then
        echo "  FAIL: ${2:-$1 should not exist} (still there: $1)"
        return 1
    fi
}

assert_link() {  # link, target
    [ -L "$1" ] || { echo "  FAIL: $1 is not a link"; return 1; }
    assert_eq "$2" "$(readlink "$1")"
}

test_links_each_user_entry_into_the_profile() {
    seed
    carry || return 1
    local U="$HOME/.claude" X="$HOME/.codex" P="$PROFILE"
    assert_link "$P/.claude/CLAUDE.md" "$U/CLAUDE.md" || return 1
    assert_link "$P/.claude/agents/helper.md" "$U/agents/helper.md" || return 1
    assert_link "$P/.claude/commands/mine.md" "$U/commands/mine.md" || return 1
    assert_link "$P/.claude/skills/my-skill" "$U/skills/my-skill" || return 1
    assert_link "$P/.claude/workflows/flow.js" "$U/workflows/flow.js" || return 1
    assert_link "$P/.claude/themes/mine.json" "$U/themes/mine.json" || return 1
    assert_link "$P/.codex/AGENTS.md" "$X/AGENTS.md" || return 1
    assert_link "$P/.codex/skills/codex-skill" "$X/skills/codex-skill" || return 1
    assert_link "$P/.codex/agents/helper.toml" "$X/agents/helper.toml" || return 1
    # One link per entry: the directories stay the profile's own.
    local dir
    for dir in .claude/skills .claude/commands .claude/agents .codex/skills .codex/agents; do
        [ -d "$P/$dir" ] && [ ! -L "$P/$dir" ] || { echo "  FAIL: $dir is not a real directory"; return 1; }
    done
    # An edit in ~/.claude reaches the profile at once.
    printf 'edited\n' > "$U/skills/my-skill/SKILL.md"
    assert_eq edited "$(cat "$P/.claude/skills/my-skill/SKILL.md")"
}

test_skips_every_name_the_installer_owns_and_backups() {
    seed
    local U="$HOME/.claude" X="$HOME/.codex" name mod
    # Without the profile's copies, nothing but the installer's lists keeps
    # these names from being linked.
    for name in "${CS_SKILLS[@]}" "${RETIRED_SKILLS[@]}"; do
        rm -rf "$PROFILE/.claude/skills/$name" "$PROFILE/.codex/skills/$name"
        mkdir -p "$U/skills/$name" "$X/skills/$name"
    done
    for mod in "${CS_MOD_FILES[@]}"; do
        rm -rf "$PROFILE/.claude/skills/${mod%%/*}"
        mkdir -p "$U/skills/${mod%%/*}"
    done
    carry || return 1
    for name in "${CS_SKILLS[@]}" "${RETIRED_SKILLS[@]}" synced cs cs-update .trash; do
        assert_absent "$PROFILE/.claude/skills/$name" "claude skill $name is the installer's" || return 1
    done
    for name in "${CS_SKILLS[@]}"; do
        assert_absent "$PROFILE/.codex/skills/$name" "codex skill $name is the installer's" || return 1
    done
    for name in "${RETIRED_COMMANDS[@]}" mine.md.pre-any-session; do
        assert_absent "$PROFILE/.claude/commands/$name" "command $name" || return 1
    done
    assert_absent "$PROFILE/.claude/agents/helper.md.pre-edit" || return 1
    for name in my-skill.pre-move my-skill.bak; do
        assert_absent "$PROFILE/.claude/skills/$name" "skill backup $name" || return 1
    done
    assert_absent "$PROFILE/.codex/skills/codex-skill.before-edit" "codex skill backup" || return 1
    assert_link "$PROFILE/.claude/skills/my-skill" "$U/skills/my-skill"
}

test_keeps_the_profiles_own_entries() {
    seed
    mkdir -p "$PROFILE/.claude/skills/my-skill" "$PROFILE/.claude/skills/local-only"
    printf 'profile skill\n' > "$PROFILE/.claude/skills/my-skill/SKILL.md"
    printf 'profile instructions\n' > "$PROFILE/.claude/CLAUDE.md"
    ln -s /somewhere/else.md "$PROFILE/.claude/commands/mine.md"
    printf 'cmd\n' > "$HOME/.claude/commands/local-only.md"
    carry || return 1
    [ ! -L "$PROFILE/.claude/skills/my-skill" ] || { echo "  FAIL: replaced the profile's skill"; return 1; }
    assert_eq 'profile skill' "$(cat "$PROFILE/.claude/skills/my-skill/SKILL.md")" || return 1
    assert_eq 'profile instructions' "$(cat "$PROFILE/.claude/CLAUDE.md")" || return 1
    assert_eq /somewhere/else.md "$(readlink "$PROFILE/.claude/commands/mine.md")" || return 1
    # A command beside a skill of the profile's own would answer /local-only twice.
    assert_absent "$PROFILE/.claude/commands/local-only.md"
}

test_rerun_unlinks_what_the_user_removed_and_nothing_else() {
    seed
    carry || return 1
    ln -s /nonexistent/elsewhere "$PROFILE/.claude/skills/foreign"
    rm -rf "$HOME/.claude/skills/my-skill" "$HOME/.claude/CLAUDE.md" "$HOME/.codex/agents/helper.toml"
    carry || return 1
    assert_absent "$PROFILE/.claude/skills/my-skill" || return 1
    assert_absent "$PROFILE/.claude/CLAUDE.md" || return 1
    assert_absent "$PROFILE/.codex/agents/helper.toml" || return 1
    [ -L "$PROFILE/.claude/skills/foreign" ] || { echo "  FAIL: removed a link that is not the carry-over's"; return 1; }
    assert_link "$PROFILE/.claude/commands/mine.md" "$HOME/.claude/commands/mine.md"
}

# A link made before ags shipped a skill of the same name would have the
# install copy ags's files through it into ~/.claude.
test_prune_drops_links_that_an_installed_name_shadows() {
    seed
    rm -rf "$PROFILE/.claude/skills/finish"
    ln -s "$HOME/.claude/skills/finish" "$PROFILE/.claude/skills/finish"
    carry --prune || return 1
    assert_absent "$PROFILE/.claude/skills/finish" || return 1
    assert_eq 'stable finish' "$(cat "$HOME/.claude/skills/finish/SKILL.md")" || return 1
    # Pruning links nothing new.
    assert_absent "$PROFILE/.claude/skills/my-skill"
}

test_second_run_changes_no_byte() {
    seed
    carry || return 1
    profile_snapshot > "$TEST_TMPDIR/first"
    carry || return 1
    profile_snapshot > "$TEST_TMPDIR/second"
    cmp "$TEST_TMPDIR/first" "$TEST_TMPDIR/second" || { diff "$TEST_TMPDIR/first" "$TEST_TMPDIR/second"; return 1; }
    assert_file_contains "$TEST_TMPDIR/carry.out" 'nothing to change'
}

test_settings_merge_keeps_the_profiles_choices() {
    seed
    carry || return 1
    local s="$PROFILE/.claude/settings.json"
    assert_eq opus "$(jq -r .model "$s")" || return 1
    assert_eq dark "$(jq -r .theme "$s")" || return 1
    assert_eq high "$(jq -r .effortLevel "$s")" "the profile's value wins" || return 1
    assert_eq null "$(jq -r .tui "$s")" "setup.sh carries tui itself" || return 1
    assert_eq null "$(jq -r .disableAllHooks "$s")" "would switch off ags's hooks" || return 1
    assert_eq true "$(jq -r .alwaysThinkingEnabled "$s")" || return 1
    assert_eq auto "$(jq -r .permissions.defaultMode "$s")" || return 1
    assert_eq '["Bash(ls:*)"]' "$(jq -c .permissions.allow "$s")" || return 1
    assert_eq true "$(jq -r '.enabledPlugins["tool@official"]' "$s")" || return 1
    assert_eq true "$(jq -r '.enabledPlugins["clangd-lsp@official"]' "$s")" "the profile's value wins" || return 1
    assert_eq 1 "$(jq '[.hooks[][].hooks[] | select(.command == "/opt/bin/hinter hint")] | length' "$s")" || return 1
    assert_eq 0 "$(jq '[.hooks[][].hooks[] | select(.command | startswith("~/"))] | length' "$s")" "cs hooks stay out" || return 1
    assert_eq 1 "$(jq '[.hooks[][].hooks[] | select(.command | endswith("/hooks/cs/session-start.sh"))] | length' "$s")" || return 1
    # A hook the user adds in the profile stays; a rerun duplicates nothing.
    jq '.hooks.Stop = [{hooks: [{type: "command", command: "/profile/own-hook"}]}]' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
    carry || return 1
    assert_eq 1 "$(jq '[.hooks[][].hooks[] | select(.command == "/opt/bin/hinter hint")] | length' "$s")" || return 1
    assert_eq /profile/own-hook "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" || return 1
    assert_file_exists "$s.pre-carry-over"
}

test_mcp_servers_merge_without_printing_secrets() {
    seed
    local out
    bash "$CARRY" --dry-run > "$TEST_TMPDIR/dry.out" 2>&1 || { cat "$TEST_TMPDIR/dry.out"; return 1; }
    carry || return 1
    cp "$TEST_TMPDIR/carry.out" "$TEST_TMPDIR/run1.out"
    carry || return 1
    for out in "$TEST_TMPDIR/dry.out" "$TEST_TMPDIR/run1.out" "$TEST_TMPDIR/carry.out"; do
        assert_file_not_contains "$out" 'FIXTURE-SECRET' || return 1
    done
    assert_file_contains "$TEST_TMPDIR/run1.out" 'Claude MCP server remote' || return 1
    assert_file_contains "$TEST_TMPDIR/run1.out" 'Codex MCP server remote' || return 1
    local cj="$PROFILE/.claude/.claude.json" config="$PROFILE/.codex/config.toml"
    assert_eq "Bearer $CLAUDE_SECRET" "$(jq -r .mcpServers.remote.headers.Authorization "$cj")" || return 1
    assert_eq /bin/echo "$(jq -r '.mcpServers["profile-own"].command' "$cj")" "the profile's server wins" || return 1
    assert_eq 3 "$(jq -r .numStartups "$cj")" || return 1
    assert_eq 600 "$(_file_mode "$cj")" || return 1
    assert_file_contains "$config" "^TOKEN = \"$CODEX_SECRET\"$" || return 1
    assert_eq 1 "$(grep -c -F '[mcp_servers.profile-own]' "$config")" || return 1
    assert_eq 1 "$(grep -c -F '[mcp_servers.remote]' "$config")" || return 1
    assert_file_contains "$config" '^  "\[not a header\]",$' || return 1
    assert_file_contains "$config" '^\[sandbox_workspace_write\]$' || return 1
    assert_file_not_contains "$config" '^model = ' || return 1
    if /usr/bin/env python3 -c 'import tomllib' 2>/dev/null; then
        python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); assert sorted(d["mcp_servers"]) == ["local", "profile-own", "remote"], d["mcp_servers"].keys()' "$config" || return 1
    fi
}

# A server defined inline cannot be copied as a table: the run says so in
# every mode, and names as added only the servers it copied.
test_codex_mcp_report_names_only_what_it_copied() {
    seed
    local X="$HOME/.codex"
    { printf 'mcp_servers.foo = { command = "/bin/foo" }\n'; cat "$X/config.toml"
      printf '\n[mcp_servers.foobar]\ncommand = "/bin/foobar"\n'; } > "$X/config.toml.new"
    mv "$X/config.toml.new" "$X/config.toml"
    carry || return 1
    grep -q -x -F '  added Codex MCP server foobar' "$TEST_TMPDIR/carry.out" || { echo "  FAIL: foobar not reported"; return 1; }
    if grep -q -x -F '  added Codex MCP server foo' "$TEST_TMPDIR/carry.out"; then
        echo "  FAIL: reported foo, which was not copied"; return 1
    fi
    assert_file_contains "$TEST_TMPDIR/carry.out" 'note: Codex MCP server foo is defined inline' || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" '/bin/foo"'
}

# A profile value of a shape the merge does not expect is the profile's: the
# rest still merges, the run goes on to Codex, and jq's message (which can
# quote a value) is not shown.
test_unexpected_shapes_in_the_profile_do_not_stop_the_run() {
    seed
    local s="$PROFILE/.claude/settings.json" config="$PROFILE/.codex/config.toml" status=0
    jq_edit "$s" '.permissions = {allow: "Bash(FIXTURE-VALUE)"}'
    jq_edit "$PROFILE/.claude/.claude.json" '.mcpServers = "FIXTURE-VALUE"'
    printf 'mcp_servers = { profile-own = { command = "/bin/echo" } }\n' > "$config"
    _codex_hooks_register "$PROFILE/.codex" "$(_codex_hook_command "$PROFILE/.local/bin/ags")"
    # /usr/bin first: its Python has no tomllib, so nothing checks the merged
    # config.toml and the run itself must not break it.
    PATH="/usr/bin:/bin:$PATH" bash "$CARRY" > "$TEST_TMPDIR/carry.out" 2>&1 || status=$?
    assert_eq 0 "$status" || { cat "$TEST_TMPDIR/carry.out"; return 1; }
    assert_file_not_contains "$TEST_TMPDIR/carry.out" 'FIXTURE-VALUE' || return 1
    assert_eq '"Bash(FIXTURE-VALUE)"' "$(jq -c .permissions.allow "$s")" || return 1
    assert_eq auto "$(jq -r .permissions.defaultMode "$s")" || return 1
    assert_eq true "$(jq -r .alwaysThinkingEnabled "$s")" || return 1
    assert_eq '"FIXTURE-VALUE"' "$(jq -c .mcpServers "$PROFILE/.claude/.claude.json")" || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'Warning: could not merge the MCP servers' || return 1
    assert_link "$PROFILE/.codex/skills/codex-skill" "$HOME/.codex/skills/codex-skill" || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" "note: the profile's config.toml holds mcp_servers as one inline table" || return 1
    assert_file_not_contains "$config" '^\[mcp_servers' || return 1
    if /usr/bin/env python3 -c 'import tomllib' 2>/dev/null; then
        python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$config"
    fi
}

# A hook's trust lives in config.toml, so hooks.json is not written when the
# merged config.toml would not parse. Needs a Python with tomllib to check.
test_codex_hooks_wait_for_a_config_that_parses() {
    /usr/bin/env python3 -c 'import tomllib' 2>/dev/null || return 0
    seed
    local hooks="$PROFILE/.codex/hooks.json" config="$PROFILE/.codex/config.toml" before
    printf 'broken = \n' >> "$config"
    before=$(shasum < "$hooks")
    cp "$config" "$TEST_TMPDIR/config.before"
    bash "$CARRY" > "$TEST_TMPDIR/carry.out" 2>&1 || { cat "$TEST_TMPDIR/carry.out"; return 1; }
    assert_file_contains "$TEST_TMPDIR/carry.out" 'would not parse' || return 1
    assert_eq "$before" "$(shasum < "$hooks")" "hooks.json unchanged" || return 1
    cmp -s "$TEST_TMPDIR/config.before" "$config" || { echo "  FAIL: config.toml changed"; return 1; }
    assert_absent "$PROFILE/.codex/.ags-carried-hooks.json"
}

test_disabled_plugins_are_not_copied() {
    seed
    jq_edit "$HOME/.claude/settings.json" '.enabledPlugins["tool@official"] = false'
    carry || return 1
    assert_absent "$PROFILE/.claude/plugins/cache/official/tool" || return 1
    assert_eq null "$(jq -c '.plugins["tool@official"]' "$PROFILE/.claude/plugins/installed_plugins.json")" || return 1
    assert_file_not_contains "$TEST_TMPDIR/carry.out" 'plugin tool@official'
}

test_plugins_come_from_the_users_cache() {
    seed
    carry || return 1
    local reg="$PROFILE/.claude/plugins/installed_plugins.json" dest
    dest="$PROFILE/.claude/plugins/cache/official/tool/1.0.0"
    assert_eq "$dest" "$(jq -r '.plugins["tool@official"][0].installPath' "$reg")" || return 1
    [ -d "$dest" ] && [ ! -L "$dest" ] || { echo "  FAIL: the plugin was not copied"; return 1; }
    assert_file_exists "$dest/.claude-plugin/plugin.json" || return 1
    assert_eq "$PROFILE/.claude/plugins/cache/official/clangd-lsp/1.0.0" \
        "$(jq -r '.plugins["clangd-lsp@official"][0].installPath' "$reg")" || return 1
    assert_eq "$PROFILE/.claude/plugins/marketplaces/official" \
        "$(jq -r .official.installLocation "$PROFILE/.claude/plugins/known_marketplaces.json")" || return 1
    assert_file_exists "$PROFILE/.claude/plugins/marketplaces/official/marketplace.json" || return 1
    assert_eq "$HOME/.claude/plugins/cache/official/tool/1.0.0" \
        "$(jq -r '.plugins["tool@official"][0].installPath' "$HOME/.claude/plugins/installed_plugins.json")"
}

test_codex_hooks_carry_the_users_trust_and_no_more() {
    seed
    carry || return 1
    local hooks="$PROFILE/.codex/hooks.json" config="$PROFILE/.codex/config.toml" key
    assert_eq '/opt/bin/emit SessionStart' "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$hooks")" "appended after ags's group" || return 1
    assert_eq 1 "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | endswith("-codex-hook session-start"))] | length' "$hooks")" || return 1
    key="$PROFILE/.codex/hooks.json:session_start:1:0"
    assert_file_contains "$config" "^\[hooks.state.\"$key\"\]$" || return 1
    assert_eq "sha256:$(codex_hash session_start "/opt/bin/emit SessionStart")" \
        "$(awk -v h="[hooks.state.\"$key\"]" '$0 == h {getline; sub(/^[^"]*"/, ""); sub(/".*/, ""); print}' "$config")" || return 1
    # ags's own trust stays, and the hook ~/.codex never trusted is carried untrusted.
    assert_file_contains "$config" "^\[hooks.state.\"$PROFILE/.codex/hooks.json:session_start:0:0\"\]$" || return 1
    assert_eq '/opt/bin/emit Stop' "$(jq -r '.hooks.Stop[0].hooks[0].command' "$hooks")" || return 1
    assert_file_not_contains "$config" 'hooks.json:stop:' || return 1
    assert_file_contains "$config" "^\[hooks.state.\"$PROFILE/.codex/hooks.json:session_end:0:0\"\]$" || return 1
    carry || return 1
    assert_eq 1 "$(grep -c -F "[hooks.state.\"$key\"]" "$config")" || return 1
    assert_eq 2 "$(jq '.hooks.SessionStart | length' "$hooks")"
}

# The profile keeps the definition it was given, so its trust is the hash of
# that definition: a hook changed and trusted again in ~/.codex (same command,
# new timeout) must not leave the profile trusting a definition it lacks.
test_codex_trust_follows_the_definition_the_profile_holds() {
    seed
    carry || return 1
    local X="$HOME/.codex" config="$PROFILE/.codex/config.toml" key old
    key="$PROFILE/.codex/hooks.json:session_start:1:0"
    old="sha256:$(codex_hash session_start "/opt/bin/emit SessionStart")"
    assert_eq "$old" "$(trusted "$config" "$key")" || return 1
    jq_edit "$X/hooks.json" '.hooks.SessionStart[0].hooks[0].timeout = 20'
    trust "$X/config.toml" "$X/hooks.json:session_start:0:0" "$(codex_hash session_start "/opt/bin/emit SessionStart" 20)"
    carry || return 1
    assert_eq null "$(jq '.hooks.SessionStart[1].hooks[0].timeout' "$PROFILE/.codex/hooks.json")" "the profile's copy stays" || return 1
    assert_eq "$old" "$(trusted "$config" "$key")" "trust still matches the profile's definition"
}

# One command under two matchers is two hooks, in both engines.
test_same_command_under_two_matchers_carries_both() {
    seed
    local s="$HOME/.claude/settings.json" X="$HOME/.codex" hooks="$PROFILE/.codex/hooks.json" config="$PROFILE/.codex/config.toml"
    jq_edit "$s" '.hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "/opt/bin/guard"}]},
        {matcher: "Edit|Write", hooks: [{type: "command", command: "/opt/bin/guard"}]}]'
    jq_edit "$X/hooks.json" '.hooks.PreToolUse = [{matcher: "Bash", hooks: [{type: "command", command: "/opt/bin/guard"}]},
        {matcher: "Edit|Write", hooks: [{type: "command", command: "/opt/bin/guard"}]}]'
    trust "$X/config.toml" "$X/hooks.json:pre_tool_use:0:0" "$(codex_hash pre_tool_use /opt/bin/guard 600 Bash)"
    trust "$X/config.toml" "$X/hooks.json:pre_tool_use:1:0" "$(codex_hash pre_tool_use /opt/bin/guard 600 'Edit|Write')"
    carry || return 1
    carry || return 1
    assert_eq '["Bash","Edit|Write"]' "$(jq -c '[.hooks.PreToolUse[] | .matcher]' "$PROFILE/.claude/settings.json")" || return 1
    assert_eq '["Bash","Edit|Write"]' "$(jq -c '[.hooks.PreToolUse[] | .matcher]' "$hooks")" || return 1
    # Each is trusted with the hash of its own matcher.
    assert_eq "sha256:$(codex_hash pre_tool_use /opt/bin/guard 600 Bash)" \
        "$(trusted "$config" "$PROFILE/.codex/hooks.json:pre_tool_use:0:0")" || return 1
    assert_eq "sha256:$(codex_hash pre_tool_use /opt/bin/guard 600 'Edit|Write')" \
        "$(trusted "$config" "$PROFILE/.codex/hooks.json:pre_tool_use:1:0")"
}

# A hook the carry-over added follows the user's: changed or removed there, it
# leaves the profile, so the old and the new never both run. A hook of the
# profile's own stays.
test_a_changed_or_removed_hook_leaves_the_profile() {
    seed
    local s="$HOME/.claude/settings.json" ps="$PROFILE/.claude/settings.json"
    jq_edit "$ps" '.hooks.Stop = [{hooks: [{type: "command", command: "/opt/bin/kept"}]}]'
    jq_edit "$s" '.hooks.Stop = [{hooks: [{type: "command", command: "/opt/bin/kept"}]}]'
    carry || return 1
    jq_edit "$s" '.hooks.UserPromptSubmit[0].hooks[0].command = "/opt/bin/hinter hint --v2"'
    carry || return 1
    assert_eq '["/opt/bin/hinter hint --v2"]' "$(jq -c '[.hooks.UserPromptSubmit[].hooks[].command]' "$ps")" || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'removed hook UserPromptSubmit: hinter (gone from ~/.claude)' || return 1
    jq_edit "$ps" '.hooks.SubagentStop = [{hooks: [{type: "command", command: "/profile/own-hook"}]}]'
    jq_edit "$s" 'del(.hooks.UserPromptSubmit, .hooks.Stop)'
    carry || return 1
    assert_eq null "$(jq -c '.hooks.UserPromptSubmit' "$ps")" || return 1
    assert_eq '["/opt/bin/kept"]' "$(jq -c '[.hooks.Stop[].hooks[].command]' "$ps")" "the profile had it first" || return 1
    assert_eq /profile/own-hook "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$ps")" || return 1
    assert_eq 1 "$(jq '[.hooks[][].hooks[] | select(.command | endswith("/hooks/cs/session-start.sh"))] | length' "$ps")"
}

# Codex trusts a hook by its position: when a carried hook leaves, the hook
# after it moves up and its trust table moves with it.
test_codex_hook_that_leaves_takes_its_trust_and_moves_the_rest() {
    seed
    carry || return 1
    local X="$HOME/.codex" hooks="$PROFILE/.codex/hooks.json" config="$PROFILE/.codex/config.toml" own_hash own2_hash f
    f="$PROFILE/.codex/hooks.json"
    # Two hooks trusted in an ags Codex session, in a group after the carried
    # one, and a table left behind for a position no hook holds.
    jq_edit "$hooks" '.hooks.SessionEnd += [{hooks: [{type: "command", command: "/profile/own-end", timeout: 2},
        {type: "command", command: "/profile/own-end2", timeout: 2}]}]'
    own_hash=$(codex_hash session_end /profile/own-end 2)
    own2_hash=$(codex_hash session_end /profile/own-end2 2)
    trust "$config" "$f:session_end:1:0" "$own_hash"
    trust "$config" "$f:session_end:1:1" "$own2_hash"
    trust "$config" "$f:session_end:0:1" "$(codex_hash session_end /gone 2)"
    jq_edit "$X/hooks.json" 'del(.hooks.SessionEnd)'
    carry || return 1
    assert_eq '["/profile/own-end","/profile/own-end2"]' "$(jq -c '[.hooks.SessionEnd[].hooks[].command]' "$hooks")" || return 1
    assert_eq "sha256:$own_hash" "$(trusted "$config" "$f:session_end:0:0")" || return 1
    assert_eq "sha256:$own2_hash" "$(trusted "$config" "$f:session_end:0:1")" || return 1
    assert_eq 0 "$(grep -c -F "[hooks.state.\"$f:session_end:1:" "$config")" || return 1
    assert_eq 1 "$(grep -c -F "[hooks.state.\"$f:session_end:0:0\"]" "$config")" || return 1
    assert_eq 1 "$(grep -c -F "[hooks.state.\"$f:session_end:0:1\"]" "$config")" || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'removed Codex hook SessionEnd: emit (gone from ~/.codex)' || return 1
    assert_eq "sha256:$(codex_hash session_start "/opt/bin/emit SessionStart")" "$(trusted "$config" "$f:session_start:1:0")" || return 1
    if /usr/bin/env python3 -c 'import tomllib' 2>/dev/null; then
        python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$config" || return 1
    fi
    carry || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'nothing to change'
}

# Named by the file a hook runs: never an argument or an assignment, which can
# hold a token. A hook that runs no command is carried once, by its definition.
test_hooks_are_named_without_their_arguments() {
    seed
    jq_edit "$HOME/.claude/settings.json" '.hooks.Stop = [
        {hooks: [{type: "command", command: "hookbin --token=ab/FIXTURE-SECRET-HOOK"}]},
        {hooks: [{type: "command", command: "TOKEN=ab/FIXTURE-SECRET-ENV /opt/bin/runner x"}]},
        {hooks: [{type: "prompt", prompt: "first check"}]},
        {hooks: [{type: "prompt", prompt: "second check"}]}]'
    carry || return 1
    assert_file_not_contains "$TEST_TMPDIR/carry.out" 'FIXTURE-SECRET' || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'added hook Stop: hookbin$' || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'added hook Stop: runner$' || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'added hook Stop: prompt hook$' || return 1
    assert_eq 2 "$(jq '[.hooks.Stop[].hooks[] | select(.type == "prompt")] | length' "$PROFILE/.claude/settings.json")" || return 1
    profile_snapshot > "$TEST_TMPDIR/first"
    carry || return 1
    profile_snapshot > "$TEST_TMPDIR/second"
    cmp "$TEST_TMPDIR/first" "$TEST_TMPDIR/second" || { diff "$TEST_TMPDIR/first" "$TEST_TMPDIR/second"; return 1; }
}

test_sidebar_bridge_wraps_the_profiles_status_line_once() {
    seed
    carry || return 1
    local s="$PROFILE/.claude/settings.json" original="$PROFILE/.claude/agents-sidebar-status/original-statusline"
    assert_eq /opt/sidebar/plugin/statusline-bridge.sh "$(jq -r .statusLine.command "$s")" || return 1
    assert_eq 1 "$(jq -r .statusLine.refreshInterval "$s")" || return 1
    # As the sidebar records it: the command alone, no newline.
    assert_eq "$PROFILE/.local/bin/ags-statusline" "$(cat "$original")" || return 1
    assert_eq "$(printf '%s' "$PROFILE/.local/bin/ags-statusline" | wc -c)" "$(wc -c < "$original")" || return 1
    # Given its own line back later, the profile keeps it.
    jq --arg c "$PROFILE/.local/bin/ags-statusline" '.statusLine = {type: "command", command: $c, refreshInterval: 60}' \
        "$s" > "$s.tmp" && mv "$s.tmp" "$s"
    carry || return 1
    assert_eq "$PROFILE/.local/bin/ags-statusline" "$(jq -r .statusLine.command "$s")"
}

test_status_line_left_alone_without_the_sidebar() {
    seed
    local s="$HOME/.claude/settings.json"
    jq '.statusLine = {type: "command", command: "/opt/bin/my-line"}' "$s" > "$s.tmp" && mv "$s.tmp" "$s"
    carry || return 1
    assert_eq "$PROFILE/.local/bin/ags-statusline" "$(jq -r .statusLine.command "$PROFILE/.claude/settings.json")" || return 1
    assert_absent "$PROFILE/.claude/agents-sidebar-status"
}

test_dry_run_writes_nothing() {
    seed
    profile_snapshot > "$TEST_TMPDIR/before"
    carry --dry-run || return 1
    profile_snapshot > "$TEST_TMPDIR/after"
    cmp "$TEST_TMPDIR/before" "$TEST_TMPDIR/after" || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'would link claude/skills/my-skill' || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'would copy plugin tool@official' || return 1
    assert_file_contains "$TEST_TMPDIR/carry.out" 'leave claude/skills/finish (ags installs its own)'
}

test_codex_only_profile_gets_no_claude_changes() {
    seed
    printf 'codex\n' > "$PROFILE/.local/bin/.cs-install-engines"
    rm -rf "$PROFILE/.claude"
    carry || return 1
    assert_absent "$PROFILE/.claude" || return 1
    assert_link "$PROFILE/.codex/skills/codex-skill" "$HOME/.codex/skills/codex-skill"
}

# Inside an ags session these name the profile itself; the carry-over reads
# the user's directories from HOME alone.
test_session_environment_does_not_redirect_the_source() {
    seed
    CLAUDE_CONFIG_DIR="$PROFILE/.claude" CODEX_HOME="$PROFILE/.codex" CS_CLAUDE_DIR="$PROFILE/.claude" \
        CS_SKILLS_DIR="$PROFILE/.claude/skills" carry || return 1
    assert_link "$PROFILE/.claude/skills/my-skill" "$HOME/.claude/skills/my-skill"
}

test_refuses_without_a_profile_and_prune_is_quiet() {
    local status=0
    bash "$CARRY" > "$TEST_TMPDIR/out" 2>&1 || status=$?
    assert_eq 1 "$status" || return 1
    assert_file_contains "$TEST_TMPDIR/out" 'run setup.sh first' || return 1
    bash "$CARRY" --prune > "$TEST_TMPDIR/out" 2>&1 || return 1
    assert_eq '' "$(cat "$TEST_TMPDIR/out")"
}

run_test test_links_each_user_entry_into_the_profile
run_test test_skips_every_name_the_installer_owns_and_backups
run_test test_keeps_the_profiles_own_entries
run_test test_rerun_unlinks_what_the_user_removed_and_nothing_else
run_test test_prune_drops_links_that_an_installed_name_shadows
run_test test_second_run_changes_no_byte
run_test test_settings_merge_keeps_the_profiles_choices
run_test test_mcp_servers_merge_without_printing_secrets
run_test test_plugins_come_from_the_users_cache
run_test test_codex_hooks_carry_the_users_trust_and_no_more
run_test test_codex_trust_follows_the_definition_the_profile_holds
run_test test_same_command_under_two_matchers_carries_both
run_test test_a_changed_or_removed_hook_leaves_the_profile
run_test test_codex_hook_that_leaves_takes_its_trust_and_moves_the_rest
run_test test_hooks_are_named_without_their_arguments
run_test test_codex_mcp_report_names_only_what_it_copied
run_test test_unexpected_shapes_in_the_profile_do_not_stop_the_run
run_test test_codex_hooks_wait_for_a_config_that_parses
run_test test_disabled_plugins_are_not_copied
run_test test_sidebar_bridge_wraps_the_profiles_status_line_once
run_test test_status_line_left_alone_without_the_sidebar
run_test test_dry_run_writes_nothing
run_test test_codex_only_profile_gets_no_claude_changes
run_test test_session_environment_does_not_redirect_the_source
run_test test_refuses_without_a_profile_and_prune_is_quiet
report_results
