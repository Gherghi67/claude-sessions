#!/usr/bin/env python3
# ABOUTME: Gives ags its own copy of a project the stable cs adopted, with its features, Claude history and secrets.
# ABOUTME: cs is only read; a rerun brings over what cs changed since and keeps what ags changed.
"""Copy a cs session into ags, and bring the copy up to date with cs later.

ags refuses to adopt a folder that already has .cs/, so a project the stable
cs adopted cannot simply be adopted again. This script gives ags a copy of
it instead, so `ags <name>` opens it on the conversations cs left off with,
and the two never share a folder:

- The project (a link in ~/.claude-sessions) is copied whole into the
  profile's sessions root: its repository, .cs/, node_modules, ignored and
  untracked files. On APFS the copy is a clone, which costs no space until
  either side writes. From then on it is ags's own repository.
- Each feature worktree (<name>@<task>) is copied beside it as a linked
  worktree of the copy's repository, on the same branch, with its index and
  uncommitted changes.
- Each session's Claude conversations are copied from ~/.claude/projects into
  the profile's, under the folder name of the copy's path, whole: subagents,
  workflows, tool results. Their file-history, session-env and task list come
  too, and the session's prompt history from history.jsonl.
- Conversations of the session's retired features and of its scratch folders
  belong to no session any more; they come too, as history (--no-history
  leaves them out).
- Trust and per-project settings in ~/.claude.json and ~/.codex/config.toml
  are copied into the profile's under the copy's paths, while no ags session
  is running.
- Secrets are copied from the stable cs store into the profile's encrypted
  store, through cs-secrets and ags-secrets, values on stdin only.

A rerun brings over what cs changed since the last one, wherever ags left
the same thing alone: branches cs moved (fetched into the copy, also as
refs/remotes/cs/*), a worktree's HEAD and index, files, keys of
.cs/local/state, conversations, and features cs started. What ags changed is
kept; something changed on both sides keeps ags's and is reported, once. A
secret whose value differs is reported, never overwritten.

Nothing outside the profile is written: ~/.claude-sessions, the project and
its feature folders, ~/.claude, ~/.claude.json, ~/.codex and the keychain are
only read, and git runs there only to read. The record of the last sync and a
log of every change are in the profile's .cs-to-ags/.

Left behind, and said so: an encrypted session, a session cs created in its
own folder, a feature worktree git does not list, and anything whose name ags
already uses for something else.

    scripts/cs-to-ags.py --session wap            # print what would happen; change nothing
    scripts/cs-to-ags.py --session wap --apply    # copy; rerun to bring over what cs did since

Paths come from HOME and the options below, never from CS_* variables: inside
a session those name the session manager running it.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

from session_transfer import (
    STATE, Record, SecretsError, Syncer, admin_dir_for, branch_heads, claude_project_key, clone_tree, copy_admin_dir,
    copy_blocker, copy_index, copy_secret, git, mark_copied, mark_now, merge_tree, read_text, reap, relinker,
    scrubbed_env, secret_names, session_is_open,
    secret_differs, state_value, tilde, write_atomic,
)

TMP_SUFFIX = ".cs-to-ags.tmp"
TMP_PREFIX = ".cs-to-ags."
VAULT_LINKS = ("memory", "plans", "claude-config", "private")
SETTINGS = os.path.join(".claude", "settings.local.json")
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
        self.source = None      # cs's folder
        self.skip = None
        self.state = None       # free, ours (copied by an earlier run) or gone (ags removed its copy)
        self.failed = False
        self.admin = None       # a feature's administrative directory in cs's repository
        self.record = None      # a base's record of the last sync
        self.is_repo = False
        self.branches = None
        self.ags_path = os.path.join(importer.ags_root, name)
        self.ags_physical = os.path.join(importer.ags_root_real, name)

    @property
    def meta(self):
        return os.path.join(self.source, ".cs")


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
        self.ags_root_real = os.path.realpath(self.ags_root)
        self.ags_claude = os.path.join(self.profile, ".claude")
        self.ags_secrets = os.path.join(self.profile, ".local", "bin", "ags-secrets")
        self.ags_secrets_dir = os.path.join(self.profile, ".cs-secrets")
        self.record_root = os.path.join(self.profile, ".cs-to-ags")
        self.log_path = os.path.join(self.record_root, "log.jsonl")
        self.failed = False
        self.syncer = Syncer("cs", "ags", self.apply, self.say, self.problem, self.log, self.log_path, TMP_SUFFIX)

    # --- planning -------------------------------------------------------

    def plan(self, name):
        base = Session(self, name, os.path.join(self.cs_root, name))
        base.features = []
        base.open_now = []
        base.gone_in_cs = []
        if not os.path.lexists(base.cs_path):
            raise SystemExit("No cs session named %s in %s." % (name, tilde(self.cs_root)))
        if not os.path.islink(base.cs_path):
            base.skip = ("cs created this session in its own folder; this script copies projects cs "
                         "adopted (a link in %s)" % tilde(self.cs_root))
            return base
        base.source = os.path.realpath(base.cs_path)
        if not os.path.isdir(base.source):
            base.skip = "its directory %s no longer exists" % tilde(os.readlink(base.cs_path))
            return base
        if not os.path.isdir(base.meta):
            base.skip = "%s has no .cs folder" % tilde(base.source)
            return base
        if os.path.lexists(os.path.join(base.meta, "local", "pre-open")) or any(
                os.path.islink(os.path.join(base.meta, sub)) for sub in VAULT_LINKS):
            base.skip = "encrypted: its vault opens only with its password, so this script leaves it"
            return base
        git_dir = os.path.join(base.source, ".git")
        if os.path.lexists(git_dir) and (os.path.islink(git_dir) or not os.path.isdir(git_dir)):
            base.skip = "its repository lives elsewhere (.git is not a folder), so a copy would still share it"
            return base
        base.is_repo = os.path.isdir(git_dir)
        base.record = Record(os.path.join(self.record_root, name))
        if not os.path.lexists(base.ags_path):
            base.state = "free"
            # A record whose copy is gone is history: the next copy starts over.
            for old in list(base.record.data["sessions"]):
                base.record.forget(old)
            base.record.data = {"sessions": {}}
        elif (os.path.isdir(base.ags_path) and not os.path.islink(base.ags_path)
              and base.record.data.get("source") == base.source):
            base.state = "ours"
        else:
            base.skip = "ags already has a different %s; remove that one, then rerun" % name
            return base
        if base.is_repo:
            self.plan_features(base)
        base.open_now = self.open_sessions(base)
        return base

    def plan_features(self, base):
        listing = git(base.source, "worktree", "list", "--porcelain").stdout
        registered = {line[len("worktree "):] for line in listing.splitlines() if line.startswith("worktree ")}
        recorded = base.record.data["sessions"]
        admin_root = os.path.join(base.source, ".git", "worktrees") + os.sep
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
            top = git(feature.source, "rev-parse", "--show-toplevel").stdout.strip()
            if (top or feature.source) not in registered:
                feature.skip = ("not a registered worktree of %s's repository (pruned or made by hand?)"
                                % base.name)
                continue
            pointer = read_text(os.path.join(feature.source, ".git")) or ""
            admin = pointer[len("gitdir:"):].strip() if pointer.startswith("gitdir:") else ""
            admin = os.path.realpath(os.path.join(feature.source, admin)) if admin else ""
            if not admin.startswith(admin_root) or not os.path.isdir(admin):
                feature.skip = "not a linked worktree of %s's repository" % base.name
                continue
            feature.admin = admin
            if not os.path.lexists(feature.ags_path):
                feature.state = "gone" if entry in recorded else "free"
            elif (os.path.isdir(feature.ags_path) and not os.path.islink(feature.ags_path)
                  and (recorded.get(entry) or {}).get("source") == feature.source):
                feature.state = "ours"
            else:
                feature.skip = "ags already has a different %s; remove that one, then rerun" % entry
        listed = {f.name for f in base.features}
        base.gone_in_cs = sorted(n for n in recorded if n != base.name and n not in listed)

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

    def ags_running(self):
        """Lines of processes run from the profile's bin, which write the files we would merge into."""
        try:
            listing = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "command="], stdin=subprocess.DEVNULL,
                                     capture_output=True, text=True).stdout
        except OSError:
            return ["(could not list processes)"]
        needle = os.path.join(os.path.realpath(self.profile), ".local", "bin") + os.sep
        return [line.strip() for line in listing.splitlines() if needle in line]

    # --- copying ---------------------------------------------------------

    def log(self, action, **fields):
        if not self.apply:
            return
        os.makedirs(self.record_root, exist_ok=True)
        fields.update(action=action, at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        with open(self.log_path, "a") as f:
            f.write(json.dumps(fields, sort_keys=True) + "\n")

    def rekey_settings(self, data, session):
        """settings.local.json names the session's memory folder by its path, which is the copy's now."""
        try:
            settings = json.loads(data)
        except ValueError:
            return None
        memory = os.path.join(session.ags_path, ".cs", "memory")
        if not isinstance(settings, dict) or settings.get("autoMemoryDirectory") in (None, memory):
            return None
        settings["autoMemoryDirectory"] = memory
        return (json.dumps(settings, indent=2) + "\n").encode()

    def relink(self, base):
        """Absolute links into cs's folders of the family, pointed at ags's copies of them."""
        roots = {}
        for session in [base] + [f for f in base.features if f.source and not f.skip]:
            paths = [session.cs_path, session.source, os.path.join(os.path.realpath(self.cs_root), session.name)]
            if os.path.islink(session.cs_path) and os.path.isabs(os.readlink(session.cs_path)):
                paths.append(os.readlink(session.cs_path))
            for path in paths:
                roots[path] = session.ags_path
        return relinker(roots)

    def sync(self, base, session):
        self.syncer.session(session.name, session.source, session.ags_physical, base.source, base.ags_physical,
                            base.record, rewrites={SETTINGS: lambda data: self.rekey_settings(data, session)},
                            relink=self.relink(base), is_repo=base.is_repo)

    def adjust(self, root, session):
        path = os.path.join(root, SETTINGS)
        raw = read_text(path)
        changed = raw is not None and self.rekey_settings(raw, session)
        if changed:
            write_atomic(path, changed, prefix=TMP_PREFIX)

    def copy_base(self, base):
        os.makedirs(self.ags_root, exist_ok=True)
        reap(self.ags_root, ".%s%s" % (base.name, TMP_PREFIX))
        tmp = tempfile.mkdtemp(dir=self.ags_root, prefix=".%s%s" % (base.name, TMP_PREFIX))
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(base.source, tmp, self.relink(base))
            # cs's linked worktrees are not the copy's; each feature copied
            # after it gets its own entry back.
            worktrees = os.path.join(tmp, ".git", "worktrees")
            if os.path.isdir(worktrees) and not os.path.islink(worktrees):
                shutil.rmtree(worktrees)
            state = read_text(os.path.join(tmp, STATE))
            self.adjust(tmp, base)
            os.rename(tmp, base.ags_path)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        base.record.data["source"] = base.source
        base.record.data["heads"] = branch_heads(base.ags_physical) if base.is_repo else {}
        mark_copied(base.record, base.name, base.source, since, state, base.ags_physical, base.is_repo, paths)
        base.record.save()
        self.log("copied", session=base.name, source=base.source, path=base.ags_path)

    def copy_feature(self, base, feature):
        """Copies a feature worktree as a linked worktree of the copy's repository.

        git links a worktree both ways: the worktree's .git file names an
        administrative directory in the repository (HEAD, index, per-worktree
        refs), whose gitdir file names the worktree back. The copy takes the
        original's administrative directory into ags's repository and points
        the two at each other.
        """
        worktrees = os.path.join(base.ags_physical, ".git", "worktrees")
        os.makedirs(worktrees, exist_ok=True)
        back_link = os.path.join(feature.ags_physical, ".git") + "\n"
        admin = admin_dir_for(worktrees, os.path.basename(feature.admin), back_link)
        reap(self.ags_root, ".%s%s" % (feature.name, TMP_PREFIX))
        tmp = tempfile.mkdtemp(dir=self.ags_root, prefix=".%s%s" % (feature.name, TMP_PREFIX))
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(feature.source, tmp, self.relink(base))
            state = read_text(os.path.join(tmp, STATE))
            self.adjust(tmp, feature)
            copy_admin_dir(feature.admin, admin)
            with open(os.path.join(admin, "gitdir"), "w") as f:
                f.write(back_link)
            with open(os.path.join(tmp, ".git"), "w") as f:
                f.write("gitdir: %s\n" % admin)
            # Staged changes may hold blobs ags's repository has not got yet.
            copy_index(feature.source, tmp)
            os.rename(tmp, feature.ags_path)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(admin, ignore_errors=True)
            raise
        mark_copied(base.record, feature.name, feature.source, since, state, feature.ags_physical, True, paths)
        # After each copy, so a run stopped midway leaves a record of every copy it made.
        base.record.save()
        self.log("copied-feature", session=feature.name, source=feature.source, path=feature.ags_path)

    # --- the rest of one session ------------------------------------------

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
        """Lines of history.jsonl for the session's paths, under the copy's paths, that the profile lacks."""
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
        """Copy each path's settings from ~/.claude.json into the profile's, under the copy's path."""
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
        """Append to the profile's Codex config each path's project table, under the copy's path."""
        stable = (read_text(os.path.join(self.codex_home, "config.toml")) or "").splitlines()
        target = os.path.join(self.profile, ".codex", "config.toml")
        mine = read_text(target)
        if mine is None:
            return []
        added, blocks = [], []
        for old, new in sorted(paths.items()):
            header = '[projects."%s"]' % old
            if header not in stable or ('[projects."%s"]' % new) in mine.splitlines():
                continue
            body = []
            for line in stable[stable.index(header) + 1:]:
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

    def secret_envs(self):
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        return scrubbed_env(), ags_env

    def secrets(self, session):
        """Names to copy, names ags already has, and any problem reading either."""
        cs_env, ags_env = self.secret_envs()
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

    def secret_differs(self, session, name):
        cs_env, ags_env = self.secret_envs()
        return secret_differs([self.cs_secrets, "--session", session, "get", name], cs_env,
                              [self.ags_secrets, "--session", session, "get", name], ags_env)

    def copy_secrets(self, session, names):
        cs_env, ags_env = self.secret_envs()
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
            finally:
                if self.apply and not base.skip and base.record is not None and os.path.isdir(base.ags_path):
                    base.record.save()
        print()
        if not self.apply:
            print("Dry run: nothing changed. Run again with --apply to copy.")
        elif self.failed:
            print("Copied what could be; the items marked ! above were not, or were kept as ags has them.")
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
            print("%s: not copied" % base.name)
            self.problem(base.skip)
            return
        print(base.name)
        if base.open_now:
            self.say("note: open in cs right now: %s. What it writes from here on comes over on a rerun"
                     % ", ".join(base.open_now))
        will = "" if self.apply else "would "

        # 1. The project and its repository.
        if base.state == "free":
            self.say("%scopy %s to %s, with a repository of its own" % (will, tilde(base.source), tilde(base.ags_path)))
            if self.apply:
                self.copy_base(base)
        else:
            self.say("in ags at %s since an earlier run; bringing over what cs changed since" % tilde(base.ags_path))
            if base.is_repo:
                base.branches = self.syncer.repo(base.name, base.source, base.ags_physical, base.record)
            self.sync(base, base)

        # 2. Feature worktrees.
        for feature in base.features:
            if feature.skip:
                self.problem("%s: not copied: %s" % (feature.name, feature.skip))
                continue
            if feature.state == "gone":
                self.say("%s: ags removed its copy after an earlier run; not copied again" % feature.name)
                continue
            if feature.state == "ours":
                self.sync(base, feature)
                continue
            branch = git(feature.source, "branch", "--show-current").stdout.strip()
            if base.state == "ours":
                feature.skip = copy_blocker(feature.source, base.ags_physical,
                                            due=base.branches.created + base.branches.moved)
                if feature.skip:
                    self.problem("%s: not copied: %s" % (feature.name, feature.skip))
                    continue
            self.say("%s: %scopy it to %s, a worktree of ags's %s on %s"
                     % (feature.name, will, tilde(feature.ags_path), base.name, branch or "a detached HEAD"))
            if self.apply:
                try:
                    self.copy_feature(base, feature)
                except OSError as error:
                    feature.failed = True
                    self.problem("%s: stopped: %s" % (feature.name, error))
        for name in base.gone_in_cs:
            self.say("%s: cs no longer has it; ags keeps its copy" % name)
        sessions = [base] + [f for f in base.features if not f.skip and not f.failed and f.state != "gone"]

        # 3. Claude conversations, under the folder name of each copy's path.
        paths = {s.source: s.ags_physical for s in sessions}
        for session in sessions:
            tally, count = self.conversations(claude_project_key(session.source),
                                              claude_project_key(session.ags_physical))
            self.report_tally("Claude history of %s" % session.name, tally, count)
        copied = self.apply or base.state == "ours"
        claude_id = state_value(os.path.join(base.ags_path if copied else base.source, ".cs"), "claude_session_id")
        transcripts = (os.path.join(self.ags_claude, "projects", claude_project_key(base.ags_physical)),
                       os.path.join(self.claude_dir, "projects", claude_project_key(base.source)))
        if claude_id and any(os.path.isfile(os.path.join(t, claude_id + ".jsonl")) for t in transcripts):
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
        for session in sessions:
            missing, present, error = self.secrets(session.name)
            if error:
                self.problem("secrets of %s: %s" % (session.name, error))
            differs = [n for n in present if self.secret_differs(session.name, n)]
            if present and len(differs) < len(present):
                self.say("secrets of %s ags already has: %s" % (session.name, ", ".join(
                    n for n in present if n not in differs)))
            for name in differs:
                self.problem("secret %s of %s differs between cs and ags; ags's is kept" % (name, session.name))
            if missing:
                self.say("secrets of %s %s: %s" % (session.name, "copied" if self.apply else "to copy",
                                                    ", ".join(missing)))
                if self.apply:
                    for name in self.copy_secrets(session.name, missing):
                        self.problem("secret %s of %s was not copied" % (name, session.name))
        if self.apply:
            self.say("cs keeps %s as it was. Rerun to bring over what cs does from here on; to go back to cs, "
                     "run scripts/ags-to-cs.py --session %s" % (base.name, base.name))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Give ags its own copy of a session the stable cs adopted, with its feature worktrees, "
                    "Claude history and secrets; a rerun brings over what cs changed since.",
        epilog="Prints what it would do unless --apply is given. Nothing outside the ags profile is written.")
    parser.add_argument("--session", action="append", required=True, metavar="NAME",
                        help="the cs session to copy (repeatable); its features come with it")
    parser.add_argument("--apply", action="store_true", help="copy; without it nothing is written")
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
