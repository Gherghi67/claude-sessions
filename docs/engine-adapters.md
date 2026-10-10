# Engine adapters

cs uses a small shell interface to route engine-specific work while keeping
session storage and launch policy in the shared command. The initial registry
contains the built-in `claude` and `codex` adapters. It is an internal
first-party boundary; adapters are not discovered from user files or third
party plugins.

## Registry and operations

The registry is the `CS_ENGINE_IDS` array. `cs_engine_known <engine>` succeeds
only for a name that starts with a lowercase letter, contains only lowercase
letters, digits, or underscores, and appears in that registry.
`cs_engine_call <engine> <operation> [args...]` accepts these operations:

| Operation | Contract |
| --- | --- |
| `dependencies` | Print missing dependency names, one per line. A completed probe returns success even when names are missing; a nonzero status means the probe or dispatch failed. |
| `capabilities` | Print supported capability names, one per line. |
| `prepare_workspace` | Prepare native integration for a session directory and mode (`create`, `migrate_storage`, `migrate`, or `worktree`). Return failure to abort the shared operation. Codex is a no-op; shared storage is already prepared. |
| `launch` | Start the selected engine with the positional launch arguments supplied by the shared command. |

Each registered implementation is named
`_cs_<engine>_adapter_<operation>`. Dispatch validates both the registry entry
and operation, then forwards arguments and the handler's exit status unchanged.
It does not construct a command string or evaluate adapter data as shell code.
An unknown engine, unsupported operation, or missing implementation fails
before adapter launch side effects.

The capability check `cs_engine_supports <engine> <capability>` performs an
exact line match against `capabilities` output. The initial capabilities
describe the checked-in integration: Claude supports `launch`, `exact_resume`,
`startup_context`, `feature_finish`, `rotation`, `spawn_brief`,
`memory_index`, and `mail_delivery`; Codex supports `launch`, `exact_resume`,
`startup_context`, `feature_finish` and `rotation`. These
names describe the integration's behavior, not a guarantee about every
installed runtime version. Shared commands should check a capability before
performing any side effect that depends on it. In particular, feature finish
must fail before session creation or adapter preparation when unsupported.

The four session-manager capabilities name what the shipped skills rely on:

| Capability | Means | Checked by |
| --- | --- | --- |
| `rotation` | a fresh conversation consumes the armed handoff and the binding follows `/clear` (Claude and Codex) | the rotate skill |
| `spawn_brief` | a spawned session's first turn reads `.cs/brief.md` | the feature skill |
| `memory_index` | `.cs/memory/MEMORY.md` loads at every session start, against a byte budget | the sweep skill |
| `mail_delivery` | `cs -msg` mail surfaces inside the open conversation | the feature skill |

`cs -engine` gives skills and scripts the same answers without sourcing the
library. It prints `engine:`, `conversation:` (the native ID the session has
bound for that engine, through `cs_binding_read`) and `capabilities:` lines.
`cs -engine supports <capability>` prints nothing and exits 0 when the engine
declares the capability, and names both and exits 1 when it does not. The engine
is the run's own (`CS_RUN_ENGINE`, which every launch exports into the native
child); outside a run it is the session's saved preference.

`check_dependencies` calls the selected adapter's probe and turns any reported
names into the established user-facing missing-dependency error. Claude keeps
its binary-plus-arguments `CLAUDE_CODE_BIN` setting, checking its first word;
Codex checks the `CODEX_BIN` executable path and `python3`. Each engine can be
selected without requiring the other engine's executable.

## Shared session context and bindings

The shared session identity is exported as `CS_SESSION_NAME`,
`CS_SESSION_DIR`, and `CS_SESSION_META_DIR`. During compatibility migration,
`cs_export_session_context` also exports the corresponding
`CLAUDE_SESSION_NAME`, `CLAUDE_SESSION_DIR`, and
`CLAUDE_SESSION_META_DIR` aliases with identical values. The helper replaces
all six values on each launch so a nested launch cannot retain a parent's
session identity. Shared consumers should use the `CS_SESSION_*` names;
existing hooks and commands can continue using the aliases while they are
migrated.

`cs_session_context <name> <directory> <actor> <renderer> [args...]` builds a
call-scoped inventory of the session's workspace-relative objective, summary,
memory, narrative, archive, checkpoint, and handoff paths. An empty actor is
resolved through the shared actor helper. The named shell function receives
the remaining arguments and can read the dynamically scoped `CS_CONTEXT_*`
fields while it renders engine-specific transport. The builder does not read
workspace prose or turn it into policy, and it returns renderer failures to
the caller. Claude's existing instruction template is kept byte-for-byte;
Codex renders the same inventory as startup context.

`cs_binding_read <session-directory> <engine>` and
`cs_binding_write <session-directory> <engine> <id>` provide shared access to
the existing machine-local formats. A missing file or absent Claude binding key
reads as an empty value. An unreadable or non-file binding fails; an empty or
multiline Codex binding file also fails. Writes use a
temporary file and rename, preserve the other engine's binding and existing
local-state fields, and reject values that the selected storage format cannot
round-trip. Native ID shape validation remains in the engine launch code.
Claude's `claude_session_id` key stays in `.cs/local/state`; Codex's ID stays
in `.cs/local/codex-thread-id`. The storage formats remain compatible. A staged replacement lives in
`local/pending-binding-<engine>.json` until the adapter acknowledges its ID.
A failed preparation preserves the previous binding; an abandoned candidate is
retained locally when another attempt supersedes it. A repeated acknowledgement
in the same run can finish an interrupted commit without duplicating lineage.
A candidate left by a previous failed run is recovery evidence; a later launch
does not silently choose that abandoned candidate.

The Codex adapter verifies that refresh returns the already-bound thread ID
and keeps the binding on refresh failure; it will not silently create another
thread. Claude also preserves a failed resume binding: the former quick-failure
fallback has been removed. `--fresh` explicitly requests a replacement;
`--resume` requires an existing binding. Claude commits a staged candidate when
the owning SessionStart acknowledges it; Codex commits after its helper confirms
the persistent thread ID. Process exit alone does not acknowledge a conversation.
Switching engines leaves the other engine's binding alone.

Engine selection retains this order: an explicit `--engine`, then the saved
session preference, then `CS_DEFAULT_ENGINE`, then a sole installed Codex adapter, otherwise Claude. The selected engine
preference is recorded only after the launch path accepts the choice. Claude remains the default on legacy and dual-adapter installations.

## Adding a built-in adapter

Add its identifier to `CS_ENGINE_IDS`, and implement the handler functions for
the operations it supports. Keep native executable discovery, IDs, protocol,
and native event formats inside those handlers. Report only verified
capabilities. The shared dispatcher invokes functions already included in the
assembled command; there is no runtime module loading or adapter registration
from the environment.

Test handlers with a fake adapter so the shared contract can be exercised on a
machine that has neither native runtime installed. Contract coverage should
check exact argument forwarding and exit-status preservation, unknown engine
and operation rejection without invocation, capability matching, dependency
isolation, and early rejection of unsupported features. For shell-source
changes, edit `lib/` fragments and run `./build.sh`; `bin/cs` and installer
outputs are generated from those sources.

## Source ownership

The standalone distribution still assembles numbered `lib/` fragments; this
iteration does not move the entire source tree or migrate storage formats.

| Shared core | First-party adapter fragments |
| --- | --- |
| `24-engine-adapters.sh`: registry and operation dispatch | `35-claudemd.sh`: Claude auto-memory and native instructions |
| `34-narrative-storage.sh`, `36-context.sh`: portable memory and context inventory | `42-claude-state.sh`: Claude transcript identity discovery and fresh invocation |
| `40-state.sh`, `41-bindings.sh`: local state and engine-qualified bindings | `46-claude-workspace.sh`: Claude workspace preparation and native migrations |
| `30-worktree.sh`, `45-migrate.sh`: shared worktree/scaffold/migration operations | `75-launch.sh`: existing Claude launch adapter and its orchestration |
| CLI commands consume `CS_SESSION_*`, falling back to legacy aliases | `76-codex.sh`, `bin/cs-codex-thread`: Codex launch, context renderer, and protocol |
| `78-switch.sh`: `cs -switch`, `pending-switch`, and the relaunch under the other engine | |

Create/adopt/migrate/worktree paths dispatch `prepare_workspace` after preparing
portable storage. They allocate no native conversation IDs themselves. Claude adoption appends its
protocol to an existing user-owned `CLAUDE.local.md` and preserves its content. On reopen, `migrate_storage` imports native memory before core writes the shared
index; `migrate` then handles native instructions and identity after legacy
README fields are moved to machine-local storage without discarding existing
Claude bindings even when Codex is selected. Claude native migration/discovery
runs only when Claude is selected; returning from Codex keeps an existing valid
Claude binding. Core workspace preparation can be tested with a fake adapter
without native helper functions or executables.

The installer selects first-party adapter payloads with `CS_INSTALL_ENGINES`.
Codex-only installations omit Claude hooks, mods, statuslines,
and settings. Skills deploy to every selected engine: the same files go to
`~/.claude/skills/` and to `$CODEX_HOME/skills/` (default `~/.codex/skills/`),
and uninstall removes only the names cs ships from either. Shared CLI identity resolution and cs-secrets prefer neutral
variables and accept older callers. Exported Claude aliases remain during the
migration for shipped native hooks and commands.

## Shared run ownership

`cs_launch_session` owns the run lease and cleanup around adapter launch.
Adapters invoke native programs through `cs_run_child`; both fresh and resumed
Claude conversations remain children of the launcher. `CS_RUN_ID`,
`CS_RUN_ENGINE`, and `CS_RUN_OWNER_PID` identify the invocation. The numeric
`.cs/session.lock` remains compatible with existing consumers, while
`.cs/local/run-lease.json` identifies its owning run.

Ownership changes and binding acknowledgements use the same filesystem guard
(`lockf` on macOS, `flock` on Linux). A forced replacement prevents the old
run from releasing or rebinding the successor. Claude hooks additionally check
the native process PID or direct parent; inheriting the run environment alone
never grants lead ownership. SessionEnd does not release a supervised run,
including during `/clear`: launcher cleanup owns that operation. Normal
termination reaps the native child before releasing ownership; a child that
ignores termination is killed after a bounded grace period. If the launcher is
killed abruptly while its native child survives, the recorded child PID and
process start time keep command-line collision checks active until it exits.

New conversation records include `engine` and `run_id`. `cs -conversations`
labels each engine, counts resumes separately, and treats older records without
an engine as Claude records. Each engine retains its own current binding.

## Switching engines

`cs -switch` (lib/78-switch.sh) moves a session to the other engine through a
rotation handoff; no transcript crosses engines. The `switch` skill writes and
arms the handoff by the `rotate` skill's steps, then runs
`cs -switch [claude|codex] [--resume]` from inside the conversation. The verb
refuses, naming the fix, outside a session or a live run of it (its
`CS_RUN_ID` must match `.cs/local/run-lease.json`), for an unknown engine or the
current one, for a target the install did not set up or whose CLI is missing,
for a target adapter without `rotation`, for a switch already pending, for an
encrypted session whose vault is locked, whose target is Codex (its rotation
does not read `.cs/private` yet) or whose open would refuse the relaunch
(`_refuse_unmounted_meta`, for example the plaintext `.cs/local/session.log`
Codex's session-start hook writes), and when no unconsumed handoff is armed.
`--check` runs every refusal except the last and writes nothing; the skill
calls it before writing a handoff. On success the verb writes
`pending-switch` atomically to the session's private directory (`.cs/local/`,
or `.cs/private/` when encrypted):

```
engine=<target>
mode=fresh|resume
handoff=<basename of the armed handoff>
run=<CS_RUN_ID of the run that wrote it>
```

and prints how to leave the CLI (`/exit` for Claude, `/quit` for Codex).
`cs -switch cancel` removes it and leaves the handoff armed. Under Claude the
`cs` mod reads the same file: its forced-rotation countdown runs `/exit`
instead of `/clear` while a switch is pending.

`cs_launch_session` settles the switch after the CLI exits, while the run
still holds its lease and an encrypted session's vault is mounted. Only the
run named by `run=` takes it, once: the file is removed first. A non-zero CLI
exit, a handoff a `/clear` already consumed, a missing target CLI, or a session
the relaunch's open would refuse ends the switch there, with the handoff left
armed and, except for the consumed case, both reopen commands printed. A switch
file found as a run starts belongs to an earlier run that ended without
settling it, and is dropped.

Otherwise `main` re-execs `cs <name> --engine <target>` once
`cs_launch_session` returns: with `--from-handoff` for `mode=fresh`, or with
`--resume` for `mode=resume` when the target has a recorded conversation (a
notice and a fresh start otherwise). The exec restores the environment, umask
and working directory `main` started from and clears `CS_RUN_ID`,
`CS_RUN_ENGINE`, `CS_RUN_OWNER_PID`, `CS_LEAD_PID`, `CS_FRESH_REBIND` and
`CS_CLAUDE_SESSION_ID`, so the target's own open steps run (dependencies,
migration or the worktree path, the adapter's launch) under a new run that
records `state engine <target>`. The previous engine's binding is untouched.
The process id survives the exec, so an encrypted session's vault stays
mounted and the relaunch joins it. A relaunch that fails before its CLI starts
prints both reopen commands, from its settle or from an exit trap `main` sets
for it. The settle looks at the handoff the relaunch came to carry, which it
notes as the run starts. When the CLI exits non-zero and that handoff is still
unconsumed, or the launch spent it (the resume path, Codex's `r` path) with no
session start logged since, it is marked unconsumed and armed again. A
relaunched conversation that did run, or that armed a newer handoff, keeps what
it took, and nothing is printed.

Launch intent `handoff` (`--from-handoff`) is the `r` answer taken without the
prompt on both adapters, from `_pending_handoff_pick`. The relaunch's resume
mode spends the handoff in the launch, just before the CLI starts: it marks it
consumed by the resumed conversation, removes the marker so a later `/clear`
cannot rotate into it again, and passes a prompt pointing at it (Claude's
launch prompt, Codex's `codex resume <id> -C <dir> <prompt>`). An encrypted
session's prompt names `.cs/private/handoffs/` and the `consumed_by` value
rather than the handoff, whose name is the session's topic.

## Deferred boundaries

Hooks, recovery, usage, and TUI runtime observations retain their Claude
integration, apart from the one Codex hook below. They are not a normalized
core event bus yet. A full move to
`core/` and `adapters/` directories should follow these behavior boundaries.
Codex native event delivery remains separate work; shared supervision does not
provide turn-boundary observation, queue delivery, or forced rotation.
The shipped skills deploy to Claude and Codex alike. Each one reaches its
helpers through its own directory and checks `cs -engine supports` before an
adapter feature. Codex declares `rotation` and none of the other three, so under
Codex `feature` refuses before writing anything.
Codex ignores `disable-model-invocation`, so `finish` also ships
`agents/openai.yaml` with `allow_implicit_invocation: false`, which keeps it out
of the skill list Codex gives the model.

Codex rotation runs through one hook. The installer registers
`cs -codex-hook session-start` in `$CODEX_HOME/hooks.json`, after any groups
already there, and writes its `trusted_hash` under `[hooks.state."<hooks.json
path>:session_start:<group>:0"]` in `config.toml` in the same step: Codex skips an
untrusted hook without a word, and keys trust by the group's position. The hash
is the sha256 of the group as compact sorted-key JSON with Codex's defaults
(`async: false`, `timeout: 600`). Codex fires SessionStart on a thread's first
turn, before the model call: `resume` for every cs launch, because cs creates
the thread and then resumes it, and `clear` for the first message after `/clear`,
carrying the new thread's id. On `clear`, under the run lease, the hook rebinds
`.cs/local/codex-thread-id`, records `rotated` and `started` events, consumes an
armed handoff and returns the rotation context; on every source it logs the
`Session started` line the rotate skill and the launch prompt read. The launch
owns the other way in: `r` at the `[Y/n/r/d]` prompt (or `--from-handoff`, or an
explicit `--fresh` with a rotation armed) adds the handoff to the new thread's
context, consumes it, and starts the thread with `codex resume <id> <prompt>`.
These paths read `.cs/handoffs` and `.cs/local/pending-handoff` only, so Codex
rotation does not yet work in an encrypted session.
