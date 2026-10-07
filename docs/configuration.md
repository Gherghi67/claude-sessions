# Configuration

agent-sessions (`ags`) reads its configuration from environment variables. None are required — it
runs with sensible defaults out of the box — but you can set any of these in
`~/.bashrc` or `~/.zshrc` to override behavior.

This lists every variable a user would set, plus the ones ags exports for hooks
and helper binaries. It deliberately excludes test seams and internal state —
values ags computes and passes to its own helpers, which change without notice and are
documented in the code that reads them.

## Environment variables you set

```bash
# Sessions directory (default: ~/.claude-sessions)
export CS_SESSIONS_ROOT="/path/to/sessions"

# Where cs's own configuration and caches live (defaults: $XDG_CONFIG_HOME/cs or
# ~/.config/cs, and $XDG_CACHE_HOME/cs or ~/.cache/cs). The ags profile launcher
# sets both so a session never touches the stable install's files.
export CS_CONFIG_DIR="$HOME/.config/cs"
export CS_CACHE_DIR="$HOME/.cache/cs"

# Where ags -encrypt makes new containers, under vaults/, and where a launch
# under tmux in iTerm2 keeps its hard links named claude, under claude/
# (default: ~/.local/share/cs, whatever XDG_DATA_HOME says). The profile
# launcher sets it to the profile's own, so a session the stable install also
# has never shares its container, and neither install prunes the other's links. An encrypted session opens the container it recorded, so
# changing this later moves no existing vault. ags -encrypt refuses a relative
# path: every open attaches the container from the session directory.
export CS_DATA_DIR="$HOME/.local/share/cs"

# Where the deployed ags executables and the installer's adapter record live
# (default: ~/.local/bin). The profile launcher sets it to the profile's own.
export CS_INSTALL_DIR="$HOME/.local/bin"

# Where the encrypted-file secrets backend keeps its store (default: ~/.cs-secrets).
export CS_SECRETS_DIR="$HOME/.cs-secrets"

# The actor name that shared memory and narratives are attributed to. Highest
# precedence in the chain $CS_ACTOR > .cs/local/identity > git user.email >
# git user.name, so it is how you override attribution on a machine whose git
# identity is not the one you want recorded.
export CS_ACTOR="alice"

# Skip the update check entirely. ags otherwise asks GitHub for the latest
# release at most hourly and caches the answer under ~/.cache/cs; this stops
# both the request and the write, for an air-gapped machine or simply to keep
# cs off the network.
export CS_NO_UPDATE_CHECK="1"

# Legacy password for secrets sync (age encryption preferred - see secrets.md)
export CS_SECRETS_PASSWORD="your-secure-password"

# Override secrets backend (keychain or encrypted). ags -list and the picker
# count secrets from the keychain, so under any other backend they show none.
export CS_SECRETS_BACKEND="keychain"

# Override Claude Code binary (default: claude)
export CLAUDE_CODE_BIN="claude"

# Default runtime for sessions without a saved engine preference.
# Legacy/dual installs default to Claude; a sole Codex install defaults to Codex.
# A session's saved engine choice takes precedence; `--engine` on the `ags` command
# takes precedence over both. Codex launches require CODEX_BIN and Python 3.
export CS_DEFAULT_ENGINE="codex"   # claude | codex

# Override the Codex CLI executable used by `ags <name> --engine codex`
# (default: codex). This is one executable path, without extra arguments.
export CODEX_BIN="/path/to/codex"

# Nerd Font icons in ags banners and session listings (lock, host);
# the status line uses standard Unicode and is unaffected by this
export CS_NERD_FONTS="1"

# Force the light/dark theme (session-picker TUI palette, statusline, hooks).
# Unset (default), ags auto-detects the terminal background before launch; the
# exact detection cascade lives in docs/statusline.md ("Terminal theme").
# Set this to override; `ags -detect-theme` prints what detection yields.
export CS_TERM_THEME="light"   # or "dark"

# Override the terminal's real background color (default: auto-detected via
# the same OSC 11 query as CS_TERM_THEME, when it succeeds). The statusline's
# capsule surface is a shade of it; unset, the surface falls back to a fixed
# warm taupe per theme.
export CS_TERM_BG_RGB="250;248;242"   # r;g;b, 0-255 each

# Disable colors (see https://no-color.org)
export NO_COLOR="1"

# Status line: choose/order segments, or disable entirely
export CS_STATUSLINE_SEGMENTS="logo,session,notes,mail,git,model,ctx,limits"  # this is the default

export CS_STATUSLINE_DISABLE="1"

# Force the Powerline rounded caps (U+E0B6/U+E0B4) on (1) or off (0),
# overriding this machine's recorded answer in ~/.config/cs/statusline-caps
export CS_STATUSLINE_CAPS="0"

# Where the machine-global usage cache behind the `fable` segment lives
# (default: $CS_SESSIONS_ROOT/.usage). One record per account per machine, not
# one per session: the endpoint it draws on budgets requests per account.
export CS_USAGE_DIR="$HOME/.claude-sessions/.usage"

# Render the `fable` segment from cache only, never triggering a refresh
export CS_USAGE_NO_REFRESH="1"

# Every switch below that silences something the model would otherwise see is
# listed by `ags -doctor` under "Authority", with its live on/off state.

# Opt a session out of the scope-prompt auto-grounding hook
export CS_SCOPE_DISABLE="1"

# Opt a session out of the scope-prompt stage trace (see hooks.md)
export CS_SCOPE_TRACE_DISABLE="1"

# Milliseconds the scope-prompt hook allows its cheap front half before it
# skips the grounded scan on a slow machine (default 1500), so the digests,
# the date note and the clarify guideline reach the model instead of dying
# with a scan the registered timeout kills. 0 skips the scan on every prompt;
# a value that is not a number, or longer than seven digits, is the default; so
# is a value of 1000 or less on a shell whose clock ticks in whole seconds
# (bash 3.2), which cannot judge a budget of one tick.
export CS_SCOPE_BUDGET_MS="1500"

# Opt a session out of first-prompt Objective capture (see hooks.md)
export CS_OBJECTIVE_CAPTURE_DISABLE="1"

# Opt a session out of the date reminder: the one-line note scope-prompt adds
# when the calendar day has changed since the conversation last heard the date
# (see hooks.md).
export CS_DATE_REMINDER_DISABLE="1"

# Opt a session out of the clarify guideline (see hooks.md).
# Separate from CS_SCOPE_DISABLE on purpose: silencing grounding should not
# silence the questions. Skip a single turn instead with a leading ~ .
export CS_CLARIFY_DISABLE="1"

# Opt a session out of prompt rewriting (ctrl+g in the composer; see hooks.md).
# Separate from CS_CLARIFY_DISABLE: the questions and the rewriter are
# independent. When set, ags leaves your $EDITOR alone entirely.
export CS_REWRITE_DISABLE="1"

# Who rewrites prompts. The default is Claude, through the `claude` CLI and your
# existing login. `openai` and `gemini` prefer that vendor's CLI when its binary
# is on PATH — `codex` and `agy` respectively, both using your subscription — and
# fall back to the vendor's API when it is not, reading OPENAI_API_KEY or
# GEMINI_API_KEY from the environment. With neither a CLI nor a key, the rewrite
# declines and your prompt stays as typed.
#
# The CLI arms cost about ten seconds against about one for the API arms, and
# the interface is frozen for that whole time. That is the trade the default
# makes for you: no key, no per-token charge.
# Append `-api` to reach a vendor's API even when its CLI is installed. That is
# the only way to get Gemini's lite tier, which agy's catalogue does not carry
# and which is the fastest option there is: measured on one machine with agy and
# codex both present, gemini 7.3s vs gemini-api 0.9s, openai 12.8s vs openai-api
# 2.0s. `claude-api` calls Anthropic's Messages endpoint instead of driving the
# whole Claude Code agent, which is why the bare `claude` default takes ~13s.
# Every -api arm needs that vendor's key and declines without one.
export CS_REWRITE_PROVIDER="claude"          # claude | openai | gemini | grok
                                            # openai-api | gemini-api | claude-api reach a
                                            # vendor API past an installed CLI

# The model that rewrites prompts, and how long to wait for it. It reaches every
# arm: the API request, `agy --model`, `codex -m`. Left unset, each vendor CLI
# uses the model configured in that tool, which is your setting and not cs's to
# override.
#
# The id belongs to whichever engine answers, and the namespaces differ. Ask the
# engine: `agy models` lists agy's, and its ids embed the reasoning effort
# (`gemini-3.6-flash-low`), so the bare family name `gemini-3.6-flash` is
# rejected. The API arms take the vendor's own API ids. An id the engine does not
# accept declines the rewrite and leaves your prompt as typed — cs never
# translates between the two namespaces.
#
# Defaults, used only where cs picks: claude-haiku-4-5-20251001 and, on the API
# arms, gpt-4.1-mini and gemini-flash-lite-latest. Reasoning models are a poor
# fit whatever the provider: they can spend most of the output budget on
# reasoning and return a rewrite truncated mid-sentence, which cs declines — so
# ctrl+g intermittently does nothing at all.
export CS_REWRITE_MODEL="gemini-3.6-flash-low"        # agy's id, for the gemini CLI arm
export CS_REWRITE_TIMEOUT="25"                        # seconds; needs timeout(1)

# What fills the blank screen while the rewrite runs. `screen` holds your prompt
# in a margin rule that breathes while the rewrite runs, with the engine, the
# model and the time remaining beneath it. `native` is one anchored line
# in Claude Code's own idiom, with the elapsed appearing only after five
# seconds. `line` is one centred line with a spinner and a clock. `static`
# prints once and never animates, so a wedged rewrite looks the same as a
# working one. Only `screen` echoes your prompt. An unrecognised value falls
# back to `screen`.
export CS_REWRITE_PROGRESS="screen"          # screen | native | line | static

# Replace the rewriter itself. Reads the rough prompt on stdin, writes the
# rewrite to stdout, non-zero to leave the prompt untouched.
export CS_REWRITE_CMD="/path/to/my-rewriter"

# Statusline context gauge escalation thresholds (see statusline.md). Each takes
# a plain integer of at most three digits; anything else falls back to the
# default shown. A value above 100 is out of the gauge's reach and so switches
# that band off, the same idiom ags -doctor uses on the Stop hook's tiers below.
export CS_STATUSLINE_CTX_WARN="40"
export CS_STATUSLINE_CTX_CRIT="65"

# Disable the subagent (agent-panel) statusline rows without unregistering
export CS_SUBAGENT_STATUSLINE_DISABLE="1"

# Context tiers in the Stop hook: one-time warning band start, rotation nudge
export CS_CTX_WARN_CTX="40"
export CS_ROTATE_NUDGE_CTX="65"

# Context percentage at which the rotate mod's "1: rotate this conversation"
# button appears above the prompt (default: the status line's warn band).
# The mod reads it from the launched process's environment.
export CS_ROTATE_BUTTON_CTX="40"

# Forced rotation with grace (on at 80 unless set): once a turn ends with context
# at or past this percentage the mod runs /rotate itself, once per
# conversation, then counts the band down for 20 seconds and runs the /clear
# that continues from the handoff. Pressing 1 clears at once; sending a
# prompt stops the countdown. On at 80 unless set; `off` or `0` disables it,
# and a value that is not a number falls back to 80 rather than off. A
# conversation born of a /clear that already starts past it is never forced
# (a toast says so once); one met at launch or through /resume is.
export CS_ROTATE_FORCE_CTX="80"

# Narrative rotation: rotate when the live file passes MAX, keep about KEEP bytes
export CS_NARRATIVE_MAX_BYTES="229376"
export CS_NARRATIVE_KEEP_BYTES="114688"

# Queue circuit breakers: per-task tool failures, context %, 5h rate-limit %
export CS_QUEUE_MAX_FAILURES="5"
export CS_QUEUE_MAX_CTX="85"
export CS_QUEUE_MAX_5H="85"

# Mail wakes: how many a turn boundary may fire between user prompts,
# and the switch that silences them entirely (see hooks.md)
export CS_MAIL_WAKE_MAX="5"   # this is the default
export CS_NO_MAIL_WAKE="1"

# Rotation auto-start: after /clear on an armed handoff the session wakes
# itself and begins the handoff's next step with no typing. The delay is the
# interval between kick writes, repeated (up to 30 times) until the wake lands,
# since Claude Code's file watch arms only once session start has finished; 0
# writes once, with no retry. A non-numeric value falls back to the default.
# The opt-out restores the previous behaviour, where the rotation waits for a
# word from you.
export CS_ROTATION_KICK_DELAY="2"   # this is the default
export CS_NO_ROTATION_WAKE="1"

# Disable the iTerm2 attention bounce (the dock bounce a finished turn starts,
# and the attention marker the status line reads). The tab tint is NOT gated by
# this: set_tab_title emits the iTerm2 escapes unconditionally at launch, and
# the colour resets when the session exits. Under tmux it also starts claude
# as found on PATH and with tmux's TERM_PROGRAM, so the tab gets no progress
# line and no Claude icon.
export CS_NO_ITERM2="1"

# Leave the Task tools to Claude Code's model default. An ags launch exports
# CLAUDE_CODE_ENABLE_TODO_TOOLS=1 because Claude Code 2.1.233+ withholds
# TaskCreate/TaskList/TaskUpdate/TaskGet on Opus 4.8, Sonnet 5 and Fable 5,
# and the rotation wake, the walk-away drain and the rotate skill all address
# the native task list. Set this to get the context those tool definitions
# cost back; the drain and the handoff then coordinate by message text alone.
export CS_NO_TASK_TOOLS="1"

# Launch without CLAUDE_CODE_ENABLE_FUNCTION_HOOKS, even when the shell
# carries it. An ags launch exports it so the rotate mod the installer deployed
# (the "1: rotate this conversation" button past 65% context) loads; the flag
# also loads any other function-hooks plugin on the machine. Without this knob
# ags keeps a value already in the shell (0 keeps function hooks off).
export CS_NO_FUNCTION_HOOKS="1"

# Override the tmux binary ags -spawn uses (default: tmux on PATH)
export CS_TMUX_BIN="/opt/homebrew/bin/tmux"

# The tmux session ags -spawn opens its windows in (default: cs). The profile
# launcher sets ags. A name with ':' or '.' is refused: tmux would not keep it.
export CS_TMUX_SESSION="cs"

# The tmux server ags -spawn and the doctor's spawn check use, as a tmux -L
# socket name (default: unset, the default server). A window runs with its
# server's environment, not the spawner's, so the profile launcher sets ags:
# on the default server a spawned profile session would run as the stable
# install, and a server the profile started would hand the profile's
# variables to every later window. The attach hint names it
# (tmux -L ags attach -t ags).
export CS_TMUX_SOCKET="ags"

# Force the detected platform instead of probing for it; any other
# value is rejected. Read by ags -secrets only, to choose between the
# macOS keychain and the encrypted file
export CS_PLATFORM_OVERRIDE="linux"   # macos, wsl, or linux
```

## Option-key bindings

The installer offers, once per machine, to bind two keys in Claude Code's
`keybindings.json` (in `$CLAUDE_CONFIG_DIR` when you set it, otherwise
`~/.claude/keybindings.json`). Run inside an encrypted session, where
`CLAUDE_CONFIG_DIR` is the session's `.cs/claude-config`, cs writes the shell's
file instead, the one that session links:

```json
{"bindings": [{"context": "Global", "bindings": {"alt+1": "command:rotate", "alt+2": "command:wrap"}}]}
```

Option+1 then submits `/rotate` and Option+2 submits `/wrap`. The terminal has
to send Option as Meta for the key to arrive as `alt+1`: in iTerm2, set the
profile's Option key to Esc+; in Terminal.app, turn on "Use Option as Meta key".

- A yes merges the two keys into the file's first `Global` block (or adds one,
  creating the file when there is none). cs never replaces a key you already
  bind to something else, in any context: it keeps your action and names the
  key in a warning. cs refuses a file that is not JSON with a `bindings` array
  and leaves it untouched.
- The installer records the answer in `~/.config/cs/option-keys` (`yes` or
  `no`; `$XDG_CONFIG_HOME/cs/option-keys` when you set that). After a `no` it
  never asks again. After a `yes`, every install and `ags -update` adds back
  either key if nothing binds it.
- With no terminal attached (CI, a pipe) the installer asks nothing, writes
  nothing and records nothing; it prints one line saying to run `ags -update` in
  a terminal.
- To change the answer, remove `~/.config/cs/option-keys` and run `ags -update`
  (or `./install.sh`) in a terminal; it asks again. To drop the keys after a
  `yes`, answer `no` there and delete the two entries from `keybindings.json`.
- `ags -uninstall` removes only the keys that still hold ags's values, drops a
  `Global` block that leaves empty, deletes the file when it holds nothing else
  (a symlinked file keeps its link and gets `{"bindings": []}` written through
  it), and removes the recorded answer.
- `ags -doctor` reports one row: bound, declined, not asked, a conflict on
  `alt+1` or `alt+2`, or an unparseable file.

## In-session switches

The release-notes pane is a Claude Code `/config` row, `cs-update.showReleaseNotes`
(on by default). Off, a launch opens no pane; `/cs-update` still opens it.
The launch banner's compact notes card draws only when `CS_NO_FUNCTION_HOOKS=1`
or `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0` withholds the mod, since otherwise
the mod shows the full notes in the session.

## Environment variables ags sets for you

These are exported automatically when you start a session, so the Claude Code
process and its hooks can find the session:

- `CS_SESSION_NAME` - The session name (e.g., `myproject`); legacy `CLAUDE_SESSION_NAME` is accepted
- `CS_CLAUDE_SESSION_ID` - The conversation UUID ags launched or resumed, exported so hooks can tell the launched conversation from any other claude that resolves the same session
- `CS_REAL_EDITOR` - Your own `$EDITOR`, captured before ags repoints `EDITOR`/`VISUAL` at the prompt-rewriter shim. The shim hands every file that is not a composer buffer back to it, so `/memory` and commit messages still open your editor. Set it yourself to pin which editor that is
- `CS_SECRETS_SESSION` - For a worktree session, the base session its secrets key to, so a feature worktree reads the same store as its parent (see [secrets.md](secrets.md))
- `CS_SESSION_DIR` - Full path to the session directory (workspace root)
- `CS_SESSION_META_DIR` - Path to the `.cs/` metadata directory
- `CLAUDE_CODE_TASK_LIST_ID` - Set to the session name for task list persistence; a feature worktree gets its own list under its `base@task` name, not the base's
- `CLAUDE_CODE_AUTO_MEMORY_PATH` / `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` - Redirect Claude Code's auto-memory writer into `<session>/.cs/memory/`
- `AGS_BIN` - Exported by every ags launch, never set by hand: the absolute path of the running ags executable, replacing any value inherited from a parent launch. The TUI and Claude Code mods prefer this pointer when calling ags because Claude Code's `PATH` may differ from the launching shell's
- `CS_BIN` - Exported alongside `AGS_BIN` as a compatibility pointer to that same executable path. Existing integrations can keep reading it; new integrations should use `AGS_BIN`
- `CS_UPDATE_AVAILABLE` - Exported by an ags launch, never set by hand: the version a newer cs was found at. The cs-update mod reads it to draw the release-notes pane. Absent when nothing is pending

## Adapter installation

`CS_INSTALL_ENGINES=claude|codex|claude,codex` selects installer payloads. With
no explicit selection, install.sh reads `$HOME/.local/bin/.cs-install-engines`
or defaults to both adapters for legacy compatibility. The file contains plain
engine identifiers; it is never executed as shell code. Previously installed
adapters remain recorded so future updates maintain their deployed integrations.
See [Migration](migration.md) for the compatibility policy.

`CS_HOOK_PATHS=absolute` makes install.sh register its hook commands in
`settings.json` by absolute path instead of `~/.claude/hooks/cs/...`. setup.sh
sets it for the profile, whose launcher keeps the user's HOME: a tilde there
would run the stable install's hooks.

## Your own setup in the ags profile

setup.sh ends by running `scripts/ags-carry-over.sh`, which brings your own
Claude and Codex setup from `~/.claude`, `~/.claude.json` and `~/.codex` into
the profile at `~/.local/share/agent-sessions/home`. It reads those and writes
only inside the profile. Every path comes from `HOME`: inside an ags session
`CLAUDE_CONFIG_DIR`, `CODEX_HOME` and the `CS_*` variables name the profile.

- **Linked**, one symlink per entry, so an edit in `~/.claude` or `~/.codex`
  shows in ags at once: `CLAUDE.md`, `keybindings.json`, and the entries of
  `agents/`, `commands/`, `skills/`, `workflows/`, `themes/` and
  `output-styles/`; for Codex, `AGENTS.md` and the entries of `skills/` and
  `agents/`. A skill directory holding `.claude-plugin/`, such as the Agents
  sidebar's, loads there as a plugin too.
- **Skipped**: every name ags installs itself, read from the installer's own
  lists (the skills, mods, retired skills and retired commands that uninstall
  removes), Claude Code's `skills/synced`, dot entries, and backups
  (`*.pre-*`, `*.before-*`).
- **Merged** into the profile's own files, adding what is missing and never
  replacing or removing what the profile has: hooks in `settings.json` (except
  cs's own under `~/.claude/hooks/cs/`), `enabledPlugins`,
  `extraKnownMarketplaces`, `permissions` (lists are joined), `modelSettings`,
  `env` and your other preference keys; `mcpServers` in the profile's
  `.claude.json`; for Codex, `hooks.json`, the `[mcp_servers.*]` tables and
  `[sandbox_workspace_write]` in `config.toml`. A profile value of another
  shape than yours (a string where you have a list) stays as it is. A Codex
  MCP server you defined inline (`mcp_servers.x = {...}`) cannot be copied as
  a table; every run names it so you can copy it by hand.
- **Hooks** are told apart by event, matcher and command, so one command under
  two matchers is two hooks. The hooks a run adds are listed in
  `.ags-carried-hooks.json` beside `settings.json` and `hooks.json`. One you
  later change or remove in `~/.claude` or `~/.codex` leaves the profile on
  the next run, so an old and a new version never both run. A hook the profile
  had before is never removed.
- **Left as the profile's**: `model`, `theme`, `tui` (setup carries that once
  itself), `statusLine`, `subagentStatusLine`, `disableAllHooks`, the login
  helpers (`apiKeyHelper`, `awsAuthRefresh`, `awsCredentialExport`,
  `gcpAuthRefresh`, `otelHeadersHelper`, `forceLoginMethod`,
  `forceLoginOrgUUID`), project-scoped MCP servers and plugins, and Codex's
  top-level keys and other tables.
- **Plugins**: each enabled plugin you installed at user scope is copied from
  `~/.claude/plugins/cache` into the profile's cache (a clone on APFS, so it
  takes no space), with its marketplace when the profile lacks it, and recorded
  in the profile's `installed_plugins.json`. Nothing is downloaded, and the
  profile updates them on its own from then on.
- **Codex hooks** are added after ags's own and trusted in the profile's
  `config.toml` only when `~/.codex/config.toml` trusts the definition the
  profile holds. One you never reviewed stays untrusted, and Codex skips it
  until you do. Codex keys trust by a hook's position, so when a carried hook
  leaves, the trust of the hooks after it moves with them. `hooks.json` is
  written only together with a `config.toml` that parses.
- **The Agents sidebar**: when your `statusLine` is the sidebar's
  `statusline-bridge.sh`, the profile's status line moves inside the bridge
  too, and the profile's own line (`ags-statusline`) is kept in
  `agents-sidebar-status/original-statusline` inside the profile's `.claude`.
  The bridge draws that line when `CLAUDE_CONFIG_DIR`, or in an encrypted
  session `CLAUDE_SECURESTORAGE_CONFIG_DIR`, names the profile; a bridge
  without that check draws the line `~/.claude` displaced instead. The wrap
  happens once: a status line you give the profile later stays (answer `y`
  when setup offers ags-statusline, or run `ags -statusline enable`); delete
  that file to wrap it again.

A rerun adds what is new and changes nothing else: a file whose content would
not change is not rewritten, and the first change to each profile file leaves a
copy at `<file>.pre-carry-over`. A link or a carried hook whose entry you
removed from `~/.claude` or `~/.codex` goes with it. An MCP server, plugin or
preference you remove or change there stays in the profile as it was; change
it in the profile by hand.

Remote MCP servers sign in per configuration directory, so one you authorised in
`~/.claude` or `~/.codex` asks again in the profile: `/mcp` in an ags Claude
session, or `CODEX_HOME=~/.local/share/agent-sessions/home/.codex codex mcp login <name>`
for Codex. Run the carry-over with no ags Claude session open: a running
session can save its own copy of `.claude.json` over the merged servers, and a
rerun puts them back.

```bash
bash scripts/ags-carry-over.sh --dry-run   # what it would change; writes nothing
bash scripts/ags-carry-over.sh             # run it alone, without reinstalling
sh ./setup.sh --no-carry-over              # install without it; or AGS_CARRY_OVER=0
```

Before it installs, setup.sh also runs `scripts/ags-carry-over.sh --prune`,
with or without the opt-out. It removes the carried links that dangle, or that
a name ags now installs shadows, so the install never copies ags's files
through a link into your own directories.
