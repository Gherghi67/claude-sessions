#!/usr/bin/env python3
# ABOUTME: Copies the ags profile's sessions, Claude conversations and secrets back into the stable cs.
# ABOUTME: The way back from ags: the profile is only read, and a rerun copies only what is new.
"""Copy what ags holds back into the stable cs.

ags runs from a private profile with its own sessions root, Claude config dir
and secrets store, so the stable cs sees none of its work. This script makes
every ags session open with `cs <name>`, resuming the same Claude
conversation:

- A session ags adopted (a link in the profile's sessions/) gets the same link
  in cs's sessions root. Its .cs/ lives in the project, so cs and ags share it.
- A session ags created (a directory in sessions/) is copied whole: git
  history, notes and local state.
- A feature worktree (<base>@<task>) follows its base. One of a created base
  becomes a linked worktree of the base's cs copy: the same branch, index,
  uncommitted changes and per-worktree refs. One of an adopted base is linked
  like its base, since git checks a branch out in one worktree only and the
  project's repository is the one cs and ags share.
- Each session's Claude conversations are copied from the profile's
  .claude/projects into ~/.claude/projects, under the folder name Claude Code
  gives the session's path in cs, with their file-history snapshots.
- Each session's secrets go from the profile's encrypted store into the store
  cs reads, through cs-secrets, values on stdin only.
- The session protocol in CLAUDE.local.md is reworded from ags to cs, except
  in a directory inside the profile.

The profile is only read, so ags keeps working. When cs already has a session
of that name, the ags one arrives as <name>-ags, or under the name --rename
gives it. A rerun skips what is already there and brings over what grew: a
conversation continued in ags replaces its cs copy only when that copy is an
unchanged start of it, and one continued on both sides is reported and left
alone.

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
    AGS_TO_CS_WORDING, SecretsError, claude_project_key, copy_secret, merge_tree, read_text,
    reword_protocol, scrubbed_env, secret_names, session_is_open, special_files, state_value,
    tilde, write_atomic,
)


class Plan:
    """What one ags session needs, worked out before anything is written."""

    def __init__(self, name, path):
        self.name = name
        self.path = path
        self.is_link = os.path.islink(path)
        self.source = os.path.realpath(path)
        self.meta = os.path.join(self.source, ".cs")
        self.skip = None
        self.cs_name = None
        self.cs_state = None
        self.renamed_because = None
        self.notes = []
        # link and copy for a base; worktree-link and worktree-copy for a
        # feature, decided by its base's kind.
        self.kind = "link" if self.is_link else "copy"
        self.base, _, self.task = name.partition("@") if "@" in name else (None, "", None)
        self.base_plan = None
        self.selected = True
        self.failed = False
        self.admin = None

    @property
    def shared(self):
        """True when cs gets a link to the directory ags uses, not a copy of it."""
        return self.kind in ("link", "worktree-link")


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
        self.profile_real = os.path.realpath(self.profile)
        self.ags_projects = os.path.join(self.profile, ".claude", "projects")
        self.ags_history = os.path.join(self.profile, ".claude", "file-history")
        self.ags_secrets = os.path.join(self.profile, ".local", "bin", "ags-secrets")
        self.ags_secrets_dir = os.path.join(self.profile, ".cs-secrets")
        self.cs_root_real = os.path.realpath(self.cs_root)
        self.failed = False

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
        if base.shared:
            plan.kind = "worktree-link"
        else:
            plan.kind = "worktree-copy"
            # The worktree's .git file names its administrative directory in
            # the base repository, which the base's copy must get as well.
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
        if plan.shared and self.inside_profile(plan.source):
            plan.notes.append("its directory %s lives inside the ags profile, which this script leaves "
                              "as it is (CLAUDE.local.md there keeps the ags wording); keep the profile "
                              "while cs uses it" % tilde(plan.source))
        if plan.kind == "worktree-link" and plan.base_plan.cs_name != plan.base:
            plan.notes.append("its state names its base %s, which cs calls %s; it shares that state "
                              "with ags, so this script leaves it" % (plan.base, plan.base_plan.cs_name))
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
        if plan.shared:
            # cs's own folder, which the ags link points at (scripts/cs-to-ags.py
            # leaves cs as it is), is the same session as much as a link to it.
            if os.path.realpath(entry) == plan.source:
                return "ours"
            return "taken"
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
        if plan.shared:
            return plan.source
        return os.path.join(self.cs_root_real, plan.cs_name)

    def inside_profile(self, path):
        return (path + os.sep).startswith(self.profile_real + os.sep)

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
        tmp = tempfile.mkdtemp(dir=self.cs_root, prefix=".%s.ags-to-cs." % plan.cs_name)
        os.rmdir(tmp)
        try:
            shutil.copytree(plan.source, tmp, symlinks=True, ignore=special_files)
            # The original repository's linked worktrees are not this copy's;
            # each feature worktree copied after it gets its own entry back.
            worktrees = os.path.join(tmp, ".git", "worktrees")
            if os.path.isdir(worktrees) and not os.path.islink(worktrees):
                shutil.rmtree(worktrees)
            self.adjust_copy(plan, tmp)
            os.rename(tmp, final)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise

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
        admin_id, n = plan.cs_name, 1
        while os.path.lexists(os.path.join(worktrees, admin_id)):
            if read_text(os.path.join(worktrees, admin_id, "gitdir")) == back_link:
                # Left by a copy that stopped before its rename.
                shutil.rmtree(os.path.join(worktrees, admin_id))
                break
            n += 1
            admin_id = "%s%d" % (plan.cs_name, n)
        admin = os.path.join(worktrees, admin_id)
        tmp = tempfile.mkdtemp(dir=self.cs_root, prefix=".%s.ags-to-cs." % plan.cs_name)
        os.rmdir(tmp)
        try:
            shutil.copytree(plan.source, tmp, symlinks=True, ignore=special_files)
            self.adjust_copy(plan, tmp)
            shutil.copytree(plan.admin, admin, symlinks=True, ignore=special_files)
            with open(os.path.join(admin, "gitdir"), "w") as f:
                f.write(back_link)
            with open(os.path.join(tmp, ".git"), "w") as f:
                f.write("gitdir: %s\n" % admin)
            os.rename(tmp, final)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(admin, ignore_errors=True)
            raise

    def adjust_copy(self, plan, root):
        state = os.path.join(root, ".cs", "local", "state")
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
        settings = os.path.join(root, ".claude", "settings.local.json")
        raw = read_text(settings)
        if raw is not None:
            try:
                data = json.loads(raw)
            except ValueError:
                data = None
            memory = os.path.join(self.cs_dir(plan), ".cs", "memory")
            if isinstance(data, dict) and "autoMemoryDirectory" in data and data["autoMemoryDirectory"] != memory:
                data["autoMemoryDirectory"] = memory
                write_atomic(settings, (json.dumps(data, indent=2) + "\n").encode(), prefix=".ags-to-cs.")
        self.reword_file(root, True)
        os.makedirs(os.path.dirname(os.path.join(root, MARKER)), exist_ok=True)
        with open(os.path.join(root, MARKER), "w") as f:
            f.write(plan.source + "\n")

    def git_head(self, path):
        result = subprocess.run(["git", "-C", path, "rev-parse", "-q", "--verify", "HEAD"],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else ""

    # --- running ---------------------------------------------------------

    def run(self):
        plans = self.sessions()
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

        # 1. The session itself, with its protocol reworded for cs. A copy is
        # reworded before it is renamed into place; a link's project is shared
        # with ags, which reads the cs wording just as well. A directory inside
        # the profile is left as it is.
        if plan.shared:
            reword_root = None if self.inside_profile(plan.source) else plan.source
            check_root = reword_root
        elif plan.cs_state == "ours":
            reword_root = check_root = final
        else:
            reword_root, check_root = None, plan.source
        reworded = check_root is not None and self.reword_file(check_root, self.apply and reword_root is not None)
        if plan.cs_state == "ours":
            self.say("already in cs at %s" % tilde(final))
            if not plan.shared:
                ags_head, cs_head = self.git_head(plan.source), self.git_head(final)
                if ags_head and ags_head != cs_head:
                    self.say("its work moved on in ags since the copy; bring it over with: "
                             "git -C %s pull %s" % (shlex.quote(tilde(final)), shlex.quote(tilde(plan.source))))
        elif plan.shared:
            target = os.readlink(plan.path) if plan.is_link else plan.source
            if not os.path.isabs(target):
                target = plan.source
            what = " (a worktree of %s's repository, shared with ags)" % plan.base if plan.base else ""
            self.say("%slink %s -> %s%s" % (will, tilde(final), tilde(target), what))
            if self.apply:
                os.makedirs(self.cs_root, exist_ok=True)
                os.symlink(target, final)
        elif plan.kind == "worktree-copy":
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

        if reworded:
            where = " (shared with ags)" if plan.shared else ""
            done = "reworded" if self.apply else "would reword"
            self.say("%s the session protocol in CLAUDE.local.md from ags to cs%s" % (done, where))

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
        if present:
            self.say("secrets cs already has, kept: %s" % ", ".join(present))
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
