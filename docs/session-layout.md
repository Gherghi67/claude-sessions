# Session layout (`.cs/`)

Every agent-sessions (`ags`) session is a directory under the sessions root:
`~/.claude-sessions/` by default, `~/.local/share/agent-sessions/home/sessions/` in the
profile setup installs (override either with `CS_SESSIONS_ROOT`). The directory itself is the workspace — the selected engine works on
project files there. All session *metadata* lives in a single `.cs/`
subdirectory, and the whole session directory is its own local git repo.

`.cs/` is kept at mode `0700` — set when the session is created and re-applied on
every open, which covers sessions predating the rule and fresh clones (git records
no directory modes, so a clone recreates `.cs/` under the local umask). Reaching a
file inside needs execute on the directory, so one private `.cs/` covers everything
under it. A session root cs created is `0700` too; an **adopted** session's root is
not, because that directory is the user's own project and its mode is theirs to
choose.

`.spawn/` at the sessions root stages `<name>.seed` files written by
`ags -spawn`: line 1 is the spawner, remaining lines are `--task` items. cs
stages a `--brief <file>` beside it as `<name>.brief.md`, and a brief alone
still writes a seed, since the seed carries the spawner. The launch consumes
fresh seeds (tasks queued and armed, the brief moved to the session's
`.cs/brief.md`, kick prompt); seeds older than an hour are set aside as
`<name>.seed.stale` with their brief as `<name>.brief.md.stale` and never
applied silently.

`.usage/` at the sessions root holds `fable.<account>.json`, its `fable.<account>.json.fields` file (the fields the status line reads, one per line, written by the refresher), the machine-global cache
behind the statusline's [fable segment](statusline.md#fable-usage), plus the
`.lock` directory that serialises refreshers. It sits at the root rather than in
any one session because the rate-limit budget it draws on belongs to the
account, not the session: every agent-sessions session on the host must poll through one
file. Machine-local and disposable — deleting it costs one refresh.

The one distinction that governs everything below is **shared vs machine-local**:

- **Shared** — committed to the session's git repo. When a session is cloned or
  synced to another machine (or shared with a co-developer), these travel with
  it. Append-heavy shared files use a git merge policy (see below) so concurrent
  writers don't conflict.
- **Machine-local** — everything under `.cs/local/`, which is gitignored. This is
  per-checkout state that must *not* sync: another machine has its own copy and
  merging them would be wrong.

## Shared files

| Path | Purpose | Merge |
|------|---------|-------|
| `.cs/README.md` | Session objective (captured from the first prompt) and outcome. Human-edited. An [encrypted session](#encrypted-sessions) keeps only the frontmatter here. | default |
| `.cs/summary.md` | Distilled session summary, written by `/wrap` and `/summary`. | default |
| `.cs/timeline.jsonl` | Structured event log — `started`, `ended`, `checkpoint`, `rotated`, and `narrative_rotated` events as newline-delimited JSON. A base session also records `worktree-retired` (with the feature's `task`) when a feature worktree is retired, and `feature-integrated` (with `task`, the integrated `sha` and a `result`) when `/finish` integrates one. | `union` |
| `.cs/memory/MEMORY.md` | Index of Claude Code's native auto-memory (one line per fact). | `ours` |
| `.cs/memory/<bucket>_*.md` | Native auto-memory fact files (user, feedback, project, reference). Written by the harness. Shared by every actor on the session, unlike the narratives below, so a `user`/`feedback` entry may describe someone other than the person present — write facts about a person keyed to that person, never as a claim about whoever is here. | default |
| `.cs/memory/narrative.<actor>.md` | Per-actor lab notebook. Each co-developer writes their own file, reads it in full on resume, and reads a teammate's file only from the line the resume digest names; append-only. | `union` |
| `.cs/narrative-archive/<actor>/<through-date>-<blob8>.md` | Sections `ags -narrative rotate` moved out of the live narrative, verbatim. Immutable once written; the name is derived from the content, so two machines archiving the same sections produce the same file. | default |
| `.cs/checkpoints/` | Labelled state snapshots from `/checkpoint` (narrative + changes + git HEAD). | default |
| `.cs/archived` | Archive marker written by `ags -archive` (date + actor). Tracked so the archived state syncs; removed on open or `ags -unarchive`. | default |
| `.cs/handoffs/` | Lineage-stamped conversation handoffs written by the `rotate` skill (parent UUID, purpose, continuation plan). Each carries a `status:` field — `unconsumed` while pending, flipped to `consumed` by the SessionStart that rotates into it, to `discarded` by the resume prompt's `d` answer, or to `superseded` when a later rotation retires it. The `rotate` skill also prunes as it goes, deleting `consumed`, `discarded` and `superseded` files older than 30 days by `created:` unless they are among the 10 newest — instructions the skill follows, not a `ags` command; nothing in the agent-sessions launcher deletes a handoff. An [encrypted session](#encrypted-sessions) keeps them in `.cs/private/handoffs/` instead. | default |
| `.cs/plans/` | Design plans and specs kept with the session. | default |
| `.cs/brief.md` | The brief a `ags -spawn --brief` (or the `feature` skill) handed this session, moved in at launch; the wake-up line sends the session to it first. Written once per spawn, replacing an earlier one. | default |
| `.cs/age-recipients/*.pub` | age public keys of everyone allowed to decrypt the session's synced secrets. | default |
| `.cs/secrets.<machine-id>.age` | Per-machine encrypted secret sync file (age; preferred). Each machine writes its own so exports never collide. | default |
| `.cs/secrets.<machine-id>.enc` | Per-machine encrypted secret sync file (OpenSSL + password; legacy). | default |

`<machine-id>` is `${USER}@<short-hostname>` — the same id that names age
recipients. See [secrets.md](secrets.md) for the sync model.

`.cs/session.lock` is a PID-based lock written at the session root (not under
`local/`). It is ephemeral and machine-specific; it exists only while a session
is open and is cleaned up on exit. `.cs/.narrative-reminder-cooldown` is a
similar gitignored transient at the `.cs/` root — the narrative reminder's
5-minute cooldown stamp.

`CLAUDE.local.md`, also at the session root, carries the agent-sessions session protocol:
it is machine-local and gitignored, cs regenerates it on each machine, and a
user-owned `CLAUDE.md` is never touched.

## Machine-local files (`.cs/local/`, gitignored)

An [encrypted session](#encrypted-sessions) keeps the content files among these
in `.cs/private/` instead.

| File | Purpose |
|------|---------|
| `session.log` | Human-readable audit trail — bash commands, session lifecycle, autosave notes, UUID rebinds. Per-checkout by nature; the shared structured record is `timeline.jsonl`. |
| `state` | Session state bound to this checkout: `claude_session_id` (the conversation UUID to resume), `claude_session_color` (the `/color` palette entry), `last_resumed` (last resume date), `session_name` for adopted sessions only (their name lives in the sessions-root symlink, which a hook resolving the directory has no way to read; an ordinary session takes its name from its directory), and, for feature worktrees, `task_branch`, `cs_base` and `cs_mode` (`tracked` when the base repo tracks `.cs/`, `ignored` when it does not; it decides how the worktree's records reach the base when the feature is integrated and retired). Each machine binds its own conversation, so this must not sync. Writers take turns on a `state.lock` directory beside it. `claude_session_id` is one slot, written only by the conversation `ags` launched — see [hooks.md](hooks.md) for how a teammate or walked-in claude is kept out of it. |
| `run-lease.json` | Current launcher run token, engine, owning process, and registered native child with its process start time; supplements the compatible numeric `.cs/session.lock`. Hooks validate ownership before rebinding. |
| `run-lease.guard` | Persistent inode for serialized lease replacement, cleanup, and binding acknowledgement. Do not unlink while launches are active. |
| `pending-binding-<engine>.json` | Candidate conversation ID, previous ID, run token, and transition reason awaiting native acknowledgement. Unacknowledged candidates superseded by retries remain in `.abandoned.*` records for diagnosis. |
| `codex-thread-id` | Independently bound Codex conversation, committed after the persistent startup helper acknowledges its ID. |
| `identity` | Overrides the actor name for shared memory/narrative attribution (precedence: `$CS_ACTOR` > `local/identity` > git `user.email` > git `user.name`). |
| `attention` | Status-line attention marker — raised by the `Stop` hook when Claude finishes, cleared on the next prompt. |
| `presence` | This session's advertised status (`ags -status`): a single line read by `ags -live`. Falls back to the README objective when unset. |
| `pending-handoff` | Basename of the `.cs/handoffs/` file to rotate into — armed by the `rotate` skill (for `/clear`) or by the `r` answer at the resume prompt. Consumed and cleared by the next SessionStart whose source is `startup` or `clear`; left armed on any other source; disarmed by any other resume-prompt answer. |
| `rotate-nudged` | Conversation UUID last nudged to rotate by the narrative reminder — keeps the 65%-context nudge to once per conversation. |
| `cs.heartbeat` | UTC timestamp of the last session start at which the cs mod ran — `ags -doctor` reports the mod from this file, never from the plugin directory being present. |
| `cs-update.heartbeat` | UTC timestamp of the last session start at which the cs-update mod ran, written by the mod's `session.start` when Claude Code loads it — `ags -doctor` reads it the same way it reads `cs.heartbeat`, never the plugin directory being present. |
| `cs-update.done` | Version and outcome line of the last `ags -update` the pane finished, written by the mod on a clean exit and read back by the reloaded module (from the pane's own render, `/cs-update`, or the next `session.start`): installing the update rewrites the mod's own deployed file, Claude Code reloads it mid-conversation without firing `session.start`, and the reload drops the module state the pane was drawing from. Cleared (written empty) by the first of those reads that finds nothing pending for that version. |
| `cs.forced` | The conversation `CS_ROTATE_FORCE_CTX` already rotated, written before the `/rotate` runs so a failed one is not retried every turn. |
| `wrapped` | The conversation a `/wrap` finished in (its `CLAUDE_CODE_SESSION_ID`), written by its last pass; the cs mod's band hides the wrap key while it names the conversation, and the next prompt empties it. |
| `disabled` | Opts the directory out of cs's hooks entirely. Present, the hooks decline as if it were not a session, whichever front end opened it. Before hooks resolved a session from the directory, a `claude` started outside `ags` in a session folder was inert; this restores that on request instead of by accident. |
| `pre-open` | An executable `ags <name>` runs before it opens an existing session, from the session directory on your terminal, so it can prompt (mounting the encrypted volume that `.cs/memory` and `.cs/plans` link into, for example). A non-zero exit aborts the open, and `ags` refuses a file that is not executable rather than skipping it. It lives here because this directory is never committed, so a cloned session cannot make `ags` run code. A session copied by a file sync (rsync, iCloud, Dropbox) carries it along, and `ags` runs it. Afterwards, if `.cs/memory` or `.cs/plans` is still a symlink to something missing, `ags` refuses to open the session and names the link, instead of creating plaintext directories in their place. |
| `vault` | The path of the container `ags -encrypt` built, written only by `ags -encrypt`. The SessionEnd hook unmounts the vault only when this file exists. |
| `vault-holders` | Process ids of every `ags` run that mounted or joined this session's vault. The volume unmounts only when none of them and no session lock is alive. |
| `vault-waiter.pid` | The background waiter the SessionEnd hook leaves to unmount the vault once the lead conversation's Claude Code exits. An open that finds the vault mounted with nothing alive behind it stops this waiter first. |
| `vault-detach.pid` | The `hdiutil detach` that waiter started, so a reopen can stop an unmount in flight. |
| `queue/` | The walk-away task queue (`ags -queue`): one file per task, staged in `queue.tmp/` and renamed into place so the drain never reads a torn entry. The drain pops the lexically first file by moving it aside — atomic against a second drain. |
| `queue.state` | Drain state machine for the queue: `idle`, `armed`, or `draining`. |
| `queue.done` | Log of completed queued tasks, appended as each is drained. |
| `queue.declined` | Cooldown stamp after declining the queue-drain prompt. |
| `notifications.jsonl` | Per-machine queue inbox — drain lifecycle events (`drain_started`, `task_done`, `breaker_tripped`, `drain_finished`) and the `gate_declined` event `ags -queue defer` writes, read by `ags -queue log` and the surface-once digest. |
| `notifications.seen` | Cursor for that digest, so unseen inbox entries surface at most once. |
| `.advisor-nudge-cooldown` | The narrative reminder's cooldown stamp for its council-advisor nudge: at most one nudge per 30 minutes. |
| `memory-index.snapshot` | Copy of `.cs/memory/MEMORY.md` that `/sweep` takes before it edits the index; the sweep skill's `scripts/memory-index-guard.sh check` compares against it and `restore` copies it back. Overwritten by the next sweep. |
| `ctx-warned` | Conversation UUID already given the one-time 40% context warning (the tier below the rotation nudge). |
| `context-date/` | One file per conversation, named by its id, holding the `YYYY-MM-DD` that conversation was last told; written at session start and advanced by `scope-prompt` when it emits the date note. Per conversation because a lead and a tmux teammate share this directory and each hears the date on its own. |
| `scope-prompt.trace` | One line per stage of each `scope-prompt` run, appended as that stage finishes — so a run its timeout killed still names the stage it hung on, a `launch` line written before the hook loads its library (a run killed that early leaves only this line), plus a `budget=<N>` line naming the budget the run settled on. A run that passed `CS_SCOPE_BUDGET_MS` before its scan records a `skip` stage and still exits normally. Opt out with `CS_SCOPE_TRACE_DISABLE=1`. |
| `rewrite.trace` | One line per `ctrl+g` invocation and the path it took. The rewriter shim draws onto a screen that is torn down and leaves the buffer unchanged on every one of its several do-nothing paths, so without this a rewrite that declined is indistinguishable from one that was never asked for. |
| `watermark` | Per-actor high-water mark for the "shared memory/narrative activity since you were last here" digest injected on resume. |
| `context-pct` | Latest context-window percentage of the launched conversation, stamped by the status line (a tmux teammate sharing the directory only touches the file, so its reading never replaces the lead's); the narrative reminder reads it to suggest compaction, the launch card reads it to say how full the conversation you are resuming already is, and ags-tui uses its mtime as the liveness heartbeat for conversations opened outside agent-sessions. A `<file>.at` beside it holds `epoch value` of the last write, so an unchanged reading is rewritten once a minute rather than every render. A teammate's touch keeps its own cadence record in `context-pct.heartbeat.at`, so neither side reads the other's write as a change. |
| `limits` | Latest 5-hour/weekly rate-limit readings, stamped by the status line; read by `ags -usage` window anchoring and the queue's rate-limit breaker. A `<file>.at` beside it holds `epoch value` of the last write, so an unchanged reading is rewritten once a minute rather than every render. |
| `failures` | Per-task tool-failure counter written by `tool-failure-logger.sh`; feeds the queue's failures circuit breaker, reset at each drain advance. |
| `mail/` | Cross-session mailbox, one JSON document per message: senders (`ags -msg`) write to the recipient's `tmp/` and rename into `new/` (atomic — a message is either entirely present or absent); `ags -msg` prints `new/*.json` and moves them to `cur/`. Unread is simply the count of `new/*.json`, the same basis for the prompt hook's digest, the status line, and the TUI. Filenames are `<zero-padded epoch>-<id>.json` — not a monotonic clock; nothing may treat name order as arrival order. `corrupt.jsonl` holds any legacy inbox lines that failed to parse during migration. (A legacy `inbox.jsonl` plus its `seen` cursor is converted on the next session open.) `out/` holds this session's own sent copies, so a thread can be re-read from either end. `woke` lists the filenames both mail wakes have already discharged — announced by a wake, or owned by the queue (`task` kind). Discharged means announced, never read: the message stays in `new/` until `ags -msg` prints it, so a spent announcement costs a wake and never a message. Anything that runs the hook against a live session's mailbox, a hand-run preview included, announces whatever it finds and leaves that mail silent but intact. The list is written tmp-then-rename under a per-process name because both wakes write it and the idle one overlaps itself. `wakes` counts wakes since the last user prompt, which clears it; `CS_MAIL_WAKE_MAX` (default 5) caps it. The directory is created at session start so Claude Code's file watcher has something to arm on: a watch given a path missing two levels never fires again for that process's lifetime. |
| `rotation-kick/` | Arms the `/clear` auto-start. session-start.sh creates it (a watch given a missing path never fires again for that process's lifetime), hands it over as `watchPaths`, and leaves a detached child to write `rotation.kick` into it once Claude Code's watch is up; that `FileChanged` wakes the session into the handoff's next step. `delivered` marks the kick spent, so the unlink that cleanup fires cannot wake the session on its own tail. Cleared at the start of each rotation, since a stale marker would make the new kick look already spent. |
| `spawned-by` | Spawner session name for a `ags -spawn`ed worker; deleted after the drain-finished notify (one-shot). A brief-only spawn writes it with no queue to drain, so it stays until a later queue in that session drains, and that drain reports to the spawner. |

## Encrypted sessions

A session can keep its private files on an encrypted volume. Four names under
`.cs/` become symlinks into the volume's mountpoint (by convention
`.cs/vault-mnt`), and each one is opt-in: agent-sessions only checks whether the link is
there.

| Link | What lives behind it |
|------|----------------------|
| `.cs/memory` | Auto-memory and the narratives. |
| `.cs/plans` | Plans and specs. |
| `.cs/claude-config` | Claude Code's config dir for this session. agent-sessions launches Claude Code with `CLAUDE_CONFIG_DIR` pointing here, so transcripts, prompt history, `.claude.json` and its backups never reach `~/.claude`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` keeps the shell's login (empty selects the default keychain entry). On every launch agent-sessions links the shell's `settings.json`, `settings.local.json`, `CLAUDE.md`, `AGENTS.md`, `rules/`, `skills/`, `commands/`, `agents/`, `hooks/`, `plugins/`, `output-styles/`, `keybindings.json` and `vale/` into it, skipping any name the session already has. A setting you change inside the session (`/model`, `/config`) writes through the link into the shell's `settings.json`. The first launch seeds `.claude.json` from the shell's copy with `projects` emptied, since each project entry keeps that project's last prompt. agent-sessions reads the session's transcripts from `projects/` here, and the picker does not rename such a session, because its links and transcripts name its path. |
| `.cs/private` | agent-sessions' own content files, which a plain session keeps in `.cs/local/`: `session.log`, `scope-prompt.trace`, `memory-index.snapshot`, `mail/`, the queue files (`queue/`, `queue.tmp/`, `queue.state`, `queue.done`, `queue.declined`, `queue.migrating`), `notifications.jsonl`, `notifications.seen`, `failures`, `rewrite.trace`, the rotation handoffs (`handoffs/`), `pending-handoff`, checkpoints (`checkpoints/`) and, when `.cs/memory` is a link, the rotated narrative sections (`narrative-archive/`). Numbers the status line writes (`context-pct`, `limits`) and ids (`state`, `spawned-by`, `rotate-nudged`, `ctx-warned`) stay in `.cs/local/`. |

### Encrypting a session with `ags -encrypt`

On macOS, `ags -encrypt <name>` sets this up for an existing session. Run it
from a terminal, with the session closed. It:

1. Creates an AES-256 encrypted sparse bundle at
   `~/.local/share/cs/vaults/<name>.sparsebundle` (`$CS_DATA_DIR/vaults/` when
   that is set, as the ags profile sets it) with `hdiutil`, which asks
   for a new password. The bundle grows as it fills, up to 50 GB. It lives
   outside the session directory, so `ags -rm` never deletes it.
2. Mounts it at `.cs/vault-mnt` (`hdiutil` asks for the password again) and
   turns Spotlight indexing off for it.
3. Moves `.cs/memory`, `.cs/plans`, the `.cs/local/` files listed under
   `.cs/private` above, and `.cs/handoffs`, `.cs/checkpoints` and
   `.cs/narrative-archive` into the volume, then links the four names into it.
4. Writes `.cs/local/pre-open` and `.cs/local/vault` (the bundle's path, which
   every later open attaches whatever `CS_DATA_DIR` says), tags
   the session `encrypted`, and unmounts the volume.

From then on every open asks for the password in the terminal. `pre-open`
refuses to open the session without a terminal, because without one `hdiutil`
shows a dialog that offers to save the password in the keychain. When the lead
conversation ends (not on `/clear` or `/resume`), the SessionEnd hook waits for
Claude Code to exit and unmounts the volume, unless the session reopened in
the meantime. The unmount is never forced: if something still holds the
volume, it stays mounted, and the next open unmounts it and asks for the
password. A second conversation opened while the session runs joins the
mounted volume without asking. An open that stops before Claude Code starts
(a refusal, or a cancelled prompt) unmounts the volume it mounted.

Every open that mounts or joins the volume adds its process id to
`.cs/local/vault-holders`. A process that replaces itself with Claude Code
keeps its id, so the entry stays valid while that conversation runs. agent-sessions
unmounts the volume only when no listed process and no session lock is
still alive, so a second conversation keeps it mounted after the first one
ends. An open that finds the volume mounted with nothing alive behind it
stops the old SessionEnd unmount first, then unmounts the volume and asks
for the password.

`ags -encrypt` refuses, before it writes anything, when:

- the machine is not a Mac, or stdin is not a terminal
- the session is running, adopted, or a feature worktree (`base@task`)
- any of the four names is already a link, or `.cs/claude-config` or
  `.cs/private` already exists as a folder or file
- `.cs/local/pre-open` already exists
- the bundle already exists
- `.cs/README.md` has no frontmatter for the tag

If a move fails partway, it stops, lists what moved and what did not, and
leaves the volume mounted so you can finish by hand; until you unmount it,
`ags -rm` and the picker's delete refuse to remove the session. When it finishes, it lists
the copies it cannot reach: the session's transcripts in `~/.claude/projects/`,
its lines in `~/.claude/history.jsonl`, its entries in `~/.claude.json` and that
file's backups, `.cs/summary.md` and `.cs/brief.md`, git history, and backups.

### Setting it up by hand

Mount the volume from `.cs/local/pre-open` (see the table above). While a link
points at a missing directory, the vault is locked, and agent-sessions writes nothing in
its place:

- `ags <name>` refuses to open the session and names the link.
- The hooks log nothing, deliver no mail wake and drain no queue.
- `ags -msg` to the session refuses the send. `ags -queue` in it refuses too.
- agent-sessions offers and consumes no rotation handoff.
- Opening a feature worktree (`base@task`) of the session refuses the same way.

A regular file at any of the four names also refuses the open. agent-sessions cannot tell
it from a locked vault, so the error names it.

Feature worktrees of an encrypted session are not supported yet. Creating or
opening one refuses even while the vault is mounted: a checkout of the links
`ags -encrypt` writes (`vault-mnt/<name>`, relative) points inside the worktree,
where nothing is mounted, and a base whose `.cs/` is ignored would give the
worktree plaintext files of its own.

Opening an encrypted session also refuses when a plaintext copy of a vault
file is still outside it: any of the `.cs/private` files above left in
`.cs/local/`, or a `.cs/handoffs/` or `.cs/checkpoints/` folder, or a plain
`.cs/narrative-archive/` beside a linked `.cs/memory`. The error names the file. Move it
into the vault or delete it. agent-sessions does not move it for you, because backups and
snapshots already hold the old copy.

With `.cs/private` present, the session protocol changes too:

- The objective, environment and outcome go at the top of the narrative. The
  prompt hook does not copy the first prompt into `.cs/README.md`, which keeps
  only its frontmatter. The first open adds a `cs:encrypted-protocol` section
  to `CLAUDE.local.md` that says so. Delete its text but keep the comment to
  opt out.
- The rotate skill writes the handoff into `.cs/private/handoffs/` and commits
  nothing from the vault.
- The launch prompt after answering `r` does not name the handoff file, and
  the `rotated` event in `timeline.jsonl` records the rotation without the
  file name. A handoff's name is its topic, and both of those are plaintext.
- `/checkpoint` saves into `.cs/private/checkpoints/`, and its `timeline.jsonl`
  event carries no label or file name.

A narrative behind a `.cs/memory` link rotates into the vault. `ags -narrative
rotate` writes through a `.cs/narrative-archive` link when there is one, and
into `.cs/private/narrative-archive/` otherwise. With neither, it refuses
rather than write plaintext. `/checkpoint` refuses in that case too, since a
checkpoint copies the narrative.

The mounted volume stays out of git and out of the session's removal:

- The autosave snapshot skips `.cs/vault-mnt` and every link target inside the
  session directory. New `.gitignore` files ignore `.cs/vault-mnt/`.
- `ags -rm` and the picker's delete refuse while a link resolves inside the
  session directory, or while the mount table shows any volume mounted inside
  it (an `ags -encrypt` that stopped before linking leaves one), even with
  `--force`, because removing it would delete what the volume holds. Unmount
  first. `/finish` does not retire a feature worktree with a volume mounted
  inside it, and `ags -uninstall` keeps the sessions root, without asking,
  while one is mounted anywhere inside it. All three also refuse when `mount`
  cannot list the table.
- Unmounted, the session removes like any other, `.cs/` included. Keep the
  volume's container (a disk image, a cipher directory) outside the session
  directory, or at its root where `ags -rm --force` names it and asks for
  `--delete-files`.

Link all four names. With only some of them, the rest leaks: `.cs/private`
without `.cs/claude-config`, for example, keeps the handoffs in the vault, but
Claude Code's transcript in `~/.claude/projects` records the start-of-session
context that names the handoff file and quotes the conversation.

Not covered: copies that backups and filesystem snapshots already made,
third-party hooks that write under `~/.claude` directly, `.cs/summary.md`
unless you link it into the vault yourself, the brief `ags -spawn --brief`
delivers (`.cs/brief.md`, staged in the sessions root's `.spawn/`).

## Merge policy

The session repo ships a `.gitattributes` that keeps append-heavy shared files
conflict-free:

- `merge=union` — `timeline.jsonl`, `narrative.*.md`: concurrent additions from
  different writers are both kept.
- `merge=ours` — `MEMORY.md`: the index is regenerated, so a machine keeps its
  own version rather than conflicting.

Human-authored prose (`README.md`, `summary.md`) uses the default merge — a
genuine divergence there is a real conflict a person should reconcile.

## Migration

Legacy layouts are migrated in place on the next `ags <name>` open, via the
numbered phases in `migrate_session()`: a flat pre-`.cs/` layout is moved under
`.cs/`, a legacy `discoveries.md` is folded into the narrative, retired
command-tracker files are pruned, and machine-local fields are moved out of
shared files into `.cs/local/`. Migration is idempotent — a modern session is
left untouched.

## Engine-local compatibility records

The product rebrand retains `.cs/` and the default root `~/.claude-sessions/`, and
never moves a stable install's sessions. Only setup's profile renamed its root, from
`.claude-sessions/` to `sessions/`; see [Migration](migration.md). `.cs/local/state` stores the selected `engine` and, once Claude has
been prepared, `claude_session_id` and `claude_session_color`. Codex stores its
independent exact ID in `.cs/local/codex-thread-id` and refreshes startup context
in `.cs/local/codex-instructions.md`. These files remain machine-local.
Codex-only sessions do not require Claude instruction or settings files. Shared
memory/plans are portable Markdown, while native auto-memory redirection is a
Claude adapter feature. See [Migration](migration.md).
