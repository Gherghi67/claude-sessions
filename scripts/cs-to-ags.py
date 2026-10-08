#!/usr/bin/env python3
# ABOUTME: Moves a project the stable cs adopted, with its feature worktrees, Claude history and secrets, into ags.
# ABOUTME: After it, the session opens with `ags <name>` only; scripts/ags-to-cs.py stays the way back.
"""Move a cs session into the ags profile.

ags refuses to adopt a folder that already has .cs/, because the stable cs
and ags would then share .cs/local/state while each resumes a conversation
the other cannot see. This script hands such a session over instead, so ags
opens it on the conversations cs left off with:

- The session (a project cs adopted, so a link in ~/.claude-sessions) gets the
  same link in the profile's sessions root. Its .cs/ lives in the project, so
  its notes, handoffs and conversation binding come along as they are.
- Each feature worktree (<name>@<task>) moves with `git worktree move` into
  the profile's sessions root, where ags looks for features: the same branch,
  index, uncommitted and untracked files, per-worktree refs and ignored files
  such as node_modules. A branch-out registry entry for it follows it.
- Each session's Claude conversations are copied from ~/.claude/projects into
  the profile's, under the folder name Claude Code gives the session's path in
  ags, whole: subagents, workflows, tool results. Their file-history,
  session-env and task list come too, and the session's prompt history in
  history.jsonl. On APFS a copy is a clone and costs no space.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more; they are copied under their own folder names
  as history (--no-history leaves them out).
- Trust and per-project settings in ~/.claude.json and ~/.codex/config.toml
  follow each path, while no ags session is running.
- Secrets go from the stable cs store into the profile's encrypted store,
  through cs-secrets and ags-secrets, values on stdin only.
- The session protocol in CLAUDE.local.md is reworded from cs to ags.
- Last, cs's own link is removed, once everything else of that session came
  over, so the session is opened from ags only.

~/.claude, ~/.claude.json and ~/.codex are only read, and the keychain's
secrets stay where they are. Every change is recorded in the profile's
.cs-to-ags/log.jsonl. A rerun skips what is already there and brings over what
grew.

Left behind, and said so: a session open right now (close it and its features,
then rerun), an encrypted session, a session cs created in its own folder, a
feature worktree git cannot move (locked, or with submodules) and anything
whose name ags already uses for something else.

    scripts/cs-to-ags.py --session wap            # print what would happen; change nothing
    scripts/cs-to-ags.py --session wap --apply    # move it

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
    CS_TO_AGS_WORDING, SecretsError, claude_project_key, copy_secret, merge_tree, read_text,
    reword_protocol, scrubbed_env, secret_names, session_is_open, state_value, tilde, write_atomic,
)

TMP_SUFFIX = ".cs-to-ags.tmp"
TMP_PREFIX = ".cs-to-ags."
MARKER = os.path.join(".cs", "local", "cs-origin")
VAULT_LINKS = ("memory", "plans", "claude-config", "private")
# Fields of a .claude.json project entry that describe its last run, not its settings.
VOLATILE = re.compile(r"^(last|exampleFiles)")
# What keeps a conversation open in a project: an engine, or the session manager running one.
ENGINES = {"claude", "codex", "cs", "ags"}
SCRATCH = re.compile(r"^-private-tmp-claude-\d+-")
# A conversation's scratch folder: <project>/<conversation id>/scratchpad[/...].
SCRATCHPAD = r"-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-scratchpad(?:-|$)"


def physical_join(root, name):
    return os.path.join(os.path.realpath(root), name)


class Feature:
    def __init__(self, base, task, cs_path):
        self.base = base
        self.task = task
        self.name = "%s@%s" % (base.name, task)
        self.cs_path = cs_path
        self.source = os.path.realpath(cs_path) if cs_path else None
        self.skip = None
        self.failed = False
        self.state = None   # free, moved (by an earlier run) or linked-back (ags-to-cs left a link)
        self.registry = []

    @property
    def ags_path(self):
        return os.path.join(self.base.importer.ags_root, self.name)

    @property
    def ags_physical(self):
        return physical_join(self.base.importer.ags_root, self.name)

    @property
    def old_physical(self):
        """Where the feature lived in cs, which names its Claude folder there."""
        if self.state == "moved":
            return (read_text(os.path.join(self.ags_physical, MARKER)) or "").strip()
        return self.source


class Base:
    def __init__(self, importer, name):
        self.importer = importer
        self.name = name
        self.cs_path = os.path.join(importer.cs_root, name)
        self.target = None
        self.source = None
        self.skip = None
        self.blocker = None
        self.failed = False
        self.state = None   # free, ours (the ags link exists) or moved (cs's link is gone already)
        self.features = []
        self.notes = []

    @property
    def ags_path(self):
        return os.path.join(self.importer.ags_root, self.name)

    @property
    def meta(self):
        return os.path.join(self.source, ".cs")

    def family_failed(self):
        return self.failed or any(f.skip or f.failed for f in self.features)


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
        self.registry_root = expand(args.registry)
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
        base = Base(self, name)
        if os.path.lexists(base.cs_path):
            if not os.path.islink(base.cs_path):
                base.skip = ("cs created this session in its own folder; this script moves projects cs "
                             "adopted (a link in %s)" % tilde(self.cs_root))
                return base
            base.target = os.readlink(base.cs_path)
            base.source = os.path.realpath(base.cs_path)
            if not os.path.isdir(base.source):
                base.skip = "its directory %s no longer exists" % tilde(base.target)
                return base
        elif os.path.islink(base.ags_path):
            base.source = os.path.realpath(base.ags_path)
            base.target = os.readlink(base.ags_path)
            origin = (read_text(os.path.join(base.source, MARKER)) or "").strip()
            if origin != base.cs_path:
                raise SystemExit("No cs session named %s in %s." % (name, tilde(self.cs_root)))
            base.state = "moved"
        else:
            raise SystemExit("No cs session named %s in %s." % (name, tilde(self.cs_root)))
        if not os.path.isabs(base.target):
            base.target = base.source
        if not os.path.isdir(base.meta):
            base.skip = "%s has no .cs folder" % tilde(base.source)
            return base
        local = os.path.join(base.meta, "local")
        if os.path.lexists(os.path.join(local, "pre-open")) or any(
                os.path.islink(os.path.join(base.meta, sub)) for sub in VAULT_LINKS):
            base.skip = "encrypted: its vault opens only with its password, so this script does not move it"
            return base
        if base.state is None:
            if not os.path.lexists(base.ags_path):
                base.state = "free"
            elif os.path.islink(base.ags_path) and os.path.realpath(base.ags_path) == base.source:
                base.state = "ours"
            else:
                base.skip = "ags already has a different %s; remove that one, then rerun" % name
                return base
        self.plan_features(base)
        open_now = [base.name] if session_is_open(base.meta) else []
        open_now += [f.name for f in base.features
                     if f.state == "free" and session_is_open(os.path.join(f.source, ".cs"))]
        held = self.processes_holding(base)
        open_now = [name for name in open_now if not any(h.startswith(name + " (") for h in held)] + held
        if open_now:
            base.blocker = "open right now: %s; close %s, then rerun" % (
                ", ".join(open_now), "it" if len(open_now) == 1 else "them")
        return base

    def processes_holding(self, base):
        """Live processes that keep the session: an engine or session manager in the project, anything in a feature that moves.

        A lock is not enough: cs execs claude in its place, and the lock goes with it.
        """
        try:
            listing = subprocess.run(["lsof", "-a", "-d", "cwd", "-F", "pn"], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True).stdout
            table = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True).stdout
        except OSError as error:
            return ["(could not list processes: %s)" % error.strerror]
        commands = {}
        for line in table.splitlines():
            pid, _, command = line.strip().partition(" ")
            commands[pid] = command.strip()
        moving = [(f.name, f.source) for f in base.features if f.state == "free"]
        inside = lambda cwd, root: cwd == root or cwd.startswith(root + os.sep)
        is_engine = lambda command: bool({os.path.basename(w) for w in command.split()[:2]} & ENGINES)
        by_session, pid, own = {}, None, str(os.getpid())
        for line in listing.splitlines():
            if line.startswith("p"):
                pid = line[1:]
                continue
            command = commands.get(pid, "")
            # A process ps no longer lists has ended since lsof saw it.
            if not line.startswith("n") or pid is None or pid == own or not command:
                continue
            cwd = line[1:]
            where = next((name for name, source in moving if inside(cwd, source)), None)
            # A shell or an editor in the project is no matter: the project stays.
            if where is None and inside(cwd, base.source) and is_engine(command):
                where = base.name
            if where:
                by_session.setdefault(where, []).append((pid, command))
        held = []
        for name in sorted(by_session):
            found = sorted(by_session[name], key=lambda p: not is_engine(p[1]))
            pid, command = found[0]
            more = ", and %d more" % (len(found) - 1) if len(found) > 1 else ""
            held.append("%s (pid %s: %s%s)" % (name, pid, command[:50], more))
        return held

    def plan_features(self, base):
        registered = self.git(base.source, "worktree", "list", "--porcelain").stdout
        registered = {line[len("worktree "):] for line in registered.splitlines() if line.startswith("worktree ")}
        tasks = {}
        prefix = base.name + "@"
        for entry in sorted(os.listdir(self.cs_root)) if os.path.isdir(self.cs_root) else []:
            if entry.startswith(prefix) and len(entry) > len(prefix):
                tasks[entry[len(prefix):]] = os.path.join(self.cs_root, entry)
        for entry in sorted(os.listdir(self.ags_root)):
            if entry.startswith(prefix) and len(entry) > len(prefix):
                task = entry[len(prefix):]
                origin = (read_text(os.path.join(self.ags_root, entry, MARKER)) or "").strip()
                if task not in tasks and origin:
                    tasks[task] = None
        for task in sorted(tasks):
            feature = Feature(base, task, tasks[task])
            base.features.append(feature)
            if feature.cs_path is None:
                feature.state = "moved"
                continue
            if os.path.islink(feature.cs_path):
                if os.path.realpath(feature.cs_path) == os.path.realpath(feature.ags_path):
                    feature.state = "linked-back"
                else:
                    feature.skip = "a link, not a worktree folder; ags-to-cs.py did not make it"
                continue
            if not os.path.isdir(os.path.join(feature.source, ".cs")):
                feature.skip = "not a cs session (no .cs folder)"
                continue
            top = self.git(feature.source, "rev-parse", "--show-toplevel").stdout.strip()
            if (top or feature.source) not in registered:
                feature.skip = ("not a registered worktree of %s's repository (pruned or made by hand?)"
                                % base.name)
                continue
            if os.path.lexists(feature.ags_path):
                feature.skip = "ags already has a %s; remove that one, then rerun" % feature.name
                continue
            feature.state = "free"
            feature.registry = self.registry_entries(feature)

    def registry_entries(self, feature):
        """branch-out's records of this worktree, by the path it recorded."""
        found = []
        if not os.path.isdir(self.registry_root):
            return found
        wanted = {feature.cs_path, feature.source}
        for repo in sorted(os.listdir(self.registry_root)):
            directory = os.path.join(self.registry_root, repo)
            if not os.path.isdir(directory):
                continue
            for name in sorted(os.listdir(directory)):
                path = os.path.join(directory, name)
                if not name.endswith(".json"):
                    continue
                try:
                    data = json.loads(read_text(path) or "")
                except ValueError:
                    continue
                if isinstance(data, dict) and data.get("worktreePath") in wanted:
                    found.append(path)
        return found

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

    def move_feature(self, feature):
        moved = self.git(feature.base.source, "worktree", "move", feature.source, feature.ags_physical)
        if moved.returncode != 0:
            detail = (moved.stderr.strip().splitlines() or ["exit %d" % moved.returncode])[-1]
            raise OSError("git worktree move refused: %s" % detail)
        self.log("moved-worktree", session=feature.name, old=feature.source, new=feature.ags_physical)
        os.makedirs(os.path.dirname(os.path.join(feature.ags_physical, MARKER)), exist_ok=True)
        with open(os.path.join(feature.ags_physical, MARKER), "w") as f:
            f.write(feature.source + "\n")
        settings = os.path.join(feature.ags_physical, ".claude", "settings.local.json")
        raw = read_text(settings)
        if raw is not None:
            try:
                data = json.loads(raw)
            except ValueError:
                data = None
            memory = os.path.join(feature.ags_path, ".cs", "memory")
            if isinstance(data, dict) and "autoMemoryDirectory" in data and data["autoMemoryDirectory"] != memory:
                data["autoMemoryDirectory"] = memory
                write_atomic(settings, (json.dumps(data, indent=2) + "\n").encode(), prefix=TMP_PREFIX)
        for path in feature.registry:
            data = json.loads(read_text(path))
            old = {"worktreePath": data.get("worktreePath"), "sessionManager": data.get("sessionManager")}
            data["worktreePath"] = feature.ags_path
            if "sessionManager" in data:
                data["sessionManager"] = "ags"
            write_atomic(path, (json.dumps(data, indent=2) + "\n").encode(), prefix=TMP_PREFIX)
            self.log("rewrote-branch-out-registry", path=path, old=old)

    def reword(self, root):
        """True when root's CLAUDE.local.md needs (or got) the ags wording."""
        path = os.path.join(root, "CLAUDE.local.md")
        text = read_text(path)
        if text is None:
            return False
        reworded = reword_protocol(text, CS_TO_AGS_WORDING)
        if reworded == text:
            return False
        if self.apply:
            write_atomic(path, reworded.encode(), prefix=TMP_PREFIX)
            self.log("reworded", path=path)
        return True

    def conversations(self, old_key, new_key):
        """Merge one Claude folder and each conversation's side files; the tally and conversation count."""
        src = os.path.join(self.claude_dir, "projects", old_key)
        tally = merge_tree(src, os.path.join(self.ags_claude, "projects", new_key), self.apply, TMP_SUFFIX)
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
        owned.update(claude_project_key(f.old_physical) for f in base.features if f.old_physical)
        # Every other cs session, by its real and its link path: a key is lossy,
        # so wap@foo and a session called wap-foo share a folder name.
        others = set()
        for entry in os.listdir(self.cs_root) if os.path.isdir(self.cs_root) else []:
            if entry == base.name or entry.startswith(base.name + "@"):
                continue
            path = os.path.join(self.cs_root, entry)
            others.add(claude_project_key(os.path.realpath(path)))
            others.add(claude_project_key(physical_join(self.cs_root, entry)))
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
        """Lines of history.jsonl for the session's paths, rewritten for ags, that the profile lacks."""
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
            if project in paths:
                if paths[project] != project:
                    record["project"] = paths[project]
                    line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
            elif not (self.history and project.startswith(family)):
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
        """Copy each path's settings from ~/.claude.json to the profile's, under its ags path."""
        stable = json.loads(read_text(self.claude_json) or "{}")
        target = os.path.join(self.ags_claude, ".claude.json")
        raw = read_text(target)
        profile = json.loads(raw) if raw else {}
        projects = profile.setdefault("projects", {})
        changed = []
        for old, new in sorted(paths.items()):
            entry = (stable.get("projects") or {}).get(old)
            if not isinstance(entry, dict):
                continue
            mine = projects.setdefault(new, {})
            added = [k for k in sorted(entry) if not VOLATILE.match(k) and k not in mine]
            for key in added:
                mine[key] = entry[key]
            if added:
                changed.append(new)
        if changed and self.apply:
            write_atomic(target, (json.dumps(profile, indent=2, ensure_ascii=False) + "\n").encode(),
                         prefix=TMP_PREFIX)
            self.log("merged-claude-project-settings", paths=changed)
        return changed

    def codex_trust(self, paths):
        """Append the profile's Codex config a project table for each path stable Codex trusts."""
        stable = read_text(os.path.join(self.codex_home, "config.toml")) or ""
        target = os.path.join(self.profile, ".codex", "config.toml")
        mine = read_text(target)
        if mine is None:
            return []
        added = []
        blocks = []
        for old, new in sorted(paths.items()):
            header = '[projects."%s"]' % old
            if header not in stable.splitlines() or ('[projects."%s"]' % new) in mine.splitlines():
                continue
            lines = stable.splitlines()
            start = lines.index(header) + 1
            body = []
            for line in lines[start:]:
                if line.startswith("["):
                    break
                body.append(line)
            while body and not body[-1].strip():
                body.pop()
            blocks.append('[projects."%s"]\n%s\n' % (new, "\n".join(body)))
            added.append(new)
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
                base.failed = True
                self.problem("stopped: %s" % error)
        print()
        if not self.apply:
            print("Dry run: nothing changed. Run again with --apply to move.")
        elif self.failed:
            print("Moved what could be moved; the items marked ! above were not.")
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

    def handle(self, base):
        if base.skip:
            print("%s: not moved" % base.name)
            self.problem(base.skip)
            return
        print(base.name)
        if base.blocker:
            self.problem(base.blocker)
            if self.apply:
                return
        will = "" if self.apply else "would "

        # 1. The session: ags gets cs's link to the project.
        if base.state == "free":
            self.say("%slink %s -> %s" % (will, tilde(base.ags_path), tilde(base.target)))
            if self.apply:
                os.symlink(base.target, base.ags_path)
                self.log("linked", session=base.name, path=base.ags_path, target=base.target)
        else:
            self.say("already in ags at %s" % tilde(base.ags_path))
        if self.apply and base.state != "moved":
            # How a rerun knows the project came from cs, once cs's link is gone.
            os.makedirs(os.path.join(base.meta, "local"), exist_ok=True)
            with open(os.path.join(base.source, MARKER), "w") as f:
                f.write(base.cs_path + "\n")
        if self.reword(base.source):
            self.say("%s the session protocol in CLAUDE.local.md from cs to ags"
                     % ("reworded" if self.apply else "would reword"))

        # 2. Feature worktrees.
        for feature in base.features:
            if feature.skip:
                self.problem("%s: not moved: %s" % (feature.name, feature.skip))
                continue
            if feature.state == "moved":
                self.say("%s: already in ags at %s" % (feature.name, tilde(feature.ags_path)))
            elif feature.state == "linked-back":
                self.say("%s: lives in ags already; %sremove cs's link to it" % (feature.name, will))
            else:
                branch = self.git(feature.source, "branch", "--show-current").stdout.strip()
                self.say("%s: %smove the worktree to %s (on %s)"
                         % (feature.name, will, tilde(feature.ags_path), branch or "a detached HEAD"))
                for path in feature.registry:
                    self.say("%s: %spoint branch-out's %s at it" % (feature.name, will, tilde(path)))
                if self.apply:
                    try:
                        self.move_feature(feature)
                    except OSError as error:
                        feature.failed = True
                        self.problem("%s: stopped: %s" % (feature.name, error))
                        continue
            root = feature.ags_physical if (self.apply or feature.state != "free") else feature.source
            if self.reword(root):
                self.say("%s: %s the session protocol from cs to ags"
                         % (feature.name, "reworded" if self.apply else "would reword"))

        # 3. Claude conversations, under the folder name of each path in ags.
        paths = {base.source: base.source}
        tally, count = self.conversations(claude_project_key(base.source), claude_project_key(base.source))
        self.report_tally("Claude history of %s" % base.name, tally, count)
        for feature in base.features:
            if feature.skip or feature.failed or not feature.old_physical:
                continue
            paths[feature.old_physical] = feature.ags_physical
            tally, count = self.conversations(claude_project_key(feature.old_physical),
                                              claude_project_key(feature.ags_physical))
            self.report_tally("Claude history of %s" % feature.name, tally, count)
        claude_id = state_value(base.meta, "claude_session_id")
        if claude_id and os.path.isfile(os.path.join(self.claude_dir, "projects", claude_project_key(base.source),
                                                     claude_id + ".jsonl")):
            self.say("ags %s resumes conversation %s" % (base.name, claude_id))
        for name in [base.name] + [f.name for f in base.features if not f.skip]:
            tally = merge_tree(os.path.join(self.claude_dir, "tasks", name),
                               os.path.join(self.ags_claude, "tasks", name), self.apply, TMP_SUFFIX)
            if tally.pending():
                self.say("task list of %s: %d file(s) %s" % (name, tally.pending(), "copied" if self.apply else "to copy"))
        if self.history:
            keys = self.history_keys(base)
            total, conversations = None, 0
            for key in keys:
                tally, count = self.conversations(key, key)
                conversations += count
                if total is None:
                    total = tally
                else:
                    total.add(tally)
            if keys:
                self.report_tally("history of %d retired feature and scratch folder(s), no session"
                                  % len(keys), total, conversations)
        lines = self.prompt_history(base, paths)
        if lines:
            self.say("prompt history: %d line(s) %s" % (lines, "appended" if self.apply else "to append"))

        # 4. Trust and per-project settings, which a running ags may rewrite under us.
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

        # 5. Secrets. A feature's go through its base, but one may hold its own.
        for session in [base.name] + [f.name for f in base.features if not f.skip]:
            missing, present, error = self.secrets(session)
            if error:
                self.problem("secrets of %s: %s" % (session, error))
            if present:
                self.say("secrets of %s ags already has, kept: %s" % (session, ", ".join(present)))
            if missing:
                self.say("secrets of %s %s: %s" % (session, "copied" if self.apply else "to copy",
                                                    ", ".join(missing)))
                if self.apply:
                    for name in self.copy_secrets(session, missing):
                        base.failed = True
                        self.problem("secret %s of %s was not copied" % (name, session))

        # 6. cs lets go, once all of it is in ags.
        links = [f for f in base.features if f.state == "linked-back"]
        if base.state == "moved" and not links:
            return
        if base.family_failed():
            self.problem("kept cs's link %s, since not all of %s came over; rerun once the items above are fixed"
                         % (tilde(base.cs_path), base.name))
            return
        for feature in links:
            self.say("%sremove cs's link %s" % (will, tilde(feature.cs_path)))
            if self.apply:
                os.unlink(feature.cs_path)
                self.log("removed-cs-link", path=feature.cs_path)
        if base.state != "moved":
            self.say("%sremove cs's link %s, so %s opens from ags only" % (will, tilde(base.cs_path), base.name))
            if self.apply:
                os.unlink(base.cs_path)
                self.log("removed-cs-link", path=base.cs_path, target=base.target)
        if self.apply:
            self.say("the way back: scripts/ags-to-cs.py --session %s" % base.name)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Move a session the stable cs adopted, with its feature worktrees, Claude history and "
                    "secrets, into the ags profile.",
        epilog="Prints what it would do unless --apply is given.")
    parser.add_argument("--session", action="append", required=True, metavar="NAME",
                        help="the cs session to move (repeatable); its features come with it")
    parser.add_argument("--apply", action="store_true", help="move; without it nothing is written")
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
    parser.add_argument("--registry", default="~/.agent-worktrees/registry",
                        help="branch-out's registry (default: %(default)s)")
    args = parser.parse_args(argv)
    for name in args.session:
        if "@" in name or "/" in name or name.startswith("."):
            parser.error("--session %s: name a base session; its feature worktrees come with it" % name)
    return Importer(args).run()


if __name__ == "__main__":
    sys.exit(main())
