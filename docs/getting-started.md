# Getting started with agent-sessions

This guide uses `ags`, the primary command. Setup keeps the original `cs`
installation independent while the rebrand is experimental. Compatibility
aliases exist inside the private payload, and workspace metadata keeps `.cs/`.

## Install this checkout

The rebrand is still local and unpublished. Run this one command from the
checkout, or use the full path to `setup.sh` from any directory:

```bash
sh ./setup.sh
```

Setup builds the CLI and installs both Claude and Codex integrations by default
on a fresh install. It remembers the selection on reruns, exposes only `ags-*`
commands and `ags` in `~/.local/bin`, and builds the optional picker when Cargo is available.
Use `sh ./setup.sh --skip-tui-build` to skip compiling the picker. Setup adds the
command path to your shell startup file; open a new terminal after installation.

Choose only one integration on a fresh install if you prefer:

```bash
CS_INSTALL_ENGINES=codex sh ./setup.sh
```

Setup requires Bash, Git, jq, and Python 3 for Codex. Shared run ownership uses
`lockf` on macOS or `flock` on Linux. Install and authenticate
Claude Code and Codex CLI separately. See [Codex sessions](codex.md) for the
current runtime compatibility limit.

The experimental profile is `~/.local/share/agent-sessions/home/`. Its Claude
and Codex configuration, hooks, commands, cache, sessions, `ags -encrypt`
vaults and `ags -spawn` tmux server (`tmux -L ags attach -t ags`, where
`cs -spawn` uses the default server) are separate from your original
installation. Log in to the selected CLI when first prompted in this profile.
Normal `cs`, `claude`, and `codex` keep their existing configuration.
Setup then carries your own setup into the profile, reading `~/.claude` and
`~/.codex` without changing them. Your `CLAUDE.md`, `AGENTS.md`, agents, skills,
commands and workflows are linked one entry at a time, so an edit made there
reaches ags at once; your hooks, enabled plugins, MCP servers and preferences
are merged into the profile's own files. Whatever ags installs itself, and any
entry the profile already has, stays the profile's. Remote MCP servers ask you
to sign in again inside the profile. [Your own setup in the ags
profile](configuration.md#your-own-setup-in-the-ags-profile) lists what moves,
and how to preview it, rerun it alone, or skip it (`sh ./setup.sh --no-carry-over`).
Setup also copies the Claude display mode (`tui`) from
your `~/.claude/settings.json` into the profile when the profile has none yet.
Otherwise a fresh profile would start in Claude Code's fullscreen renderer, which
captures trackpad gestures such as iTerm2's two-finger tab swipe. Run `/tui`
inside the profile to change it; later setups keep that choice.
Your HOME stays your own, so the macOS keychain, `~/.ssh`, your Git identity and
other credentials work as usual inside a session. Secrets use encrypted files
within the profile, with their own master password, so `ags -list` and the
picker show no secret counts (they count keychain secrets only, which here are
the original installation's). `ags <name> -secrets list` lists a session's own.

Keep using `cs` in existing workspaces. For testing `ags`, create a new workspace
or adopt a separate project; `ags .` and adoption refuse an existing `cs` workspace.
The profile starts empty. Run bare `ags`, press `n`, and enter a name to create
your first session. Existing `cs` sessions stay in their original registry.
To take ags sessions back to `cs`, see [Going back to cs](migration.md#going-back-to-cs).

## Adopt a project or create a workspace

To make the current project an agent-sessions workspace, run this from its root:

```bash
cd /path/to/my-project
ags -adopt my-project --engine codex
```

Adoption keeps the project files where they are and adds `.cs/` workspace
metadata. The adoption operation may commit its bookkeeping files to the
project's Git repository. Omit `--engine` to use the configured default, or
specify `--engine claude` to choose Claude explicitly. The first open of an
adopted project starts a new conversation; there is nothing to resume yet.
Re-adopting a project whose `.cs/` records name a conversation keeps it.

To create a separate session workspace for a task that is not an existing
project, run:

```bash
ags research-notes --engine codex
```

This creates a workspace under
`~/.local/share/agent-sessions/home/sessions/research-notes/` and
starts Codex there. Running the same command later resumes that workspace.

## Resume and switch engines

Resume with the saved engine:

```bash
ags research-notes
```

Use an explicit flag to bypass the resume/fresh prompt:

```bash
ags research-notes --resume
ags research-notes --fresh
```

A failed resume preserves its recorded conversation. Fresh creates a new native
conversation while retaining the workspace and notes. Each engine keeps its own
binding; switching engines does not erase the other engine's history.

To switch engines, close the current interactive CLI first, then launch with the
other engine:

```bash
ags research-notes --engine claude
ags research-notes --engine codex
```

The workspace files and `.cs/` notes are shared. Claude and Codex keep separate
native conversation histories, so `--engine` alone opens the other engine's
own conversation, which has not seen the work done since it last ran. Keep
one interactive owner open for a workspace at a time.

To carry the current conversation's work across, ask for the `switch` skill
from inside the conversation (`/switch` in Claude, `$switch` in Codex; name
`claude` or `codex`, or leave it out for the other engine). It writes and arms
a rotation handoff the way the `rotate` skill does, then records the move with
`ags -switch` and tells you how to leave: `/exit` in Claude (the `ags` mod
counts down and runs it for you), `/quit` in Codex. When the CLI exits, ags
reopens the session in the same terminal under the other engine, in a fresh
conversation that starts from the handoff. That engine becomes the session's
saved engine. The previous conversation stays on disk and is not resumed;
`ags research-notes --engine <previous engine>` opens it again.

Ask for `--resume` with the switch to resume the other engine's last
conversation in this session instead. The handoff becomes its first new
message. When that engine has no conversation recorded here, ags says so and
starts a fresh one.

`ags -switch cancel` drops a recorded switch and leaves the handoff armed, so
`/clear` continues from it in the same engine. A `/clear` instead of the exit
also takes the handoff in the same engine; ags then drops the switch with a
notice. If the CLI exits with an error, or the other engine cannot start, ags
prints both ways back and the handoff stays armed:

```bash
ags research-notes --engine codex --from-handoff
ags research-notes --engine claude
```

`--from-handoff` starts a fresh conversation from the pending handoff without
the resume prompt: the armed one, otherwise the newest unconsumed one, labelled
`(from another checkout)` when this checkout did not write it. Without a
pending handoff it refuses and points at `--fresh`. It cannot be combined with
`--fresh`, `--resume` or `-finish`. Codex cannot yet start from the handoffs of
an [encrypted session](session-layout.md#encrypted-sessions), so the switch
into Codex and `--engine codex --from-handoff` refuse there. A switch out of
Codex refuses there as well while Codex's plaintext `.cs/local/session.log`
exists; move it into `.cs/private/` first.

Run `ags .` from the root of an adopted project or registered session to open
that workspace. From anywhere, `ags` with no arguments opens the interactive
session picker when the TUI was built before installation. Without the picker,
bare `ags` prints help; named session launches still work.

## Work in a parallel feature worktree

From an existing session, create a named feature worktree with:

```bash
ags my-project@fix-auth --engine codex
```

List feature worktrees from the base session with:

```bash
ags my-project -features
```

The base project should have a clean, committed starting point before you
create a worktree. The worktree has its own session metadata and shares the
base repository's Git history. Claude currently supports the `/finish`
integration workflow; Codex worktrees can be managed with Git directly while
Codex integration support is developed.

## Save a manual checkpoint

From an active session, ask the assistant to save a named checkpoint, or run:

```bash
ags -checkpoint "before changing the schema"
ags -checkpoint list
ags -checkpoint show <checkpoint-name>
```

A checkpoint records the current Git HEAD, changed-file list, and session
narrative under `.cs/checkpoints/`. It is a reference snapshot; commit your code
separately when you want to preserve the contents of the changes themselves.

## Current Codex limits

Codex currently supports engine selection, launch, exact thread resume,
shared startup context, rotation, and the `switch` skill in both directions.
Claude's hooks and mods do not run inside Codex. Codex does not yet provide
agent-sessions autosave and crash recovery, automatic queue or mailbox
delivery, runtime usage reporting, rotation in an encrypted session, or native
terminal controls. Manual status and workspace management are available.

This branch has not been published. The experimental launcher disables
`ags -update` and `ags -uninstall`; rerun `setup.sh` to install checkout changes.
