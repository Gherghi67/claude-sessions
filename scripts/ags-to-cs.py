#!/usr/bin/env python3
# ABOUTME: Gives the stable cs its own copy of the ags profile's sessions, Claude conversations and secrets.
# ABOUTME: The way back from ags: the profile is only read; a rerun brings over what ags changed since.
"""Copy what ags holds back into the stable cs, and bring the copies up to date later.

ags runs from a private profile with its own sessions root, Claude config dir
and secrets store, so the stable cs sees none of its work. This script gives
cs a copy of every ags session, which opens with `cs <name>` on the same
Claude conversation. The two never share a folder:

- A session is copied whole into cs's sessions root, wherever ags keeps it (a
  project ags adopted included): git history, notes, local state, ignored
  and untracked files. On APFS the copy is a clone, which costs no space until
  either side writes.
- A feature worktree (<base>@<task>) becomes a linked worktree of its base's
  cs copy: the same branch, index, uncommitted changes and per-worktree refs.
- Each session's Claude conversations are copied from the profile's
  .claude/projects into ~/.claude/projects, under the folder name Claude Code
  gives the copy's path, with their file-history snapshots.
- Each session's secrets go from the profile's encrypted store into the store
  cs reads, through cs-secrets, values on stdin only.
- The session protocol in CLAUDE.local.md is reworded from ags to cs.

The profile is only read, and git runs there only to read, so ags keeps
working. When cs already has a session of that name, the ags one arrives as
<name>-ags, or under the name --rename gives it. A rerun brings over what ags
changed since, wherever cs left the same thing alone: branches (fetched into
the copy, also as refs/remotes/ags/*), a worktree's HEAD and index, files and
conversations. What cs changed in its copy is kept; something changed on both
sides keeps cs's and is reported, once. The record of the last sync lives in
cs's sessions root, under .ags-to-cs/.

Left behind, and said so: a session open in ags (close it, then rerun), an
encrypted session (its vault opens only with its password and links into the
profile), a feature worktree whose base is not copied, and Codex threads (cs
has no Codex engine; they stay in the profile).

    scripts/ags-to-cs.py              # print what would be copied; change nothing
    scripts/ags-to-cs.py --apply      # copy

Paths come from HOME and the options below, never from CS_* variables: inside
an ags session those name the profile itself.
"""

import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
VAULT_LINKS = ("memory", "plans", "claude-config", "private")
MARKER = os.path.join(".cs", "local", "ags-origin")

from session_transfer import (
    AGS_TO_CS_WORDING, STATE, Record, SecretsError, Syncer, admin_dir_for, branch_heads, claude_project_key,
    clone_tree, copy_admin_dir, copy_blocker, copy_index, copy_secret, mark_copied, mark_now, merge_tree, read_text,
    reap, relinker, reword_protocol, scrubbed_env, secret_names,
    secret_differs, session_is_open, state_value, tilde, write_atomic,
)

TMP_SUFFIX = ".ags-to-cs.tmp"
SETTINGS = os.path.join(".claude", "settings.local.json")
# A copy keeps cs's names for itself and its base, whatever ags calls them.
PINNED = ("session_name", "cs_base")


class Plan:
    """What one ags session needs, worked out before anything is written."""

    def __init__(self, name, path):
        self.name = name
        self.path = path
        self.source = os.path.realpath(path)
        self.meta = os.path.join(self.source, ".cs")
        self.skip = None
        self.cs_name = None
        self.cs_state = None
        self.renamed_because = None
        self.notes = []
        self.kind = "copy"      # worktree-copy for a feature
        self.base, _, self.task = name.partition("@") if "@" in name else (None, "", None)
        self.base_plan = None
        self.selected = True
        self.failed = False
        self.admin = None
        self.is_repo = os.path.isdir(os.path.join(self.source, ".git"))
        self.gone = False       # cs removed the copy an earlier run made
        self.branches = None    # a base's branch sync this run


class Copier:
    def __init__(self, args):
        self.apply = args.apply
        self.profile = os.path.abspath(os.path.expanduser(args.profile))
        self.cs_root = os.path.abspath(os.path.expanduser(args.cs_root))
        self.claude_dir = os.path.abspath(os.path.expanduser(args.claude_dir))
        self.cs_secrets = os.path.abspath(os.path.expanduser(args.cs_secrets))
        self.only = args.session
        self.renames = {}
        for item in args.rename:
            old, sep, new = item.partition("=")
            if not sep or not old or not new:
                raise SystemExit("--rename takes OLD=NEW, not %r" % item)
            if not NAME_RE.match(new) or new.startswith("-") or new in (".", ".."):
                raise SystemExit("--rename %s: cs names take letters, digits, '.', '_' and '-'" % item)
            self.renames[old] = new
        self.sessions_root = os.path.join(self.profile, "sessions")
        if not os.path.isdir(self.sessions_root):
            legacy = os.path.join(self.profile, ".claude-sessions")
            if os.path.isdir(legacy):
                self.sessions_root = legacy
            else:
                raise SystemExit("No ags sessions at %s; pass --profile." % self.sessions_root)
        self.ags_projects = os.path.join(self.profile, ".claude", "projects")
        self.ags_history = os.path.join(self.profile, ".claude", "file-history")
        self.ags_secrets = os.path.join(self.profile, ".local", "bin", "ags-secrets")
        self.ags_secrets_dir = os.path.join(self.profile, ".cs-secrets")
        self.cs_root_real = os.path.realpath(self.cs_root)
        self.record_root = os.path.join(self.cs_root, ".ags-to-cs")
        self.log_path = os.path.join(self.record_root, "log.jsonl")
        self.records = {}
        self.failed = False
        self.syncer = Syncer("ags", "cs", self.apply, self.say, self.problem, self.log, self.log_path, TMP_SUFFIX)

    # --- planning -------------------------------------------------------

    def sessions(self):
        names = sorted(n for n in os.listdir(self.sessions_root) if not n.startswith("."))
        plans = []
        for name in names:
            path = os.path.join(self.sessions_root, name)
            if os.path.islink(path) and not os.path.exists(path):
                plan = Plan(name, path)
                plan.skip = "its directory %s no longer exists" % tilde(os.readlink(path))
                plans.append(plan)
                continue
            if not os.path.isdir(path) or not os.path.isdir(os.path.join(path, ".cs")):
                continue
            plans.append(Plan(name, path))
        known = {plan.name: plan for plan in plans}
        if self.only:
            unknown = [n for n in self.only if n not in known]
            if unknown:
                raise SystemExit("No ags session named %s in %s." % (", ".join(unknown), tilde(self.sessions_root)))
            for plan in plans:
                plan.selected = plan.name in self.only
        for old in self.renames:
            if old not in known or not known[old].selected:
                raise SystemExit("--rename %s: no ags session of that name is being copied." % old)
            if known[old].base:
                raise SystemExit("--rename %s: a feature worktree takes its base's cs name; rename %s instead."
                                 % (old, known[old].base))
        for plan in plans:
            if plan.base:
                plan.base_plan = known.get(plan.base)
        # Bases first: a feature's cs name and repository come from its base.
        return sorted(plans, key=lambda plan: (plan.base is not None, plan.name))

    def classify_feature(self, plan):
        base = plan.base_plan
        if base is None:
            plan.skip = "its base %s is not an ags session" % plan.base
            return
        if base.skip or base.cs_name is None:
            why = "see above" if base.selected else base.skip
            plan.skip = "its base %s is not copied (%s)" % (plan.base, why)
            return
        if not base.selected and base.cs_state != "ours":
            plan.skip = "its base %s is not in cs yet; copy it too (--session %s)" % (plan.base, plan.base)
            return
        plan.kind = "worktree-copy"
        # The worktree's .git file names its administrative directory in the
        # base repository, which the base's copy must get as well.
        pointer = read_text(os.path.join(plan.source, ".git")) or ""
        admin = pointer[len("gitdir:"):].strip() if pointer.startswith("gitdir:") else ""
        admin = os.path.realpath(os.path.join(plan.source, admin)) if admin else ""
        repo = os.path.join(base.source, ".git", "worktrees") + os.sep
        if not admin.startswith(repo) or not os.path.isdir(admin):
            plan.skip = "not a linked worktree of %s's repository" % plan.base
            return
        plan.admin = admin
        plan.cs_name = "%s@%s" % (base.cs_name, plan.task)
        plan.cs_state = self.entry_state(plan, plan.cs_name)
        if plan.cs_state == "taken":
            plan.skip = "cs already has a different %s; finish or remove that one, then rerun" % plan.cs_name
            plan.cs_name = None

    def classify(self, plan):
        local = os.path.join(plan.meta, "local")
        if os.path.lexists(os.path.join(local, "pre-open")) or any(
                os.path.islink(os.path.join(plan.meta, sub)) for sub in VAULT_LINKS):
            plan.skip = ("encrypted: its vault opens only with its password and links into the "
                         "ags profile, so this script does not copy it")
            return
        if session_is_open(plan.meta):
            plan.skip = "open in ags right now; close it, then rerun"
            return
        if plan.base:
            self.classify_feature(plan)
        else:
            self.pick_name(plan)
        if plan.cs_name is None:
            return
        if plan.cs_state == "free" and plan.cs_name in self.record(plan).data["sessions"]:
            plan.gone = True
        git_dir = os.path.join(plan.source, ".git")
        if not plan.base and os.path.lexists(git_dir) and not plan.is_repo:
            plan.skip = "its repository lives elsewhere (.git is not a folder), so a copy would still share it"
            plan.cs_name = None
            return
        thread = (read_text(os.path.join(local, "codex-thread-id")) or "").strip()
        if thread:
            plan.notes.append("Codex thread %s stays in the profile (cs has no Codex engine): "
                              "CODEX_HOME=%s codex resume %s"
                              % (thread, shlex.quote(os.path.join(self.profile, ".codex")), thread))
        if state_value(plan.meta, "engine") == "codex":
            plan.notes.append("last opened with Codex; cs resumes its Claude conversation instead")

    def entry_state(self, plan, name):
        entry = os.path.join(self.cs_root, name)
        if not os.path.lexists(entry):
            return "free"
        if os.path.isdir(entry) and not os.path.islink(entry):
            origin = (read_text(os.path.join(entry, MARKER)) or "").strip()
            if origin == plan.source:
                return "ours"
        return "taken"

    def pick_name(self, plan):
        explicit = self.renames.get(plan.name)
        candidates = [explicit] if explicit else [plan.name, plan.name + "-ags"]
        for name in candidates:
            state = self.entry_state(plan, name)
            if state != "taken":
                plan.cs_name, plan.cs_state = name, state
                if name != plan.name and not explicit:
                    plan.renamed_because = "cs already has a different %s" % plan.name
                return
        plan.skip = ("cs already has %s; name the copy with --rename %s=<name>"
                     % (" and ".join(candidates), plan.name))

    # --- the parts of one session ----------------------------------------

    def cs_dir(self, plan):
        return os.path.join(self.cs_root, plan.cs_name)

    def cs_physical(self, plan):
        return os.path.join(self.cs_root_real, plan.cs_name)

    def record(self, plan):
        """The record of the last sync of plan's family, under its base's cs name."""
        base = plan.base_plan if plan.base else plan
        if base.cs_name not in self.records:
            self.records[base.cs_name] = Record(os.path.join(self.record_root, base.cs_name))
        return self.records[base.cs_name]

    def relink(self, plan):
        """Absolute links into ags's folders of the family, pointed at cs's copies of them."""
        base = plan.base_plan if plan.base else plan
        roots = {}
        for other in self.plans:
            if other.cs_name and (other is base or other.base_plan is base):
                roots[other.path] = roots[other.source] = self.cs_dir(other)
        return relinker(roots)

    def log(self, action, **fields):
        if not self.apply:
            return
        os.makedirs(self.record_root, exist_ok=True)
        fields.update(action=action, at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        with open(self.log_path, "a") as f:
            f.write(json.dumps(fields, sort_keys=True) + "\n")

    def conversations(self, plan):
        """The tally of the session's Claude files, and how many conversations they hold."""
        src = os.path.join(self.ags_projects, claude_project_key(plan.source))
        dst = os.path.join(self.claude_dir, "projects", claude_project_key(self.cs_physical(plan)))
        tally = merge_tree(src, dst, self.apply, ".ags-to-cs.tmp")
        count = 0
        if os.path.isdir(src):
            for name in sorted(os.listdir(src)):
                if name.endswith(".jsonl"):
                    count += 1
                    conversation = name[:-len(".jsonl")]
                    tally.add(merge_tree(os.path.join(self.ags_history, conversation),
                                         os.path.join(self.claude_dir, "file-history", conversation),
                                         self.apply, ".ags-to-cs.tmp"))
        return tally, count

    def secrets(self, plan):
        """Names to copy, names cs already has, and any problem reading either."""
        store = os.path.join(self.ags_secrets_dir, plan.name + ".enc")
        if not os.path.isfile(store):
            return [], [], None
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        cs_env = scrubbed_env()
        try:
            names = secret_names([self.ags_secrets], ags_env, plan.name)
            if not names:
                return [], [], None
            if not os.access(self.cs_secrets, os.X_OK):
                raise SecretsError("%s is missing; install the stable cs, or pass --cs-secrets"
                                   % tilde(self.cs_secrets))
            have = set(secret_names([self.cs_secrets], cs_env, plan.cs_name))
        except SecretsError as error:
            return [], [], str(error)
        return [n for n in names if n not in have], [n for n in names if n in have], None

    def copy_secrets(self, plan, names):
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        cs_env = scrubbed_env()
        return [name for name in names
                if not copy_secret([self.ags_secrets, "--session", plan.name, "get", name], ags_env,
                                   [self.cs_secrets, "--session", plan.cs_name, "set", name], cs_env)]

    def reword_file(self, root, apply):
        """True when root's CLAUDE.local.md needs (or got) the cs wording."""
        path = os.path.join(root, "CLAUDE.local.md")
        text = read_text(path)
        if text is None:
            return False
        reworded = reword_protocol(text, AGS_TO_CS_WORDING)
        if reworded == text:
            return False
        if apply:
            write_atomic(path, reworded.encode(), prefix=".ags-to-cs.")
        return True

    def copy_directory(self, plan):
        """Copies the session directory beside its final name, adjusts it, then renames it in."""
        os.makedirs(self.cs_root, exist_ok=True)
        final = self.cs_dir(plan)
        reap(self.cs_root, ".%s.ags-to-cs." % plan.cs_name)
        tmp = tempfile.mkdtemp(dir=self.cs_root, prefix=".%s.ags-to-cs." % plan.cs_name)
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(plan.source, tmp, self.relink(plan))
            # The original repository's linked worktrees are not this copy's;
            # each feature worktree copied after it gets its own entry back.
            worktrees = os.path.join(tmp, ".git", "worktrees")
            if os.path.isdir(worktrees) and not os.path.islink(worktrees):
                shutil.rmtree(worktrees)
            state = read_text(os.path.join(tmp, STATE))
            self.adjust_copy(plan, tmp)
            os.rename(tmp, final)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        record = self.record(plan)
        # A copy starts a new family: whatever an earlier copy of this name left is history.
        for old in list(record.data["sessions"]):
            record.forget(old)
        record.data = {"sessions": {}, "source": plan.source, "heads": {}}
        if plan.is_repo:
            record.data["heads"] = branch_heads(self.cs_physical(plan))
        mark_copied(record, plan.cs_name, plan.source, since, state, self.cs_physical(plan), plan.is_repo, paths)
        record.save()
        self.log("copied", session=plan.name, cs=plan.cs_name, source=plan.source)

    def copy_worktree(self, plan):
        """Copies a feature worktree as a linked worktree of its base's cs copy.

        git links a worktree both ways: the worktree's .git file names an
        administrative directory in the repository (HEAD, index, per-worktree
        refs), whose gitdir file names the worktree back. The copy takes the
        original's administrative directory into the base's copy and points
        the two at each other, so it keeps its branch, index and uncommitted
        changes while the original stays a worktree of the original.
        """
        base_git = os.path.join(self.cs_root_real, plan.base_plan.cs_name, ".git")
        if not os.path.isdir(base_git):
            raise OSError("the cs copy of %s has no repository at %s" % (plan.base, tilde(base_git)))
        final = self.cs_dir(plan)
        back_link = os.path.join(self.cs_physical(plan), ".git") + "\n"
        worktrees = os.path.join(base_git, "worktrees")
        os.makedirs(worktrees, exist_ok=True)
        admin = admin_dir_for(worktrees, plan.cs_name, back_link)
        reap(self.cs_root, ".%s.ags-to-cs." % plan.cs_name)
        tmp = tempfile.mkdtemp(dir=self.cs_root, prefix=".%s.ags-to-cs." % plan.cs_name)
        os.rmdir(tmp)
        since = mark_now()
        try:
            paths = clone_tree(plan.source, tmp, self.relink(plan))
            state = read_text(os.path.join(tmp, STATE))
            self.adjust_copy(plan, tmp)
            copy_admin_dir(plan.admin, admin)
            with open(os.path.join(admin, "gitdir"), "w") as f:
                f.write(back_link)
            with open(os.path.join(tmp, ".git"), "w") as f:
                f.write("gitdir: %s\n" % admin)
            # Staged changes may hold blobs the base's copy has not got yet.
            copy_index(plan.source, tmp)
            os.rename(tmp, final)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(admin, ignore_errors=True)
            raise
        record = self.record(plan)
        mark_copied(record, plan.cs_name, plan.source, since, state, self.cs_physical(plan), True, paths)
        record.save()
        self.log("copied-feature", session=plan.name, cs=plan.cs_name, source=plan.source)

    def rewrites(self, plan):
        """What a file from ags becomes in cs's copy: the protocol in cs's words, the memory folder at cs's path."""
        def reword(data):
            text = data.decode("utf-8", "surrogateescape")
            reworded = reword_protocol(text, AGS_TO_CS_WORDING)
            return reworded.encode("utf-8", "surrogateescape") if reworded != text else None
        return {"CLAUDE.local.md": reword, SETTINGS: lambda data: self.rekey_settings(data, plan)}

    def rekey_settings(self, data, plan):
        try:
            settings = json.loads(data)
        except ValueError:
            return None
        memory = os.path.join(self.cs_dir(plan), ".cs", "memory")
        if not isinstance(settings, dict) or settings.get("autoMemoryDirectory") in (None, memory):
            return None
        settings["autoMemoryDirectory"] = memory
        return (json.dumps(settings, indent=2) + "\n").encode()

    def sync_copy(self, plan):
        """Bring what ags changed since the last run into cs's copy, where cs left the same thing alone."""
        record = self.record(plan)
        mark = record.data["sessions"].get(plan.cs_name)
        if not mark:
            self.problem("%s was copied by an earlier version of this script, which kept no record of the copy, "
                         "so nothing is brought over; move it aside and rerun to copy it afresh" % tilde(self.cs_dir(plan)))
            return
        base = plan.base_plan if plan.base else plan
        base_copy = self.cs_physical(base)
        if not plan.base and plan.is_repo:
            plan.branches = self.syncer.repo(plan.cs_name, plan.source, base_copy, record)
        self.syncer.session(plan.cs_name, plan.source, self.cs_physical(plan), base.source, base_copy, record,
                            rewrites=self.rewrites(plan), relink=self.relink(plan), pinned=PINNED,
                            is_repo=base.is_repo)

    def adjust_copy(self, plan, root):
        state = os.path.join(root, STATE)
        text = read_text(state)
        if text is not None:
            changed = text
            if re.search(r"^session_name:", changed, re.M):
                changed = re.sub(r"^session_name:.*$", "session_name: " + plan.cs_name, changed, flags=re.M)
            # A feature's secrets and finish go through its base, by cs name.
            if plan.base_plan is not None and re.search(r"^cs_base:", changed, re.M):
                changed = re.sub(r"^cs_base:.*$", "cs_base: " + plan.base_plan.cs_name, changed, flags=re.M)
            if changed != text:
                write_atomic(state, changed.encode(), prefix=".ags-to-cs.")
        settings = os.path.join(root, SETTINGS)
        raw = read_text(settings)
        changed = raw is not None and self.rekey_settings(raw, plan)
        if changed:
            write_atomic(settings, changed, prefix=".ags-to-cs.")
        self.reword_file(root, True)
        os.makedirs(os.path.dirname(os.path.join(root, MARKER)), exist_ok=True)
        with open(os.path.join(root, MARKER), "w") as f:
            f.write(plan.source + "\n")

    # --- running ---------------------------------------------------------

    def run(self):
        plans = self.plans = self.sessions()
        print("ags profile: %s" % tilde(self.profile))
        print("cs sessions: %s   Claude: %s" % (tilde(self.cs_root), tilde(self.claude_dir)))
        if not plans:
            print("\nNo ags sessions to copy.")
            return 0
        # Every base is classified, chosen or not, so a chosen feature knows
        # its base's cs name and whether cs has it already.
        for plan in plans:
            if not plan.skip:
                self.classify(plan)
        for plan in plans:
            if not plan.selected:
                continue
            print()
            try:
                self.handle(plan)
            except OSError as error:
                # One session's failure (a full disk, a permission) leaves the
                # others to copy; a copy is renamed into place only when whole.
                plan.failed = True
                self.problem("stopped: %s" % error)
            finally:
                # After each session, so a run stopped midway leaves a record
                # of every copy it made.
                if self.apply:
                    for record in self.records.values():
                        record.save()
        print()
        if not self.apply:
            print("Dry run: nothing changed. Run again with --apply to copy.")
        elif self.failed:
            print("Copied what could be copied; the items marked ! above were not.")
        else:
            print("Done. Open a session with: cs <name>")
        return 1 if self.failed else 0

    def say(self, text, mark=" "):
        print("  %s %s" % (mark, text))

    def problem(self, text):
        self.failed = True
        self.say(text, "!")

    def handle(self, plan):
        if not plan.skip and plan.base_plan is not None and plan.base_plan.failed:
            plan.skip = "its base %s is not copied (see above)" % plan.base
        if plan.skip:
            print("%s: not copied" % plan.name)
            self.problem(plan.skip)
            return
        heading = plan.name if plan.cs_name == plan.name else "%s -> cs %s" % (plan.name, plan.cs_name)
        if plan.renamed_because:
            heading += " (%s)" % plan.renamed_because
        print(heading)
        will = "" if self.apply else "would "
        final = self.cs_dir(plan)
        if plan.gone:
            self.say("cs removed its copy %s after an earlier run; not copied again" % tilde(final))
            return

        # 1. The session itself, with its protocol reworded for cs.
        if plan.cs_state == "ours":
            self.say("in cs at %s since an earlier run; bringing over what ags changed since" % tilde(final))
            self.sync_copy(plan)
        elif plan.kind == "worktree-copy":
            base = plan.base_plan
            if base.cs_state == "ours":
                due = base.branches.created + base.branches.moved if base.branches else ()
                blocker = copy_blocker(plan.source, self.cs_physical(base), due)
                if blocker:
                    self.problem("not copied: %s" % blocker)
                    return
            branch = subprocess.run(["git", "-C", plan.source, "branch", "--show-current"],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True).stdout.strip()
            self.say("%scopy the feature worktree to %s, a worktree of cs %s on %s"
                     % (will, tilde(final), plan.base_plan.cs_name, branch or "a detached HEAD"))
            if self.apply:
                self.copy_worktree(plan)
        else:
            self.say("%scopy the session directory to %s" % (will, tilde(final)))
            if self.apply:
                self.copy_directory(plan)
        if plan.cs_state != "ours" and self.reword_file(plan.source, False):
            self.say("%s the session protocol in CLAUDE.local.md from ags to cs"
                     % ("reworded" if self.apply else "would reword"))

        # 2. Claude conversations.
        tally, count = self.conversations(plan)
        verb = "copied" if self.apply else "to copy"
        if tally.pending():
            parts = []
            if tally.new:
                parts.append("%d new" % tally.new)
            if tally.grown:
                parts.append("%d grown since the last copy" % tally.grown)
            self.say("Claude history of %d conversation(s), files %s: %s"
                     % (count, verb, ", ".join(parts)))
        elif not tally.diverged:
            self.say("Claude history of %d conversation(s): nothing new" % count)
        if tally.ahead:
            self.say("%d cs file(s) went on past the ags copy; kept" % tally.ahead)
        for path_ in tally.diverged:
            self.problem("continued in both ags and cs, left as it is: %s" % tilde(path_))
        claude_id = state_value(plan.meta, "claude_session_id")
        transcript = claude_project_key(plan.source) + os.sep + claude_id + ".jsonl"
        if claude_id and os.path.isfile(os.path.join(self.ags_projects, transcript)):
            self.say("cs %s resumes conversation %s" % (plan.cs_name, claude_id))

        # 3. Secrets.
        missing, present, error = self.secrets(plan)
        if error:
            self.problem("secrets: %s" % error)
        ags_env = scrubbed_env()
        ags_env.update(CS_SECRETS_BACKEND="encrypted", CS_SECRETS_DIR=self.ags_secrets_dir)
        differs = [n for n in present
                   if secret_differs([self.ags_secrets, "--session", plan.name, "get", n], ags_env,
                                     [self.cs_secrets, "--session", plan.cs_name, "get", n], scrubbed_env())]
        if len(differs) < len(present):
            self.say("secrets cs already has: %s" % ", ".join(n for n in present if n not in differs))
        for name in differs:
            self.problem("secret %s differs between ags and cs; cs's is kept" % name)
        if missing:
            self.say("secrets %s: %s" % (verb, ", ".join(missing)))
            if self.apply:
                for name in self.copy_secrets(plan, missing):
                    self.problem("secret %s was not copied" % name)

        for note in plan.notes:
            self.say("note: " + note)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Copy the ags profile's sessions, Claude conversations and secrets back into the stable cs.",
        epilog="Prints what it would do unless --apply is given. The profile is never changed.")
    parser.add_argument("--apply", action="store_true", help="copy; without it nothing is written")
    parser.add_argument("--session", action="append", default=[], metavar="NAME",
                        help="copy only this ags session (repeatable)")
    parser.add_argument("--rename", action="append", default=[], metavar="OLD=NEW",
                        help="the cs name for an ags session (repeatable)")
    parser.add_argument("--profile", default="~/.local/share/agent-sessions/home",
                        help="the ags profile (default: %(default)s)")
    parser.add_argument("--cs-root", default="~/.claude-sessions",
                        help="the stable cs sessions root (default: %(default)s)")
    parser.add_argument("--claude-dir", default="~/.claude",
                        help="the Claude config dir the stable cs runs Claude Code on (default: %(default)s)")
    parser.add_argument("--cs-secrets", default="~/.local/bin/cs-secrets",
                        help="the stable cs secrets command (default: %(default)s)")
    args = parser.parse_args(argv)
    return Copier(args).run()


if __name__ == "__main__":
    sys.exit(main())
