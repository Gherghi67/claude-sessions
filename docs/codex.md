# Codex CLI sessions

agent-sessions (`ags`) can launch a named session with Codex CLI while keeping the session's files,
notes, and workspace under the same `.cs/` directory used by Claude Code.

## Launching

```bash
ags investigate --engine codex
ags investigate --engine claude
```

CS chooses the engine in this order: `--engine` on the current command, the
session's saved engine preference in `.cs/local/state`, `CS_DEFAULT_ENGINE`,
then the sole installed Codex adapter, otherwise `claude`. The explicit option accepts `claude` or `codex`. Claude remains
the default on legacy or dual-adapter installations when no preference is set. A Codex
launch saves the selected preference after its startup helper succeeds and
before the interactive CLI resumes. A failed Codex startup leaves the prior
engine preference and thread binding intact. A Claude launch records its
preference when SessionStart acknowledges the conversation or the native launch
returns successfully.

Codex launches use the `codex` executable by default. Set `CODEX_BIN` to its
path when it is installed elsewhere. The Codex adapter uses Python 3 for its
startup/bootstrap helper. Codex CLI must be installed and authenticated for
the current user; CS does not configure Codex credentials.

The startup helper uses Codex's experimental app-server `thread/inject_items`
API to create or resume a thread and append startup context without starting a
model turn. This API was verified with Codex CLI
`0.158.0-alpha.2.1`; compatibility with other builds depends on those
experimental protocol capabilities being present. CS checks at startup and
reports an error when they are unavailable. It does not upgrade Codex
automatically.

CS keeps the Codex thread ID in the machine-local
`.cs/local/codex-thread-id` file and resumes that exact thread on later Codex
launches. This binding is separate from Claude's conversation UUID. The engine
preference and conversation identity are local to that machine and are not
shared through Git.

Starting a different thread inside the Codex CLI does not update CS's saved
binding in this version. Use `ags <name> --engine codex --fresh` to explicitly create and bind another
conversation in the same workspace; reopening without that choice resumes the
recorded ID.

CS launches Codex with `--no-daemon`, so the thread writer is released when the
CLI exits. Keep one interactive owner for a thread: close that Codex thread in
the desktop app or another CLI before asking CS to resume it.

## Resume or start fresh

```bash
ags investigate --engine codex --resume
ags investigate --engine codex --fresh
```

Both engines accept these mutually exclusive flags. `--resume` fails when no
conversation is recorded and never creates a replacement. `--fresh` keeps the
previous binding until native preparation acknowledges the candidate. A failed
resume returns an error with the old binding intact.

Without either flag, an interactive reopen offers resume or fresh. Unattended
launches resume the recorded conversation by default. A new workspace starts a
conversation. Engine switching preserves the other engine's saved ID.

Both engines run under the same launcher-owned lease and cleanup. Codex's
persistent helper acknowledgement establishes its binding; this does not mean
the interactive CLI has completed authentication or a model turn. The normal
CLI exit status is returned to the caller.

## Workspace preparation and installation

```bash
CS_INSTALL_ENGINES=codex sh ./setup.sh
ags -adopt existing-project --engine codex
ags existing-project@investigation --engine codex
```

Codex-only create, adopt, worktree, and reopen flows create portable `.cs/`
records without allocating a Claude UUID/color, writing `CLAUDE.local.md`, or
configuring `.claude/settings.local.json`. Existing Claude files remain intact.
Switching to Claude prepares its native configuration at that point. A fresh
Codex-only install leaves `~/.claude/` untouched and remembers the selection.
`ags -doctor` reports the selected adapter's dependencies, binding, and capability
gaps. Install choices and migration rules are in [Migration](migration.md).

Setup uses an isolated profile under `~/.local/share/agent-sessions/home/`,
including its own Codex login and session registry. Setup creates the
profile's `.codex/` (mode 700), which the launcher exports as `CODEX_HOME`;
Codex refuses a `CODEX_HOME` that does not exist, and a launch with a missing
one stops and names it. Log in with `codex login` on the first launch. Keep original `cs`
workspaces in the stable tool; use a new workspace or a separate project for
these examples.

## Shared session context

The workspace and CS records remain shared across engines: project files,
`.cs/README.md`, plans, handoffs, and memory are in the same session directory.
At startup, CS appends context about the relevant `.cs/` files to the Codex
thread so it can load the session protocol and current notes. This does not
transfer the other engine's conversation history or native memory. When
switching engines, summarize important findings in the shared notes so both
conversations can pick them up.

CS does not replace or edit a project's `AGENTS.md`. Claude-specific session
configuration, including `CLAUDE.local.md` and Claude's auto-memory redirect,
continues to apply only to Claude Code.

## Current boundary

The Codex integration currently covers engine selection, launch and exact
thread resume, shared-context bootstrap, and packaging of the adapter. The
existing Claude hooks and function-hook mods do not run in Codex. Codex does
not yet participate in CS autosave and crash recovery, queue delivery, usage
reporting, automatic cross-engine handoffs, observed runtime status, or native terminal
controls. CS session-management commands continue to manage the shared
workspace, including manual `ags -status` updates through `CS_SESSION_*`; native runtime observations remain Claude-specific for now.

The shared internal dispatch, binding, and context interfaces are described in
[Engine adapters](engine-adapters.md).
