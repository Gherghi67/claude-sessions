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

`--from-handoff` takes the `r` answer without asking: a fresh thread starts
from the pending rotation handoff (the armed one, otherwise the newest
unconsumed one) and runs its first turn on its own. Without a pending handoff
it refuses and points at `--fresh`; it cannot be combined with `--fresh`,
`--resume` or `-finish`. An explicit `--fresh` on Codex also continues an
armed rotation, while Claude's `--fresh` disarms it; `--from-handoff` reads the
same on both engines.

Both engines run under the same launcher-owned lease and cleanup. Codex's
persistent helper acknowledgement establishes its binding; this does not mean
the interactive CLI has completed authentication or a model turn. The normal
CLI exit status is returned to the caller.

## Switching engines

```bash
ags investigate --engine claude
```

A plain `--engine` reopens the other engine's own conversation, which has not
seen the work done since it last ran. To carry the work across, ask for
`$switch` in Codex (or `/switch` in Claude), optionally naming the engine and
`--resume`. The skill writes and arms a handoff by the `rotate` skill's steps,
then runs `ags -switch`; Codex may ask you to approve that call, since it writes
into `.cs/` from the launch's read-only sandbox. Quit Codex with `/quit`, and
the `ags` that launched it reopens the session in the same terminal under
Claude, in a fresh conversation that starts from the handoff. From Claude the
`ags` mod runs `/exit` for you after a countdown, and Codex opens a fresh thread
from the handoff the way `r` does.

`--resume` resumes the target's last conversation in the session instead and
gives it the handoff as its first message (`codex resume <id> -C <dir>
<prompt>` on Codex). A target with no recorded conversation starts fresh, with
a notice. `ags -switch cancel` drops the recorded switch and keeps the handoff
armed. A `/clear` instead of quitting takes the handoff in the same engine, and
the switch is dropped with a notice. A CLI that exits with an error, or a target
that cannot start, leaves the handoff armed and prints both ways back:
`ags <name> --engine <target> --from-handoff` and `ags <name> --engine
<current>`. When the target exits with an error before its conversation
starts, ags also puts back a handoff its launch had already marked consumed.

Codex does not yet read an encrypted session's vault for rotation, so a switch
into Codex refuses in an [encrypted session](session-layout.md#encrypted-sessions),
as does `--engine codex --from-handoff`. A switch from Codex to Claude refuses
there too while `.cs/local/session.log` exists: Codex's session-start hook
writes that log in plaintext, and an encrypted session does not open beside it.
Move the file into `.cs/private/`, then ask for the switch again.

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
transfer the other engine's conversation history or native memory. The
`switch` skill carries the work across in a rotation handoff; for a plain
`--engine` reopen, summarize important findings in the shared notes so both
conversations can pick them up.

CS does not replace or edit a project's `AGENTS.md`. Claude-specific session
configuration, including `CLAUDE.local.md` and Claude's auto-memory redirect,
continues to apply only to Claude Code.

## Current boundary

The Codex integration currently covers engine selection, launch and exact
thread resume, shared-context bootstrap, packaging of the adapter, and the
shipped skills. The installer copies the skills into `$CODEX_HOME/skills/`,
where Codex lists them by name and a message starts one with `$<name>` (for
example `$checkpoint`); `finish` runs only when asked that way. A skill that
needs an adapter feature Codex lacks says so and stops: `feature` refuses under
Codex for now.

`$rotate` works. It writes and arms a handoff, then tells you to run `/clear`
and send any message: Codex starts no turn by itself, and the handoff loads with
that first message through the one hook ags registers for Codex
(`ags -codex-hook session-start` in `$CODEX_HOME/hooks.json`, trusted in
`config.toml` by the installer). The same hook rebinds the session after every
`/clear`, so the next `ags <name>` resumes the conversation you were in.
Exiting instead and answering `r` at the next launch starts a fresh thread from
the handoff and runs its first turn on its own. `$switch` does the same across
engines (see [Switching engines](#switching-engines)). The Claude hooks and
function-hook mods do not run in Codex. Codex does
not yet participate in CS autosave and crash recovery, queue delivery, usage
reporting, rotation in an encrypted session, observed runtime status, or native
terminal controls. CS session-management commands continue to manage the shared
workspace, including manual `ags -status` updates through `CS_SESSION_*`; native runtime observations remain Claude-specific for now.

The shared internal dispatch, binding, and context interfaces are described in
[Engine adapters](engine-adapters.md).
