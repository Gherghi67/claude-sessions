---
model: opus
name: switch
description: Switch this ags session to the other engine (Claude <-> Codex) - write and arm a rotation handoff by the rotate skill's own steps, record the move with `ags -switch`, and tell the user to exit so ags reopens the session under the other engine from that handoff. Invoke only when the user asks to switch engines.
disable-model-invocation: true
---

Switching is a rotation that changes engines. You distill the work into a
handoff and arm it exactly as the rotate skill does, then `ags -switch`
records where the session goes next. When the user exits this CLI, ags —
still waiting on it in the same terminal — reopens the session under the
other engine, and a fresh conversation there continues from the handoff.
This skill writes the handoff, the marker and the pending switch. It never
ends the conversation and never launches anything: the exit is the user's
(under Claude, the `ags` mod's countdown can take it), and the relaunch is
ags's.

## Prerequisites

Only works in an ags session: check that `$CS_SESSION_NAME` is set. If
empty, tell the user switching engines needs an ags session and stop.

Run `ags -engine` and note its `engine:` line: the engine this conversation
runs under. The steps below differ between Claude and Codex, and rotate's
step 1 reads the `conversation:` line of the same output.

Take the target and the option from the user's message, the one that invoked
this skill: an engine name, `claude` or `codex`, and optionally `--resume`.
Codex hands a skill no arguments (it never substitutes the arguments
placeholder), so under both engines read them from the user's message; do
not wait for them to arrive any other way. No engine named means the other
one: `claude` switches to `codex`, `codex` to `claude`. A target equal to the
current engine is not a switch: `ags -switch` refuses it, and the rotate
skill is what the user wants.

`--resume` changes what the target opens. Instead of a fresh conversation,
ags resumes the target engine's last conversation in this session and hands
it the handoff as its first new message: a heavier, possibly stale context,
traded for that conversation's full detail. Pass it only when the user asked
for it; the default is fresh.

A switch needs a purpose, as a rotation does: one line saying what the next
conversation should do. If the user did not give one, take it from the
conversation (the work in flight and its next step). Do not stop to ask.

Refuse, and write nothing, while anything this conversation started in the
background is still running: background agents, workflows, monitors,
background shells (under Codex, any background terminal it started). Exiting
the CLI ends them with it, and their results would land nowhere. Tell the
user what is still running and to wait for it or stop it, then switch.

Then ask ags whether the switch can happen, BEFORE writing anything:

```
ags -switch --check <target>
```

(with `--resume` appended when the user asked for it). It runs every check
the switch itself makes except the armed handoff, which does not exist yet:
the session's live ags run (the one this conversation runs in), a known
engine other than this one, the target installed with its
CLI found and its adapter declaring `rotation`, no switch already pending,
and, in an encrypted session, the vault mounted with no plaintext session
files left beside it and a target that reads its handoffs from the vault
(Codex does not yet, so an encrypted session cannot switch into Codex). It
writes nothing. If it exits
non-zero, print the line it printed (it names the fix) and stop: no handoff,
no commit, no marker. A handoff written for a switch that cannot happen is
armed for a `/clear` the user never asked for.

Under Codex the launch's sandbox is read-only, so Codex may ask the user to
approve the `ags -switch` calls (the one in step 3 writes into `.cs/`), as it
does the handoff's own writes. Say so before the first one, so the approval
is expected.

**Encrypted session.** Rotate's own section applies: the handoffs, the
marker and the session log live under `.cs/private/`, and nothing from the
vault is committed. `ags -switch` keeps its record there too,
`.cs/private/pending-switch` instead of `.cs/local/pending-switch`.

## Process

1. Read the rotate skill: `../rotate/SKILL.md`, relative to the folder this
   SKILL.md was loaded from. Claude Code shows that folder as the skill's
   base directory when it loads the skill; Codex names the path of this
   SKILL.md when it lists or injects the skill, and the rotate skill sits
   beside it in the same skills directory. Read it with your file-read tool,
   one call (not `cat` through the shell), and apply what it says rather
   than a remembered paraphrase: its steps are the single source, and they
   change.

2. Run rotate's Process steps 1-9 exactly as its file writes them, with its
   Prerequisites' rules for the purpose and the encrypted session, through
   its last one, which arms the marker. Two things differ:

   - The handoff's purpose line names the move:
     `purpose: Continue under <target>: <next step>`, for example
     `purpose: Continue under codex: rerun the secrets suites solo`.
   - Rotate's capability check is the target's here, and
     `ags -switch --check` above already made it.

   Do not run rotate's steps 10 and 11: they send the user to `/clear`,
   which hands the handoff to this engine. Steps 3-5 below replace them.

3. Record the switch, once the marker is armed:

   ```
   ags -switch <target>
   ```

   (with `--resume` appended when the user asked for it). It reads the armed
   handoff and writes the pending switch (target, mode, the handoff's
   basename and this run), then prints one line saying how to exit.

   If it says no rotation handoff is armed, rotate's step 9 did not land:
   arm the handoff as that step says and run `ags -switch <target>` again.
   Any other refusal means something changed since the check: a switch
   recorded from another shell, the vault unmounted, the target's CLI gone.
   Print the line it printed and tell the user the handoff stays armed: `/clear`
   continues from it in this engine, or they fix the cause and run
   `ags -switch <target>` again. Under Claude, say too that the `ags` mod's
   countdown runs that `/clear` itself twenty seconds after this turn ends,
   unless they send a prompt (which stops it) or launched with
   `CS_ROTATE_FORCE_CTX=off`. Then end with rotate's step 11 line for this
   engine, not this skill's.

4. Tell the user what happens next:

   - Once this CLI exits, ags reopens this session in the same terminal
     under the target: a fresh conversation that starts from the handoff.
     With `--resume`, it resumes the target's last conversation in this
     session instead, with the handoff as its first new message; when the
     target has no conversation recorded here, ags says so and starts a
     fresh one.
   - The new conversation begins the handoff's next step by itself, under
     either engine: ags launches it with the handoff as its opening prompt
     (Claude's launch prompt, Codex's starting prompt), so there is nothing
     to type, not even `go`.
   - Under Claude (`engine: claude`), the `ags` mod counts twenty seconds
     down once this turn ends and runs `/exit` itself; its key on the capsule
     reads `/exit and continue in codex` (Ctrl+X 1, if they bound it). A prompt they send stops the count
     (it starts again when that turn ends) and keeps this conversation; the
     switch stays pending for a later exit. Launched with
     `CS_ROTATE_FORCE_CTX=off` (or `0`), there is no countdown: the key or a
     typed `/exit` is theirs. With function hooks withheld
     (`CS_NO_FUNCTION_HOOKS=1`) there is no mod at all, so they type `/exit`.
   - Under Codex (`engine: codex`) there is no countdown: they quit Codex
     themselves with `/quit`. A `/clear` cannot change engines.
   - The old conversation stays on disk, untouched:
     `ags <session-name> --engine <current engine>` opens it again later.
   - To call the switch off before exiting: `ags -switch cancel`. The
     handoff stays armed, so `/clear` then continues in this engine.
   - A `/clear` instead of the exit takes the handoff in this engine, and ags
     drops the switch with a notice when the CLI exits. If the CLI exits with
     an error or the relaunch fails, ags prints both ways back
     (`ags <session-name> --engine <target> --from-handoff` and
     `ags <session-name> --engine <current engine>`) and the handoff stays
     armed.

5. End your response with the instruction and nothing after it, on its own
   final line, exactly. Under Claude the line is:

   **Run `/exit` now** (or press the capsule above the prompt, or Ctrl+X 1 if you bound it) — ags reopens this session under Codex.

   Under Codex the line is, exactly:

   **Quit Codex now (`/quit`)** — ags reopens this session under Claude.

   This is the one step you cannot take for the user: ags relaunches only
   after the CLI it waits on has exited. A hook cannot exit for them; the
   `ags` mod's key and countdown can under Claude, and they run `/exit`
   rather than `/clear` because the pending switch is recorded. Codex has no
   key and no countdown: the quit is theirs. The line must not end up buried
   under a summary of what you just wrote.
