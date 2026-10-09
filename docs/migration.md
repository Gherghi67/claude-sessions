# agent-sessions migration and compatibility

`claude-sessions` is now branded **agent-sessions**, a persistent workspace
manager with first-party Claude and Codex adapters. The product directory can
be named `agent-sessions/`. The upstream GitHub repository and release/download
URLs remain `hex/claude-sessions`; this local rebrand does not publish a rename.

## Deliberate compatibility policy

`ags` is the primary executable and the documented command name. `setup.sh`
keeps the original global `cs` installation and deploys the experimental build
under `~/.local/share/agent-sessions/home/`. Only `ags` names are exposed globally.
Compatibility aliases inside that private payload support its own integrations.
Existing sessions are not migrated. Native CLI login is separate in the
experimental profile. Setup carries the user's own Claude and Codex setup in
without writing to `~/.claude` or `~/.codex`: instructions, agents, skills and
commands by link, hooks, plugins, MCP servers and preferences by merge (see
[Your own setup in the ags profile](configuration.md#your-own-setup-in-the-ags-profile)),
and it copies the Claude display mode (`tui`) from `~/.claude/settings.json`
when the profile has none. Direct `install.sh` refuses
to replace an existing original `cs` executable; use `setup.sh`.

| Surface | Current policy |
| --- | --- |
| Public executable | Primary: `ags`; compatibility alias: `cs` inside the private payload. The global original `cs` stays independent. |
| Companion executables/package | Primary names: `ags-secrets`, `ags-codex-thread`, `ags-statusline`, `ags-subagent-statusline`, and `ags-tui`. Legacy companion names remain aliases where installed. |
| Workspace records | Keep `.cs/`, machine-local `.cs/local/`, and tracked-versus-local rules. |
| Default discovery root | The source default remains `~/.claude-sessions/`. Setup's launcher keeps HOME as the user's own (macOS finds the login keychain through it, and `~/.ssh` and the other credentials stay visible) and points each tool at the experimental profile through its own directory variable: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CS_SESSIONS_ROOT`, `CS_INSTALL_DIR`, `CS_CONFIG_DIR`, `CS_CACHE_DIR`, `CS_DATA_DIR` (where `ags -encrypt` makes its containers; the stable install's stay in `~/.local/share/cs/vaults`, and so do any the profile made before it had its own, which keep opening from there because each session records its container's path) and `CS_SECRETS_DIR`. For the same reason the profile's `settings.json` registers hook commands by absolute path (`CS_HOOK_PATHS=absolute` at install time) rather than `~/.claude/hooks/cs/...`, which would resolve to the stable install's hooks. The launcher also sets `CS_TMUX_SOCKET=ags` and `CS_TMUX_SESSION=ags`, so `ags -spawn` opens its windows in session `ags` on a tmux server of its own (`tmux -L ags attach -t ags`). A tmux window runs with its server's environment, not the spawner's: on the default server a spawned `ags` would run with the stable install's directories, and a server `ags` started would hand the profile's variables to stable `cs -spawn` windows. The launcher's `CS_SECRETS_BACKEND=encrypted` keeps secrets out of the shared keychain, and `ags -list` and the picker then show no secret counts rather than the stable install's keychain counts for a session of the same name. The profile's sessions root is `sessions/`, since it holds Claude and Codex sessions alike; rerunning setup.sh moves an earlier profile's `.claude-sessions/` there once. The move renames the Claude transcript folders, the Claude and Codex trusted-folder entries and the git worktree links of the session directories that moved (a symlinked session keeps its paths), and it waits until no profile command is running. |
| Engine choice | Explicit `--engine`, saved session choice, `CS_DEFAULT_ENGINE`, sole installed Codex adapter, then Claude. Legacy and dual-adapter installs retain Claude by default. |
| Session environment | `CS_SESSION_NAME`, `CS_SESSION_DIR`, `CS_SESSION_META_DIR` are canonical. Shared commands and secrets accept legacy `CLAUDE_SESSION_*` callers. Launches refresh both sets together. |
| Executable pointer | `AGS_BIN` is the canonical launch-time path used by the TUI and mods; `CS_BIN` remains exported with the same path for compatibility. Existing `CS_*` configuration keys and storage namespaces stay unchanged. |
| Native bindings | Preserve independent Claude UUID and Codex thread ID through the shared binding API over existing local formats. Switching engines never converts native transcripts. |
| Other compatibility namespaces | Keep Keychain/secret identifiers, recovery refs, configuration/cache paths, hook sentinels, native Claude command names, and native mod IDs such as `cs` and `cs-update`. Branding does not migrate or erase these. |
| Version output | Both entrypoints identify agent-sessions; help and installer document `ags` as primary. The release version is unchanged until publication. |

No session migration command is needed. Use `ags <name>` to resume an existing
workspace (or `cs <name>` in an old script); use `ags <name> --engine codex` to
select Codex. The engine preference is recorded only when startup preparation
succeeds. Return with `--engine claude`. Both engines read the shared notes, but
their native histories remain independent.

## Provider-specific preparation

Core creation, adoption, migration, and worktrees prepare the portable `.cs/`
workspace and then call the selected adapter's `prepare_workspace` operation.
Codex does not write `AGENTS.md`, Claude instructions/settings, or Claude memory
configuration, and does not allocate Claude UUID/color. Opening that workspace
with Claude prepares its own native integration. Existing Claude configuration
is preserved on Codex opens rather than removed. Claude's existing instruction
migration and resume behavior are retained behind its adapter.

```bash
ags investigate --engine codex
ags -adopt existing-project --engine codex
ags existing-project@worker --engine codex
ags investigate --engine claude
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
the public experimental launcher disables upstream updates and uninstall.
Selections add or refresh adapters; they do not uninstall previously deployed
adapters. The record retains their union so later updates maintain them.
`ags -uninstall` uses the record to remove deployed integration; a Codex-only
record leaves Claude settings and integrations alone. Old installations with
no record follow the existing uninstall behavior.

The selection controls packaged integrations, not access to executables: the
core registry still knows both first-party adapters. A Claude-only install
needs a Codex-enabled reinstall before launching Codex, since the bootstrap
helper is required. Native runtime installation/authentication remains the
user's configuration. Nothing is installed globally by the development tests.

This branch is unpublished. Existing upstream releases still use their original
branding and installer behavior; running `ags -update` before publishing these
changes can replace this local build with the upstream release.

## Opening a cs session in ags

`ags -adopt` refuses a folder that already has `.cs/`, so a project the
stable `cs` adopted cannot simply be adopted again. `scripts/cs-to-ags.py`
gives ags a copy of it instead, so `ags <name>` opens it on the conversations
`cs` left off with. The two never share a folder. It prints what it would do;
`--apply` does it:

```bash
scripts/cs-to-ags.py --session wap            # the plan; nothing is written
scripts/cs-to-ags.py --session wap --apply    # rerun later to bring over what cs did since
```

- The project is copied whole into the profile's sessions root: its
  repository, `.cs/`, `node_modules`, ignored and untracked files. On APFS the
  copy is a clone, which costs no space until either side writes. From then on
  it is ags's own repository.
- Each feature worktree (`<name>@<task>`) is copied beside it as a linked
  worktree of the copy's repository, on the same branch, with its index,
  uncommitted changes and per-worktree refs. A link that points into `cs`'s
  folders by an absolute path (a `node_modules` or `.env` shared with the
  project) is pointed at ags's copy instead, so nothing writes through it.
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
  what the profile has. While an ags session runs, these two files are left and
  a rerun brings them.
- Secrets are copied from the stable store into the profile's encrypted store,
  values on stdin.

Nothing outside the profile is written: `~/.claude-sessions`, the project and
its feature folders, `~/.claude`, `~/.claude.json`, `~/.codex` and the keychain
are only read, and git runs there only to read. The session protocol in
`CLAUDE.local.md` keeps the `cs` wording, which works inside ags too, since the
profile ships `cs` as `ags`. A session or feature open in `cs` while the script
runs is named: what it writes afterwards comes over on a rerun.

A rerun brings over what `cs` changed since the last run, wherever ags left the
same thing alone, and keeps what ags changed:

- Branches: `cs`'s are fetched into the copy as `refs/remotes/cs/*`. A branch
  ags did not move since is moved to `cs`'s commit, and one ags moved too is
  fast-forwarded when it is strictly behind; otherwise ags's is kept and the
  branch is reported.
- A worktree's HEAD and index: taken from `cs` when ags's did not change,
  staged blobs included. When both changed, git is left as ags has it and only
  that worktree's `.cs/` is brought over until git agrees again (for example
  after ags resets onto `refs/remotes/cs/<branch>`); `cs`'s other changes stay
  pending meanwhile, not dropped. That is reported once per change on the `cs`
  side.
- Files: one `cs` changed is copied where ags did not change it, and a file
  `cs` deleted is deleted in the copy. A file changed on both sides keeps ags's
  and is reported once. `.cs/local/state` is merged key by key.
- Features `cs` started since are copied, unless their branch is checked out
  in ags already or their commit is on no branch ags's repository has; one
  `cs` finished stays in ags, and one whose copy ags removed is not copied
  again.
- Conversations that grew in `cs` are brought over when the ags copy is an
  unchanged start of them; one continued on both sides is reported.
- A secret whose value differs is reported and never overwritten, and its
  value is never shown.

Which files changed is told by their inode change time (ctime), which only the
kernel sets: the profile's `.cs-to-ags/<name>/` keeps a mark per side, taken
before that side is read, the ctimes of the script's own writes, and the paths
both sides had at the last sync, so a deletion is told from an addition. A
file ags changes while the script runs is left as ags has it. Should that
record lose its path list, the script stops rather than bring back files ags
deleted. Every change goes to `.cs-to-ags/log.jsonl`, with up to 1000 of the
files kept on both sides.

The script leaves these behind and names each one: an encrypted session, a
session `cs` created in its own folder, a project whose `.git` is not a folder,
a feature folder git does not list as a worktree, and a name ags already uses
for something else. Anything left behind or kept on both sides makes the run
exit 1. The first `ags` open runs one full migration, because the stable `cs`
stamp names no engine. The copy lives under the profile, so the directory
commands (`ags .`, `-checkpoint`, `-narrative`) work inside it.

## Going back to cs

`scripts/ags-to-cs.py` gives the stable `cs` a copy of the profile's work, so
every ags session opens with `cs <name>` and resumes the same Claude
conversation. It prints what it would do; `--apply` copies:

```bash
scripts/ags-to-cs.py              # the plan; nothing is written
scripts/ags-to-cs.py --apply
```

- Every session is copied whole into `~/.claude-sessions`, wherever ags keeps
  it, a project ags adopted included, git history and local state with it.
- A feature worktree (`<base>@<task>`) becomes a linked worktree of its base's
  copy, under the base's `cs` name, on the same branch with its index,
  uncommitted changes and per-worktree refs; the original stays a worktree of
  the original. `--session <base>@<task>` alone works once the base is in `cs`.
- Each session's Claude conversations and their file-history snapshots are
  copied from the profile into `~/.claude`, under the folder Claude Code gives
  the copy's path.
- Secrets go from the profile's encrypted store into the store `cs-secrets`
  reads, values on stdin. One whose value differs is reported, never
  overwritten.
- The session protocol in `CLAUDE.local.md` is reworded from `ags` to `cs` in
  the copy.

The profile is only read, and git runs there only to read, so ags keeps
working. When `cs` already has a session of that name, the ags one arrives as
`<name>-ags`; `--rename OLD=NEW` picks another name and `--session NAME`
copies one session. A rerun brings over what ags changed since, by the same
rules as above with the sides swapped: what `cs` changed in its copy is kept,
and something changed on both sides keeps `cs`'s and is reported once. A copy
`cs` removed is not made again. The record of the last sync lives in
`~/.claude-sessions/.ags-to-cs/`. A copy made before this record existed is
named and left; move it aside and rerun.

The script leaves these behind and names each one: a session open in ags
(close it, then rerun), an encrypted session (its vault needs its password and
links into the profile), a feature worktree whose base is not copied, and
Codex threads (`cs` has no Codex engine; resume one with
`CODEX_HOME=~/.local/share/agent-sessions/home/.codex codex resume <id>`).
Anything left behind makes the run exit 1. Paths come from `HOME` and the
options, never from `CS_*` variables, which name the profile inside an ags
session.

## Remaining compatibility decisions

- The primary executable is now `ags`; `cs` remains as a compatibility alias.
  The data root and `.cs/` metadata intentionally keep their old names to avoid
  migrating existing workspaces and machine configuration.
- Claude retains its quick failed-resume fallback and legacy transcript
  discovery; Codex refuses to replace a failed exact binding. Unifying resume,
  fresh, and handoff policy requires a lifecycle change with recoverable binding
  transitions, not a branding edit.
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
