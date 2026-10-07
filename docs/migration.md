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
Existing sessions and Claude settings are not migrated. Native CLI configuration
and login are separate in the experimental profile; the one exception is the
Claude display mode (`tui`), which setup copies from `~/.claude/settings.json`
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

## Going back to cs

`scripts/ags-to-cs.py` copies the profile's work back into the stable `cs`, so
every ags session opens with `cs <name>` and resumes the same Claude
conversation. It prints what it would do; `--apply` copies:

```bash
scripts/ags-to-cs.py              # the plan; nothing is written
scripts/ags-to-cs.py --apply
```

- A session ags adopted gets the same link in `~/.claude-sessions`. Its `.cs/`
  lives in the project, so `cs` and `ags` share it.
- A session ags created is copied whole, git history and local state included.
- A feature worktree (`<base>@<task>`) follows its base, under the base's `cs`
  name. One of a created base becomes a linked worktree of the base's copy, on
  the same branch with its index, uncommitted changes and per-worktree refs;
  the original stays a worktree of the original. One of an adopted base is
  linked like its base: its repository is the project's, shared with ags, and
  git checks a branch out in one worktree only. `--session <base>@<task>` alone
  works once the base is in `cs`.
- Each session's Claude conversations and their file-history snapshots are
  copied from the profile into `~/.claude`, under the folder Claude Code gives
  the session's path in `cs`.
- Secrets go from the profile's encrypted store into the store `cs-secrets`
  reads, values on stdin.
- The session protocol in `CLAUDE.local.md` is reworded from `ags` to `cs`. For
  an adopted session that file is shared, so ags sessions read the `cs` wording
  too. A directory inside the profile keeps the `ags` wording.

The profile is only read, so ags keeps working. When `cs` already has a
session of that name, the ags one arrives as `<name>-ags`; `--rename OLD=NEW`
picks another name and `--session NAME` copies one session. A rerun skips what
is already there and brings over what grew. A conversation continued in ags
replaces its `cs` copy only when that copy is an unchanged start of it. One
continued in both is reported and left alone.

The script leaves these behind and names each one: a session open in ags
(close it, then rerun), an encrypted session (its vault needs its password and
links into the profile), a feature worktree whose base is not copied, and
Codex threads (`cs` has no Codex engine; resume one with
`CODEX_HOME=~/.local/share/agent-sessions/home/.codex codex resume <id>`).
A linked session whose directory lives inside the profile, such as a worktree
under `work/` or a feature of an adopted base, stays where it is and is left
unchanged; keep the profile while `cs` uses it. Anything left behind makes the run exit 1.
Paths come from `HOME` and the options, never from `CS_*` variables, which name
the profile inside an ags session.

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
