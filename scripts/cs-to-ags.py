#!/usr/bin/env python3
# ABOUTME: Gives ags a project the stable cs adopted, its feature worktrees, Claude history and secrets.
# ABOUTME: The stable cs is left as it is: ags links to the same folders and gets copies of the rest.
"""Open a cs session in ags, leaving the stable cs as it is.

ags refuses to adopt a folder that already has .cs/, so a project the stable
cs adopted cannot simply be adopted again. This script hands it to ags
instead, so `ags <name>` opens it on the conversations cs left off with,
while everything cs has stays where it is and as it is:

- The session (a project cs adopted, so a link in ~/.claude-sessions) gets
  the same link in the profile's sessions root. Its .cs/ lives in the
  project, so notes, handoffs and the conversation binding are shared.
- Each feature worktree (<name>@<task>) gets a link in the profile's sessions
  root to its folder in ~/.claude-sessions, where ags looks for features: one
  worktree, which both can open. git checks a branch out in one worktree only.
- Each session's Claude conversations are copied from ~/.claude/projects into
  the profile's, under the same folder names (the paths do not change), whole:
  subagents, workflows, tool results. Their file-history, session-env and task
  list come too, and the session's prompt history from history.jsonl. On APFS
  a copy is a clone and costs no space.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more; they come too, as history (--no-history
  leaves them out).
- Trust and per-project settings in ~/.claude.json and ~/.codex/config.toml
  are copied into the profile's, while no ags session is running.
- Secrets are copied from the stable cs store into the profile's encrypted
  store, through cs-secrets and ags-secrets, values on stdin only.

Nothing outside the profile is written: ~/.claude-sessions, the project and
its feature folders, ~/.claude, ~/.claude.json, ~/.codex and the keychain are
only read. Every change is recorded in the profile's .cs-to-ags/log.jsonl.
A rerun skips what is already there and brings over what grew.

Both managers can open the session afterwards, and they share its
.cs/local/state, while each resumes conversations only it has. Open it from
ags; to go back to cs, run scripts/ags-to-cs.py first, which copies what ags
added. A session open in cs while this runs is named: what it writes later
comes over on a rerun.

Left behind, and said so: an encrypted session, a session cs created in its
own folder, a feature worktree git does not list, and anything whose name ags
already uses for something else.

    scripts/cs-to-ags.py --session wap            # print what would happen; change nothing
    scripts/cs-to-ags.py --session wap --apply    # do it

Paths come from HOME and the options below, never from CS_* variables: inside
a session those name the session manager running it.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

from session_transfer import (
    SecretsError, claude_project_key, copy_secret, merge_tree, read_text, scrubbed_env,
    secret_names, session_is_open, state_value, tilde, write_atomic,
)

TMP_SUFFIX = ".cs-to-ags.tmp"
TMP_PREFIX = ".cs-to-ags."
VAULT_LINKS = ("memory", "plans", "claude-config", "private")
# What keeps a conversation open in a folder: an engine, or the session manager running one.
ENGINES = {"claude", "codex", "cs", "ags"}
# Fields of a .claude.json project entry that describe its last run, not its settings.
VOLATILE = re.compile(r"^(last|exampleFiles)")
SCRATCH = re.compile(r"^-private-tmp-claude-\d+-")
# A conversation's scratch folder: <project>/<conversation id>/scratchpad[/...].
SCRATCHPAD = r"-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-scratchpad(?:-|$)"


class Session:
    """The base or one of its feature worktrees, as cs has it and as ags will."""

    def __init__(self, importer, name, cs_path):
        self.name = name
        self.cs_path = cs_path
        self.target = None
        self.source = None
        self.skip = None
        self.state = None   # free, or ours (ags already links to it)
        self.ags_path = os.path.join(importer.ags_root, name)

    @property
    def meta(self):
        return os.path.join(self.source, ".cs")

    def ags_state(self):
        if not os.path.lexists(self.ags_path):
            return "free"
        if os.path.islink(self.ags_path) and os.path.realpath(self.ags_path) == self.source:
            return "ours"
        return None


class Importer:
    def __init__(self, args):
        expand = lambda p: os.path.abspath(os.path.expanduser(p))
        self.apply = args.apply
        self.history = not args.no_history
        self.profile = expand(args.profile)
        self.cs_root = expand(args.cs_root)
        self.claude_dir = expand(args.claude_dir)
        self.claude_json = expand(args.claude_json)
        self.codex_home = expand(args.codex_home)
        self.cs_secrets = expand(args.cs_secrets)
        self.names = args.session
        self.ags_root = os.path.join(self.profile, "sessions")
        if not os.path.isdir(self.ags_root):
            raise SystemExit("No ags sessions root at %s; run setup.sh first, or pass --profile." % tilde(self.ags_root))
        self.ags_claude = os.path.join(self.profile, ".claude")
        self.ags_secrets = os.path.join(self.profile, ".local", "bin", "ags-secrets")
        self.ags_secrets_dir = os.path.join(self.profile, ".cs-secrets")
        self.log_path = os.path.join(self.profile, ".cs-to-ags", "log.jsonl")
        self.failed = False

    # --- planning -------------------------------------------------------

    def plan(self, name):
        base = Session(self, name, os.path.join(self.cs_root, name))
        base.features = []
        base.open_now = []
        if not os.path.lexists(base.cs_path):
            raise SystemExit("No cs session named %s in %s." % (name, tilde(self.cs_root)))
        if not os.path.islink(base.cs_path):
            base.skip = ("cs created this session in its own folder; this script hands over projects cs "
                         "adopted (a link in %s)" % tilde(self.cs_root))
            return base
        base.target = os.readlink(base.cs_path)
        base.source = os.path.realpath(base.cs_path)
        if not os.path.isabs(base.target):
            base.target = base.source
        if not os.path.isdir(base.source):
            base.skip = "its directory %s no longer exists" % tilde(base.target)
            return base
        if not os.path.isdir(base.meta):
            base.skip = "%s has no .cs folder" % tilde(base.source)
            return base
        if os.path.lexists(os.path.join(base.meta, "local", "pre-open")) or any(
                os.path.islink(os.path.join(base.meta, sub)) for sub in VAULT_LINKS):
            base.skip = "encrypted: its vault opens only with its password, so this script leaves it"
            return base
        base.state = base.ags_state()
        if base.state is None:
            base.skip = "ags already has a different %s; remove that one, then rerun" % name
            return base
        self.plan_features(base)
        base.open_now = self.open_sessions(base)
        return base

    def plan_features(self, base):
        registered = self.git(base.source, "worktree", "list", "--porcelain").stdout
        registered = {line[len("worktree "):] for line in registered.splitlines() if line.startswith("worktree ")}
        prefix = base.name + "@"
        for entry in sorted(os.listdir(self.cs_root)):
            if not entry.startswith(prefix) or len(entry) == len(prefix):
                continue
            feature = Session(self, entry, os.path.join(self.cs_root, entry))
            base.features.append(feature)
            feature.source = os.path.realpath(feature.cs_path)
            if not os.path.isdir(os.path.join(feature.source, ".cs")):
                feature.skip = "not a cs session (no .cs folder)"
                continue
            top = self.git(feature.source, "rev-parse", "--show-toplevel").stdout.strip()
            if (top or feature.source) not in registered:
                feature.skip = ("not a registered worktree of %s's repository (pruned or made by hand?)"
                                % base.name)
                continue
            feature.state = feature.ags_state()
            if feature.state is None:
                feature.skip = "ags already has a different %s; remove that one, then rerun" % entry

    def open_sessions(self, base):
        """Which of the session's folders an engine or a session manager runs in right now.

        A lock is not enough: cs execs claude in its place, and the lock goes with it.
        """
        sessions = [base] + [f for f in base.features if not f.skip]
        found = {s.name: [] for s in sessions if session_is_open(s.meta)}
        try:
            listing = subprocess.run(["lsof", "-a", "-d", "cwd", "-F", "pn"], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True).stdout
            table = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True).stdout
        except OSError:
            listing = table = ""
        commands = {}
        for line in table.splitlines():
            pid, _, command = line.strip().partition(" ")
            commands[pid] = command.strip()
        inside = lambda cwd, root: cwd == root or cwd.startswith(root + os.sep)
        # The deepest folder first: a feature may live inside the project.
        by_depth = sorted(sessions, key=lambda s: len(s.source), reverse=True)
        pid = None
        for line in listing.splitlines():
            if line.startswith("p"):
                pid = line[1:]
                continue
            command = commands.get(pid, "")
            if not line.startswith("n") or not command or pid == str(os.getpid()):
                continue
            if not {os.path.basename(w) for w in command.split()[:2]} & ENGINES:
                continue
            where = next((s.name for s in by_depth if inside(line[1:], s.source)), None)
            if where:
                found.setdefault(where, []).append((pid, command))
        out = []
        for name in sorted(found):
            if found[name]:
                pid, command = found[name][0]
                more = ", and %d more" % (len(found[name]) - 1) if len(found[name]) > 1 else ""
                out.append("%s (pid %s: %s%s)" % (name, pid, command[:50], more))
            else:
                out.append(name)
        return out

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", cwd] + list(args), stdin=subprocess.DEVNULL,
                              capture_output=True, text=True)

    def ags_running(self):
        """Lines of processes run from the profile's bin, which write the files we would merge into."""
        try:
            listing = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True).stdout
        except OSError:
            return ["(could not list processes)"]
        needle = os.path.join(os.path.realpath(self.profile), ".local", "bin") + os.sep
        return [line.strip() for line in listing.splitlines() if needle in line]

    # --- the parts of one session ----------------------------------------

    def log(self, action, **fields):
        if not self.apply:
            return
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        fields.update(action=action, at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        with open(self.log_path, "a") as f:
            f.write(json.dumps(fields, sort_keys=True) + "\n")

    def conversations(self, key):
        """Merge one Claude folder and each conversation's side files; the tally and conversation count."""
        src = os.path.join(self.claude_dir, "projects", key)
        tally = merge_tree(src, os.path.join(self.ags_claude, "projects", key), self.apply, TMP_SUFFIX)
        count = 0
        if os.path.isdir(src):
            for name in sorted(os.listdir(src)):
                if name.endswith(".jsonl"):
                    count += 1
                    conversation = name[:-len(".jsonl")]
                    for side in ("file-history", "session-env"):
                        tally.add(merge_tree(os.path.join(self.claude_dir, side, conversation),
                                             os.path.join(self.ags_claude, side, conversation),
                                             self.apply, TMP_SUFFIX))
        return tally, count

    def history_keys(self, base):
        """Claude folders of the session's retired features and scratch folders: no session owns them now."""
        projects = os.path.join(self.claude_dir, "projects")
        if not os.path.isdir(projects):
            return []
        family = claude_project_key(os.path.join(os.path.realpath(self.cs_root), base.name + "@"))
        main = claude_project_key(base.source)
        owned = {main}
        owned.update(claude_project_key(f.source) for f in base.features if f.source)
        # Every other cs session, by its real and its link path: a key is lossy,
        # so wap@foo and a session called wap-foo share a folder name.
        others = set()
        for entry in os.listdir(self.cs_root):
            if entry == base.name or entry.startswith(base.name + "@"):
                continue
            path = os.path.join(self.cs_root, entry)
            others.add(claude_project_key(os.path.realpath(path)))
            others.add(claude_project_key(os.path.join(os.path.realpath(self.cs_root), entry)))
        keys = []
        for key in sorted(os.listdir(projects)):
            if key in owned or not os.path.isdir(os.path.join(projects, key)):
                continue
            scratch = SCRATCH.match(key)
            core = key[scratch.end():] if scratch else key
            if scratch:
                ours = bool(re.match(re.escape(main) + SCRATCHPAD, core)) or (
                    core.startswith(family) and re.search(SCRATCHPAD, core) is not None)
            else:
                ours = core.startswith(family)
            if ours and not any(core == o or core.startswith(o + "-") for o in others):
                keys.append(key)
        return keys

    def prompt_history(self, base, paths):
        """Lines of history.jsonl for the session's paths that the profile's lacks."""
        src = os.path.join(self.claude_dir, "history.jsonl")
        dst = os.path.join(self.ags_claude, "history.jsonl")
        text = read_text(src)
        if not text:
            return 0
        family = os.path.join(os.path.realpath(self.cs_root), base.name + "@")
        have = set((read_text(dst) or "").splitlines())
        out = []
        for line in text.splitlines():
            try:
                record = json.loads(line)
            except ValueError:
                continue
            project = record.get("project") if isinstance(record, dict) else None
            if not isinstance(project, str):
                continue
            if project not in paths and not (self.history and project.startswith(family)):
                continue
            if line not in have:
                have.add(line)
                out.append(line)
        if out and self.apply:
            os.makedirs(self.ags_claude, exist_ok=True)
            existing = read_text(dst) or ""
            with open(dst, "a") as f:
                f.write(("\n" if existing and not existing.endswith("\n") else "") + "\n".join(out) + "\n")
            self.log("appended-prompt-history", lines=len(out))
        return len(out)

    def project_settings(self, paths):
        """Copy each path's settings from ~/.claude.json into the profile's, keeping what the profile has."""
        stable = json.loads(read_text(self.claude_json) or "{}")
        target = os.path.join(self.ags_claude, ".claude.json")
        raw = read_text(target)
        profile = json.loads(raw) if raw else {}
        projects = profile.setdefault("projects", {})
        changed = []
        for path in sorted(paths):
            entry = (stable.get("projects") or {}).get(path)
            if not isinstance(entry, dict):
                continue
            mine = projects.setdefault(path, {})
            added = [k for k in sorted(entry) if not VOLATILE.match(k) and k not in mine]
            for key in added:
                mine[key] = entry[key]
            if added:
                changed.append(path)
        if changed and self.apply:
            write_atomic(target, (json.dumps(profile, indent=2, ensure_ascii=False) + "\n").encode(),
                         prefix=TMP_PREFIX)
            self.log("merged-claude-project-settings", paths=changed)
        return changed

    def codex_trust(self, paths):
        """Append to the profile's Codex config each path's project table from the Codex config outside ags."""
        stable = (read_text(os.path.join(self.codex_home, "config.toml")) or "").splitlines()
        target = os.path.join(self.profile, ".codex", "config.toml")
        mine = read_text(target)
        if mine is None:
            return []
        added, blocks = [], []
        for path in sorted(paths):
            header = '[projects."%s"]' % path
            if header not in stable or header in mine.splitlines():
                continue
            body = []
            for line in stable[stable.index(header) + 1:]:
                if line.startswith("["):
                    break
                body.append(line)
            while body and not body[-1].strip():
                body.pop()
            blocks.append("%s\n%s\n" % (header, "\n".join(body)))
            added.append(path)
        if blocks and self.apply:
            text = mine if mine.endswith("\n") or not mine else mine + "\n"
            write_atomic(target, (text + "\n" + "\n".join(blocks)).encode(), prefix=TMP_PREFIX)
            self.log("added-codex-trust", paths=added)
        return added

    def secrets(self, session):
        """Names to copy, names ags already has, and any problem reading either."""
        cs_env = scrubbed_env()
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        if not os.access(self.cs_secrets, os.X_OK):
            return [], [], "%s is missing; pass --cs-secrets" % tilde(self.cs_secrets)
        try:
            names = secret_names([self.cs_secrets], cs_env, session)
            if not names:
                return [], [], None
            if not os.access(self.ags_secrets, os.X_OK):
                raise SecretsError("%s is missing; run setup.sh" % tilde(self.ags_secrets))
            have = set(secret_names([self.ags_secrets], ags_env, session))
        except SecretsError as error:
            return [], [], str(error)
        return [n for n in names if n not in have], [n for n in names if n in have], None

    def copy_secrets(self, session, names):
        cs_env = scrubbed_env()
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        failed = [name for name in names
                  if not copy_secret([self.cs_secrets, "--session", session, "get", name], cs_env,
                                     [self.ags_secrets, "--session", session, "set", name], ags_env)]
        if len(failed) < len(names):
            self.log("copied-secrets", session=session, names=[n for n in names if n not in failed])
        return failed

    # --- running ---------------------------------------------------------

    def run(self):
        print("cs sessions: %s   Claude: %s" % (tilde(self.cs_root), tilde(self.claude_dir)))
        print("ags profile: %s" % tilde(self.profile))
        bases = [self.plan(name) for name in self.names]
        for base in bases:
            print()
            try:
                self.handle(base)
            except OSError as error:
                self.problem("stopped: %s" % error)
        print()
        if not self.apply:
            print("Dry run: nothing changed. Run again with --apply to hand it over.")
        elif self.failed:
            print("Handed over what could be; the items marked ! above were not.")
        else:
            print("Done. Open it with: ags %s" % " / ags ".join(self.names))
        return 1 if self.failed else 0

    def say(self, text, mark=" "):
        print("  %s %s" % (mark, text))

    def problem(self, text):
        self.failed = True
        self.say(text, "!")

    def report_tally(self, what, tally, count):
        verb = "copied" if self.apply else "to copy"
        if tally.pending():
            parts = []
            if tally.new:
                parts.append("%d new" % tally.new)
            if tally.grown:
                parts.append("%d grown since the last copy" % tally.grown)
            self.say("%s, %d conversation(s), files %s: %s" % (what, count, verb, ", ".join(parts)))
        elif not tally.diverged:
            self.say("%s, %d conversation(s): nothing new" % (what, count))
        if tally.ahead:
            self.say("%d ags file(s) went on past the cs copy; kept" % tally.ahead)
        for path in tally.diverged:
            self.problem("continued in both cs and ags, left as it is: %s" % tilde(path))

    def link(self, session, what):
        will = "" if self.apply else "would "
        if session.state == "ours":
            self.say("%s: already in ags at %s" % (session.name, tilde(session.ags_path)))
            return
        self.say("%s: %slink %s -> %s%s" % (session.name, will, tilde(session.ags_path), tilde(session.target), what))
        if self.apply:
            os.symlink(session.target, session.ags_path)
            self.log("linked", session=session.name, path=session.ags_path, target=session.target)

    def handle(self, base):
        if base.skip:
            print("%s: not handed over" % base.name)
            self.problem(base.skip)
            return
        print(base.name)
        if base.open_now:
            self.say("note: open in cs right now: %s. What it writes from here on comes over on a rerun, "
                     "once it is closed" % ", ".join(base.open_now))

        # 1. Links: ags opens the same folders cs does.
        self.link(base, "")
        for feature in base.features:
            if feature.skip:
                self.problem("%s: not linked: %s" % (feature.name, feature.skip))
                continue
            feature.target = feature.source
            branch = self.git(feature.source, "branch", "--show-current").stdout.strip()
            self.link(feature, " (on %s)" % (branch or "a detached HEAD"))
        sessions = [base] + [f for f in base.features if not f.skip]

        # 2. Claude conversations, under the same folder names: the paths do not change.
        for session in sessions:
            tally, count = self.conversations(claude_project_key(session.source))
            self.report_tally("Claude history of %s" % session.name, tally, count)
        claude_id = state_value(base.meta, "claude_session_id")
        if claude_id and os.path.isfile(os.path.join(self.claude_dir, "projects", claude_project_key(base.source),
                                                     claude_id + ".jsonl")):
            self.say("ags %s resumes conversation %s" % (base.name, claude_id))
        for session in sessions:
            tally = merge_tree(os.path.join(self.claude_dir, "tasks", session.name),
                               os.path.join(self.ags_claude, "tasks", session.name), self.apply, TMP_SUFFIX)
            if tally.pending():
                self.say("task list of %s: %d file(s) %s"
                         % (session.name, tally.pending(), "copied" if self.apply else "to copy"))
        if self.history:
            keys = self.history_keys(base)
            total, conversations = None, 0
            for key in keys:
                tally, count = self.conversations(key)
                conversations += count
                if total is None:
                    total = tally
                else:
                    total.add(tally)
            if keys:
                self.report_tally("history of %d retired feature and scratch folder(s), no session"
                                  % len(keys), total, conversations)
        paths = {s.source for s in sessions}
        lines = self.prompt_history(base, paths)
        if lines:
            self.say("prompt history: %d line(s) %s" % (lines, "appended" if self.apply else "to append"))

        # 3. Trust and per-project settings, which a running ags may rewrite under us.
        running = self.ags_running()
        if running:
            self.say("note: an ags session is running (%s), so .claude.json and the Codex config are left; "
                     "rerun once none is open" % running[0][:80])
        else:
            changed = self.project_settings(paths)
            if changed:
                self.say("Claude project settings %s for %s" % ("merged" if self.apply else "to merge",
                                                                 ", ".join(tilde(p) for p in changed)))
            added = self.codex_trust(paths)
            if added:
                self.say("Codex trust %s for %s" % ("added" if self.apply else "to add",
                                                    ", ".join(tilde(p) for p in added)))

        # 4. Secrets. A feature's go through its base, but one may hold its own.
        for session in sessions:
            missing, present, error = self.secrets(session.name)
            if error:
                self.problem("secrets of %s: %s" % (session.name, error))
            if present:
                self.say("secrets of %s ags already has, kept: %s" % (session.name, ", ".join(present)))
            if missing:
                self.say("secrets of %s %s: %s" % (session.name, "copied" if self.apply else "to copy",
                                                    ", ".join(missing)))
                if self.apply:
                    for name in self.copy_secrets(session.name, missing):
                        self.problem("secret %s of %s was not copied" % (name, session.name))
        if self.apply:
            self.say("cs keeps %s as it was. Open it from ags; to go back to cs, run "
                     "scripts/ags-to-cs.py --session %s first" % (base.name, base.name))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Give ags a session the stable cs adopted, with its feature worktrees, Claude history and "
                    "secrets, leaving cs as it is.",
        epilog="Prints what it would do unless --apply is given. Nothing outside the ags profile is written.")
    parser.add_argument("--session", action="append", required=True, metavar="NAME",
                        help="the cs session to hand over (repeatable); its features come with it")
    parser.add_argument("--apply", action="store_true", help="hand it over; without it nothing is written")
    parser.add_argument("--no-history", action="store_true",
                        help="leave out the conversations of retired features and scratch folders")
    parser.add_argument("--profile", default="~/.local/share/agent-sessions/home",
                        help="the ags profile (default: %(default)s)")
    parser.add_argument("--cs-root", default="~/.claude-sessions",
                        help="the stable cs sessions root (default: %(default)s)")
    parser.add_argument("--claude-dir", default="~/.claude",
                        help="the Claude config dir the stable cs runs Claude Code on (default: %(default)s)")
    parser.add_argument("--claude-json", default="~/.claude.json",
                        help="Claude Code's state file beside it (default: %(default)s)")
    parser.add_argument("--codex-home", default="~/.codex",
                        help="the Codex home outside ags (default: %(default)s)")
    parser.add_argument("--cs-secrets", default="~/.local/bin/cs-secrets",
                        help="the stable cs secrets command (default: %(default)s)")
    args = parser.parse_args(argv)
    for name in args.session:
        if "@" in name or "/" in name or name.startswith("."):
            parser.error("--session %s: name a base session; its feature worktrees come with it" % name)
    return Importer(args).run()


if __name__ == "__main__":
    sys.exit(main())
