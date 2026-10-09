# code-sessions migration and compatibility

**code-sessions** is a fork of `claude-sessions` (cs), a persistent workspace
manager, with first-party Claude and Codex adapters. It keeps cs's names: the
command is `cs` inside its sessions, and its messages, skills and mods say cs.
In a terminal it starts as `code-sessions`, or `ccs` for short, so `cs` there
stays the original. The upstream GitHub repository and release/download URLs
remain `hex/claude-sessions`; the fork is not published.

## Deliberate compatibility policy

`setup.sh` keeps the original global `cs` installation and deploys the fork
under `~/.local/share/code-sessions/home/`. Only the `code-sessions` and `ccs`
launchers are exposed globally. Existing sessions are not migrated. Native CLI
login is separate in the profile. Setup carries the user's own Claude and Codex
setup in without writing to `~/.claude` or `~/.codex`: instructions, agents,
skills and commands by link, hooks, plugins, MCP servers and preferences by
merge (see [Your own setup in the code-sessions
profile](configuration.md#your-own-setup-in-the-code-sessions-profile)), and it
copies the Claude display mode (`tui`) from `~/.claude/settings.json` when the
profile has none. Direct `install.sh` refuses to replace a `cs` executable that
is not code-sessions' own build; use `setup.sh`.

| Surface | Current policy |
| --- | --- |
| Public executable | Launchers: `code-sessions` and `ccs` in `~/.local/bin`; inside the profile the command is `cs`. The global original `cs` stays independent. |
| Companion executables/package | Upstream's names, inside the profile only: `cs-secrets`, `cs-codex-thread`, `cs-statusline`, `cs-subagent-statusline`, and `cs-tui`. |
| Workspace records | Keep `.cs/`, machine-local `.cs/local/`, and tracked-versus-local rules. |
| Default discovery root | The source default remains `~/.claude-sessions/`. Setup's launcher keeps HOME as the user's own (macOS finds the login keychain through it, and `~/.ssh` and the other credentials stay visible) and points each tool at the profile through its own directory variable: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CS_SESSIONS_ROOT`, `CS_INSTALL_DIR`, `CS_CONFIG_DIR`, `CS_CACHE_DIR`, `CS_DATA_DIR` (where `cs -encrypt` makes its containers; the original install's stay in `~/.local/share/cs/vaults`, and so do any the profile made before it had its own, which keep opening from there because each session records its container's path) and `CS_SECRETS_DIR`. For the same reason the profile's `settings.json` registers hook commands by absolute path (`CS_HOOK_PATHS=absolute` at install time) rather than `~/.claude/hooks/cs/...`, which would resolve to the original install's hooks. The launcher also sets `CS_TMUX_SOCKET=code-sessions` and `CS_TMUX_SESSION=code-sessions`, so `cs -spawn` opens its windows in session `code-sessions` on a tmux server of its own (`tmux -L code-sessions attach -t code-sessions`). A tmux window runs with its server's environment, not the spawner's: on the default server a spawned window would run with the original install's directories, and a server the fork started would hand the profile's variables to the original's `cs -spawn` windows. Secrets go to the macOS keychain, as in the original install, but the launcher's `CS_SECRETS_KEYCHAIN_PREFIX=code-sessions` names the profile's items `code-sessions:<session>:<name>` beside the original's `cs:<session>:<name>`, so a session both installs have keeps two separate sets, and `cs -list` and the picker count each install's own. The launcher drops a `CS_SECRETS_BACKEND` inherited from the calling shell; where there is no keychain, the encrypted store lives in the profile's `.cs-secrets/`. Setup moves secrets an earlier profile kept in `.cs-secrets/<session>.enc` into the keychain, once per file: never onto an item the keychain already has, and not while that session or one of its features is open (rerun setup.sh after closing it). The profile's sessions root is `sessions/`, since it holds Claude and Codex sessions alike; rerunning setup.sh moves an earlier profile's `.claude-sessions/` there once. The move renames the Claude transcript folders, the Claude and Codex trusted-folder entries and the git worktree links of the session directories that moved (a symlinked session keeps its paths), and it waits until no profile command is running. |
| Engine choice | Explicit `--engine`, saved session choice, `CS_DEFAULT_ENGINE`, sole installed Codex adapter, then Claude. Legacy and dual-adapter installs retain Claude by default. |
| Session environment | `CS_SESSION_NAME`, `CS_SESSION_DIR`, `CS_SESSION_META_DIR` are canonical. Shared commands and secrets accept legacy `CLAUDE_SESSION_*` callers. Launches refresh both sets together. |
| Fork marker | The launcher exports `CODE_SESSIONS_HOME`, the profile's path. With it set, `cs -update` and `cs -uninstall` refuse, since the fork's release address is the original cs's; tools such as branch-out read it to tell the fork from the original. `CS_BIN` is the launch-time path of the profile's `cs`. |
| Native bindings | Preserve independent Claude UUID and Codex thread ID through the shared binding API over existing local formats. Switching engines never converts native transcripts. |
| Other compatibility namespaces | Keep Keychain/secret identifiers, recovery refs, configuration/cache paths, hook sentinels, native Claude command names, and native mod IDs such as `cs` and `cs-update`. |
| Version output | `cs -version` prints `cs <version> (code-sessions, a fork of cs)`, and help names the `ccs` launcher. The version is upstream's release the fork last merged. |

No session migration command is needed. Use `ccs <name>` to resume an existing
workspace; use `ccs <name> --engine codex` to select Codex. The engine
preference is recorded only when startup preparation succeeds. Return with
`--engine claude`. Both engines read the shared notes, but their native
histories remain independent.

## Provider-specific preparation

Core creation, adoption, migration, and worktrees prepare the portable `.cs/`
workspace and then call the selected adapter's `prepare_workspace` operation.
Codex does not write `AGENTS.md`, Claude instructions/settings, or Claude memory
configuration, and does not allocate Claude UUID/color. Opening that workspace
with Claude prepares its own native integration. Existing Claude configuration
is preserved on Codex opens rather than removed. Claude's existing instruction
migration and resume behavior are retained behind its adapter.

```bash
ccs investigate --engine codex
ccs -adopt existing-project --engine codex
ccs existing-project@worker --engine codex
ccs investigate --engine claude
```

## Installation and updates

From this checkout:

```bash
CS_INSTALL_ENGINES=codex sh ./setup.sh          # core and Codex bootstrap helper
CS_INSTALL_ENGINES=claude sh ./setup.sh         # core and Claude integrations
CS_INSTALL_ENGINES=claude,codex sh ./setup.sh    # both (fresh-install default)
```

A fresh Codex-only install leaves the profile's `.claude/` untouched. Setup
always preserves the user's original `~/.claude/`. Inside the profile, the installer records
installed adapters in `.local/bin/.cs-install-engines` (the directory `CS_INSTALL_DIR` names at run time) and
reuses that record when no selection is supplied. Rerun `setup.sh` to update;
inside the profile `cs -update` and `cs -uninstall` refuse.
Selections add or refresh adapters; they do not uninstall previously deployed
adapters. The record retains their union so later updates maintain them.
`cs -uninstall` uses the record to remove deployed integration (inside the
profile's launcher it refuses, as said above); a Codex-only record leaves Claude
settings and integrations alone. Old installations with no record follow the
existing uninstall behavior.

The selection controls packaged integrations, not access to executables: the
core registry still knows both first-party adapters. A Claude-only install
needs a Codex-enabled reinstall before launching Codex, since the bootstrap
helper is required. Native runtime installation/authentication remains the
user's configuration. Nothing is installed globally by the development tests.

The fork is unpublished. Upstream releases install the original cs; that is why
`cs -update` refuses inside the profile, where it would replace this local
build with the upstream release.

## Moving an ags profile

Before it was called code-sessions the fork was `ags` (agent-sessions), with
its profile in `~/.local/share/agent-sessions/home/` and `ags` launchers in
`~/.local/bin`. The first `sh setup.sh` of code-sessions moves that profile
over once, after the build and before the install:

- The profile directory moves to `~/.local/share/code-sessions/home/`, with its
  sessions, Claude and Codex logins, history and secrets. The emptied
  `agent-sessions` folder goes.
- The commands named ags inside the profile (`ags`, `ags-statusline` and the
  rest, and their `cs` links) are removed, and the install writes the `cs` ones
  in their place. Settings, hooks, trust and history files that name the old
  profile by its path, or a helper by its ags name, are rewritten, under both
  the physical path and the one setup was given. The Claude transcript folders
  named after a session inside the profile are renamed, and worktree sessions
  are repaired with `git worktree repair`.
- Each session's `CLAUDE.local.md`, a linked one in its own folder too, has its
  protocol reworded from `ags` to `cs` (`ags -secrets` becomes `cs -secrets`,
  and so on). Text above the protocol's first `<!-- cs:` sentinel is left as it is.
- The `ags` launchers in `~/.local/bin` are removed, but only those that name
  `share/agent-sessions/home`; a file of yours that merely starts with `ags-`
  stays. The `agent-sessions PATH` block in a shell startup file counts as the
  `code-sessions` one.

Setup refuses while a process runs from the old profile's bin (close every ags
session first) and when both profiles exist.

## Copying a cs session into code-sessions

`cs -adopt` refuses a folder that already has `.cs/`, so a project the
original cs adopted cannot simply be adopted again. `scripts/cs-to-code-sessions.py`
gives code-sessions a copy of it instead, so `ccs <name>` opens it on the
conversations the original cs left off with. The two never share a folder. It
prints what it would do; `--apply` does it:

```bash
scripts/cs-to-code-sessions.py --session wap            # the plan; nothing is written
scripts/cs-to-code-sessions.py --session wap --apply    # rerun later to bring over what cs did since
```

- The project is copied whole into the profile's sessions root: its
  repository, `.cs/`, `node_modules`, ignored and untracked files. On APFS the
  copy is a clone, which costs no space until either side writes. From then on
  it is code-sessions's own repository.
- Each feature worktree (`<name>@<task>`) is copied beside it as a linked
  worktree of the copy's repository, on the same branch, with its index,
  uncommitted changes and per-worktree refs. A link that points into the
  original's folders by an absolute path (a `node_modules` or `.env` shared
  with the project) is pointed at the copy instead, so nothing writes through it.
- Each session's Claude conversations are copied from `~/.claude/projects` into
  the profile's, under the folder name of the copy's path, whole: subagents,
  workflows, tool results. Their `file-history`, `session-env` and task list
  come too, and the session's lines of `history.jsonl` (the prompt history),
  pointed at the copy.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more. They come too, as history; `--no-history`
  leaves them out.
- Trust and per-project settings in `~/.claude.json` and `~/.codex/config.toml`
  are copied into the profile's under the copy's paths, without overwriting
  what the profile has. While a code-sessions session runs, these two files are
  left and a rerun brings them.
- Secrets are copied from the original's store into the profile's, values on
  stdin: from the keychain's `cs:<session>:<name>` items to its
  `code-sessions:<session>:<name>` ones.

Nothing outside the profile is written: `~/.claude-sessions`, the project and
its feature folders, `~/.claude`, `~/.claude.json`, `~/.codex` and the
original's keychain items are only read, and git runs there only to read. The
keychain gains only the profile's own `code-sessions:` items. The session protocol in
`CLAUDE.local.md` comes over as it is: both sides word it for cs. A session or
feature open in the original cs while the script runs is named: what it writes
afterwards comes over on a rerun.

A rerun brings over what the original cs changed since the last run, wherever
code-sessions left the same thing alone, and keeps what code-sessions changed:

- Branches: the original's are fetched into the copy as `refs/remotes/cs/*`. A
  branch code-sessions did not move since is moved to the original's commit,
  and one code-sessions moved too is fast-forwarded when it is strictly behind;
  otherwise code-sessions's is kept and the branch is reported.
- A worktree's HEAD and index: taken from the original when the copy's did not
  change, staged blobs included. When both changed, git is left as the copy has
  it and only that worktree's `.cs/` is brought over until git agrees again
  (for example after a reset onto `refs/remotes/cs/<branch>` in the copy); the
  original's other changes stay pending meanwhile, not dropped. That is
  reported once per change on the original's side.
- Files: one the original changed is copied where the copy did not change it,
  and a file the original deleted is deleted in the copy. A file changed on
  both sides keeps the copy's and is reported once. `.cs/local/state` is
  merged key by key.
- Features the original started since are copied, unless their branch is
  checked out in the copy already or their commit is on no branch the copy's
  repository has; one the original finished stays in the copy, and one whose
  copy code-sessions removed is not copied again.
- Conversations that grew in the original are brought over when the copy is
  an unchanged start of them; one continued on both sides is reported.
- A secret whose value differs is reported and never overwritten, and its
  value is never shown.

Which files changed is told by their inode change time (ctime), which only the
kernel sets: the profile's `.cs-to-code-sessions/<name>/` keeps a mark per side,
taken before that side is read, the ctimes of the script's own writes, and the
paths both sides had at the last sync, so a deletion is told from an addition.
A file the copy changes while the script runs is left as it is. Should that
record lose its path list, the script stops rather than bring back files the
copy deleted. Every change goes to `.cs-to-code-sessions/log.jsonl`, with up
to 1000 of the files kept on both sides.

The script leaves these behind and names each one: an encrypted session, a
session the original created in its own folder, a project whose `.git` is not a
folder, a feature folder git does not list as a worktree, and a name
code-sessions already uses for something else. Anything left behind or kept on
both sides makes the run exit 1. The first open in code-sessions runs one full
migration, because the original's stamp names no engine. The copy lives under
the profile, so the directory commands (`ccs .`, `-checkpoint`, `-narrative`)
work inside it.

## Going back to cs

`scripts/code-sessions-to-cs.py` gives the original cs a copy of the profile's
work, so every code-sessions session opens with `cs <name>` and resumes the
same Claude conversation. It prints what it would do; `--apply` copies:

```bash
scripts/code-sessions-to-cs.py              # the plan; nothing is written
scripts/code-sessions-to-cs.py --apply
```

- Every session is copied whole into `~/.claude-sessions`, wherever the
  profile keeps it, a project code-sessions adopted included, git history and
  local state with it.
- A feature worktree (`<base>@<task>`) becomes a linked worktree of its base's
  copy, under the base's cs name, on the same branch with its index,
  uncommitted changes and per-worktree refs; the original stays a worktree of
  the original. `--session <base>@<task>` alone works once the base is in cs.
- Each session's Claude conversations and their file-history snapshots are
  copied from the profile into `~/.claude`, under the folder Claude Code gives
  the copy's path.
- Secrets go from the profile's keychain items (`code-sessions:<session>:<name>`)
  into the store `cs-secrets` reads, values on stdin. One whose value differs
  is reported, never overwritten.

The profile is only read, and git runs there only to read, so code-sessions
keeps working. When cs already has a session of that name, the code-sessions
one arrives as `<name>-ccs`; `--rename OLD=NEW` picks another name and
`--session NAME` copies one session. A rerun brings over what code-sessions
changed since, by the same rules as above with the sides swapped: what cs
changed in its copy is kept, and something changed on both sides keeps cs's and
is reported once. A copy cs removed is not made again. The record of the last
sync lives in `~/.claude-sessions/.code-sessions-to-cs/`. A copy made before
this record existed is named and left; move it aside and rerun.

The script leaves these behind and names each one: a session open in
code-sessions (close it, then rerun), an encrypted session (its vault needs its
password and links into the profile), a feature worktree whose base is not
copied, and Codex threads (cs has no Codex engine; resume one with
`CODEX_HOME=~/.local/share/code-sessions/home/.codex codex resume <id>`).
Anything left behind makes the run exit 1. Paths come from `HOME` and the
options, never from `CS_*` variables, which name the profile inside a
code-sessions session.

## Remaining compatibility decisions

- The fork keeps upstream's command, data root and `.cs/` metadata names, so
  upstream merges stay plain and nothing in an existing workspace or machine
  configuration needs migrating. Only the launchers carry the fork's name.
- Claude retains its quick failed-resume fallback and legacy transcript
  discovery; Codex refuses to replace a failed exact binding. Unifying resume,
  fresh, and handoff policy requires a lifecycle change with recoverable binding
  transitions, not a naming edit.
- Keep one interactive owner per workspace. Shared run leases, stale-hook
  protection, and normalized events remain to be extracted from Claude hooks.
- Codex's bootstrap uses the existing verified experimental app-server
  protocol for `0.158.0-alpha.2.1`. Supported runtime versions and a live event
  bridge require compatibility investigation before advertising automation.
- Claude owns native recovery, rotation, unattended queue/mail delivery,
  telemetry, and terminal mods. Codex can use shared storage and manual status;
  its runtime usage/state remains unavailable. Conversation listings and TUI
  observations still need engine-qualified views. Unknown Codex telemetry must
  not be interpreted as zero usage or an observed idle state.

See [Engine adapters](engine-adapters.md) for the implemented contract and
[Codex sessions](codex.md) for current runtime limitations.
