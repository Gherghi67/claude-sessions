#!/usr/bin/env python3
# ABOUTME: Merges an upstream claude-sessions release into this branch, in a worktree of its own.
# ABOUTME: Translates upstream into the fork's names and file layout first, so only real overlaps conflict.
"""Merge an upstream claude-sessions release into the agent-sessions branch.

The rebrand renamed commands and environment variables, moved Claude-only
functions into fragments of their own, and turned bin/cs-* into symlinks to
bin/ags-*. A plain `git merge` sees all of that as conflicts. Before merging,
this script rewrites both upstream versions of every file (the merge base and
the release) into the fork's dialect: the same renames, each function in the
fragment the fork keeps it in, each file at the fork's path. Each file is then
merged three ways with `git merge-file`.

That is safe by construction. A line the fork deliberately left alone (a `cs`
it kept on purpose) differs from the rewritten base, so it counts as a fork
edit: the fork's line wins, or it conflicts if upstream changed it too. It is
never renamed silently. The renames are only a preference: a file they leave
with more conflicts than a plain merge is merged plainly.

    scripts/sync-upstream.py status          # which releases are missing, what the next one conflicts in
    scripts/sync-upstream.py catch-up        # merge them one by one, landing each
    scripts/sync-upstream.py start [--to v2026.10.3]
    scripts/sync-upstream.py continue        # in the sync worktree, once resolved

Nothing is pushed. The merge commit lands on a sync/<tag> branch; bring it
into the branch you started from with `git merge --ff-only sync/<tag>`, or let
catch-up do that.
"""

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REMOTE = "origin"
# Written by build.sh. Never merged: rebuilt once the sources are merged.
GENERATED = {"bin/ags", "bin/cs", "hooks/cs-shared.sh", "skills/sweep/scripts/cs-shared.sh", "install.sh"}
# Where the fork's renames apply. Prose (README, docs, CHANGELOG) was
# rewritten by hand, so it merges plainly.
RENAME_DIRS = ("lib/", "hooks/", "skills/", "commands/", "mods/", "completions/",
               "tests/", "bin/", "scripts/")
RENAME_FILES = {"install.sh.in", "setup.sh", "build.sh"}
# Fragments build.sh joins into one program: a function can live in any of them.
UNIT_DIR = "lib/"
SESSION_VARS = ("SESSION_META_DIR", "SESSION_DIR", "SESSION_NAME")
COMPANIONS = r"(?:subagent-statusline|statusline|secrets|tui|codex-thread)"
LABELS = ("ours", "base", "upstream")
STATE_NAME = "ags-sync-upstream.json"


class SyncError(Exception):
    pass


def git(*args, cwd=None, binary=False):
    proc = subprocess.run(("git",) + args, cwd=cwd, capture_output=True)
    if proc.returncode != 0:
        raise SyncError("git %s failed: %s" % (" ".join(args), proc.stderr.decode(errors="replace").strip()))
    return proc.stdout if binary else proc.stdout.decode(errors="replace")


def git_ok(*args, cwd=None):
    return subprocess.run(("git",) + args, cwd=cwd, capture_output=True).returncode == 0


# ---- the fork's renames ---------------------------------------------------

def _session_var(text, var):
    full = "${CS_%s:-${CLAUDE_%s:-%%s}}" % (var, var)
    guard = r"(?<!\$\{CS_%s:-)" % var
    text = re.sub(guard + r"\$\{CLAUDE_%s:-([^{}]*)\}" % var, lambda m: full % m.group(1), text)
    text = re.sub(guard + r"\$\{CLAUDE_%s\}" % var, lambda m: full % "", text)
    return re.sub(r"\$CLAUDE_%s(?![A-Za-z0-9_])" % var, lambda m: full % "", text)


def rename(text):
    """Apply the rebrand's mechanical renames to upstream text. Idempotent."""
    for var in SESSION_VARS:
        text = _session_var(text, var)
    text = re.sub(r"(?<![\w.-])cs-(%s)(?![\w-])" % COMPANIONS, r"ags-\1", text)
    text = re.sub(r"(\$INSTALL_DIR/|bin/)cs(?![\w.-])", r"\1ags", text)
    text = re.sub(r"/cs\.bash\b", "/ags.bash", text)
    text = re.sub(r"/_cs(?![\w-])", "/_ags", text)
    text = re.sub(r"\$CS_((?:SECRETS_|STATUSLINE_|SUBAGENT_STATUSLINE_)?URL)\b", r"$AGS_\1", text)
    # The command itself: `cs -list`, "cs: name", (cs), ${COMMENT}cs${NC}. Not
    # .cs/, hooks/cs, cs-shared.sh, cs_helper, CS_KEY or docs, and not a cs:word
    # identifier: <!-- cs:wrap-cues --> and the other sentinels keep their names.
    text = re.sub(r"(?<![\w./$-])cs(?=$|[\s\"'`).,;]|:(?=\s|$)|\$\{)", "ags", text, flags=re.M)
    return re.sub(r"\b([Aa]) ags\b", r"\1n ags", text)  # "a cs session" reads "an ags session"


def renames_apply(path):
    return path in RENAME_FILES or path.startswith(RENAME_DIRS)


def rename_changed_lines(base, upstream):
    """Upstream text with the renames applied to the lines it changed or added."""
    base_lines, upstream_lines = base.split("\n"), upstream.split("\n")
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, base_lines, upstream_lines, autojunk=False).get_opcodes():
        lines = upstream_lines[j1:j2]
        out += lines if tag == "equal" else [rename(line) for line in lines]
    return "\n".join(out)


def renamed_like_the_fork(base, ours, upstream):
    """Rename upstream text only where the fork renamed: the base lines the
    fork changed, the upstream lines that replace them, and lines upstream
    adds. A line the fork kept stays as upstream writes it."""
    base_lines, upstream_lines = base.split("\n"), upstream.split("\n")
    kept = set()
    for tag, i1, i2, _, _ in difflib.SequenceMatcher(
            None, base_lines, ours.split("\n"), autojunk=False).get_opcodes():
        if tag == "equal":
            kept.update(range(i1, i2))
    new_base = [line if i in kept else rename(line) for i, line in enumerate(base_lines)]
    new_upstream = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            None, base_lines, upstream_lines, autojunk=False).get_opcodes():
        if tag == "equal":
            new_upstream += new_base[i1:i2]
        elif tag == "insert" or (tag == "replace" and not kept.issuperset(range(i1, i2))):
            new_upstream += [rename(line) for line in upstream_lines[j1:j2]]
        elif tag == "replace":
            new_upstream += upstream_lines[j1:j2]
    return "\n".join(new_base), "\n".join(new_upstream)


# ---- function units --------------------------------------------------------

UNIT_START = re.compile(r"^(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\)\s*\{")
ASSIGNMENT = re.compile(r"^(?:readonly\s+|export\s+)?([A-Z][A-Z0-9_]*)=\S")


def one_line_assignment(line):
    """An UPPERCASE assignment that starts and ends on this line: an array that
    closes here, no heredoc, no continuation, balanced quotes."""
    if "<<" in line or line.rstrip().endswith("\\"):
        return None
    if "=(" in line and not line.rstrip().endswith(")"):
        return None
    if line.count('"') % 2 or line.count("'") % 2:
        return None
    return ASSIGNMENT.match(line)


def units(lines):
    """Top-level functions and one-line UPPERCASE assignments, each with the
    comment block directly above it: [(name, first_line, last_line)]."""
    found, i = [], 0
    while i < len(lines):
        start = UNIT_START.match(lines[i])
        assign = None if start else one_line_assignment(lines[i])
        if not start and not assign:
            i += 1
            continue
        end = i
        if start and not re.search(r"\}\s*(#.*)?$", lines[i]):
            end = i + 1
            while end < len(lines) and not re.match(r"^\}\s*(#.*)?$", lines[end]):
                end += 1
            if end == len(lines):
                return found  # unterminated: leave the rest alone
        first, floor = i, (found[-1][2] + 1 if found else 0)
        while first > floor and lines[first - 1].startswith("#") and not lines[first - 1].startswith("#!"):
            first -= 1
        found.append(((start or assign).group(1), first, end))
        i = end + 1
    return found


def split_lines(text):
    return text.split("\n") if text else []


def unit_text(text, name):
    lines = split_lines(text)
    for unit, first, last in units(lines):
        if unit == name:
            return "\n".join(lines[first:last + 1])
    return None


def remove_units(text, names):
    lines = split_lines(text)
    drop = set()
    for name, first, last in units(lines):
        if name in names:
            drop.update(range(first, last + 1))
            if last + 1 < len(lines) and not lines[last + 1].strip():
                drop.add(last + 1)
    return "\n".join(line for n, line in enumerate(lines) if n not in drop)


def insert_units(text, moved, ours_order):
    """Insert moved units ({name: unit text}) into text, each after the unit
    that precedes it in the fork's copy of the file, in the fork's order."""
    lines = split_lines(text)
    for index, name in enumerate(ours_order):
        if name not in moved:
            continue
        present = {n: (first, last) for n, first, last in units(lines)}
        anchor = next((present[n] for n in reversed(ours_order[:index]) if n in present), None)
        block = moved[name].split("\n")
        if anchor:
            at = anchor[1] + 1
            lines[at:at] = [""] + block
        else:
            later = [present[n][0] for n in ours_order[index + 1:] if n in present]
            at = min(later) if later else len(lines)
            lines[at:at] = block + [""]
    return "\n".join(lines)


# ---- trees -----------------------------------------------------------------

class Tree:
    """The files of one commit, read on demand."""

    def __init__(self, repo, rev):
        self.repo, self.rev, self._cache, self.modes = repo, rev, {}, {}
        for entry in filter(None, git("ls-tree", "-r", "-z", rev, cwd=repo).split("\0")):
            meta, path = entry.split("\t", 1)
            self.modes[path] = meta.split()[0]

    def has(self, path):
        return path in self.modes

    def is_link(self, path):
        return self.modes.get(path) == "120000"

    def raw(self, path):
        if path not in self._cache:
            self._cache[path] = git("cat-file", "-p", "%s:%s" % (self.rev, path), cwd=self.repo,
                                    binary=True) if path in self.modes else None
        return self._cache[path]

    def text(self, path):
        data = self.raw(path)
        if data is None or b"\0" in data or self.is_link(path):
            return None
        return data.decode("utf-8", errors="surrogateescape")

    def content(self, path):
        """Text as str, a binary file as bytes, a symlink as ("link", target)."""
        if self.is_link(path):
            return ("link", self.raw(path))
        text = self.text(path)
        return text if text is not None else self.raw(path)


def path_map(repo, base, ours):
    """Upstream path -> the fork's path, for files the fork moved."""
    mapping = {}
    # 30%: commands/checkpoint.md became skills/checkpoint/SKILL.md with most
    # of its text rewritten. Only files the fork deleted can pair up, so a
    # low threshold cannot misdirect a file both sides still have.
    out = git("diff", "-M30%", "--name-status", "-z", "--diff-filter=R", base.rev, ours.rev, cwd=repo)
    fields = [f for f in out.split("\0") if f]
    for i in range(0, len(fields) - 2, 3):
        mapping[fields[i + 1]] = fields[i + 2]
    # bin/cs-statusline became a symlink to bin/ags-statusline, which git
    # records as a type change plus a new file rather than a rename.
    for path in base.modes:
        if path in GENERATED or path in mapping or base.is_link(path) or not ours.is_link(path):
            continue
        target = os.path.normpath(os.path.join(os.path.dirname(path), ours.raw(path).decode()))
        if ours.has(target) and not ours.is_link(target) and not base.has(target):
            mapping[path] = target
    return mapping


def unit_moves(base, upstream, ours, mapping):
    """{name: (upstream fragment, fork fragment)} for every function or
    assignment the fork keeps in another fragment than upstream does."""
    def index(tree):
        where = {}
        for path in tree.modes:
            if path.startswith(UNIT_DIR) and path.endswith(".sh"):
                for name, _, _ in units(split_lines(tree.text(path) or "")):
                    where.setdefault(name, []).append(path)
        return {name: paths[0] for name, paths in where.items() if len(paths) == 1}

    ours_at = index(ours)
    moves = {}
    for tree in (base, upstream):
        for name, source in index(tree).items():
            if name in ours_at and ours_at[name] != mapping.get(source, source):
                moves[name] = (source, ours_at[name])
    return moves


def translate(tree, moves, ours, mapping):
    """The tree rewritten into the fork's layout: {fork path: content}."""
    files = {mapping.get(path, path): tree.content(path) for path in tree.modes if path not in GENERATED}
    outgoing = {}
    for name, (source, target) in moves.items():
        source = mapping.get(source, source)
        if isinstance(files.get(source), str):
            text = unit_text(files[source], name)
            if text is not None:
                outgoing.setdefault(target, {})[name] = text
                files[source] = remove_units(files[source], {name})
    for target, moved in outgoing.items():
        if isinstance(files.get(target, ""), str):
            order = [n for n, _, _ in units(split_lines(ours.text(target) or ""))]
            files[target] = insert_units(files.get(target, ""), moved, order)
    return files


# ---- merging ---------------------------------------------------------------

def merge_file(ours_text, base_text, theirs_text, scratch):
    paths = []
    for label, text in zip(LABELS, (ours_text, base_text, theirs_text)):
        path = os.path.join(scratch, label)
        with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as handle:
            handle.write(text or "")
        paths.append(path)
    proc = subprocess.run(["git", "merge-file", "-p", "--zdiff3",
                           "-L", LABELS[0], "-L", LABELS[1], "-L", LABELS[2]] + paths,
                          capture_output=True)
    if proc.returncode < 0 or proc.returncode > 127:
        raise SyncError("git merge-file failed: %s" % proc.stderr.decode(errors="replace"))
    return proc.stdout.decode("utf-8", errors="surrogateescape"), proc.returncode


def merge_one(path, o, b, u, scratch):
    """Merge one fork path. Returns (result, conflicts, plain_conflicts, how)
    where result is str/bytes/("link", target) to write, or None to delete."""
    texts = all(isinstance(x, str) or x is None for x in (o, b, u))
    renamed = renames_apply(path) and texts
    # Only upstream changed it. In a file the fork never touched the fork made
    # no choices, so every line upstream changes or adds gets the renames (a
    # test there asserts the messages the fork renamed in lib/); one the fork
    # changed by the renames alone gets them again.
    if o == b and o is not None:
        if renamed and u is not None:
            result = rename_changed_lines(b, u)
            return result, 0, 0, (["renames"] if result != u else [])
        return u, 0, 0, []
    if renamed and b is not None and o == rename(b):
        return (None if u is None else rename(u)), 0, 0, ["renames"]
    if u is None:
        if isinstance(o, str):
            return "<<<<<<< deleted upstream, changed in the fork\n" + o, 1, 1, []
        return o, 1, 1, ["deleted upstream, changed in the fork"]
    if o is None:
        if b is None:  # new upstream: written the fork's way from the start
            return (rename(u) if renamed else u), 0, 0, (["renames"] if renamed and rename(u) != u else [])
        if isinstance(u, str):
            return "<<<<<<< deleted in the fork, changed upstream\n" + u, 1, 1, []
        return None, 1, 1, ["deleted in the fork, changed upstream"]
    if not texts:
        return o, 1, 1, ["changed on both sides; not text, the fork's version is kept"]
    merged, count = merge_file(o, b, u, scratch)
    plain = count
    how = []
    if renamed:
        renamed_text, renamed_count = merge_file(o, *renamed_like_the_fork(b or "", o, u), scratch=scratch)
        if renamed_count <= count:
            if renamed_text != merged:
                how.append("renames")
            merged, count = renamed_text, renamed_count
    return merged, count, plain, how


def plan_merge(repo, base_rev, upstream_rev, ours_rev, scratch):
    """Merge every file upstream changed: ({fork path: (result, executable)}, report)."""
    base, upstream, ours = Tree(repo, base_rev), Tree(repo, upstream_rev), Tree(repo, ours_rev)
    mapping = path_map(repo, base, ours)
    reverse = {fork: up for up, fork in mapping.items()}
    moves = unit_moves(base, upstream, ours, mapping)
    changed_moves = {name for name, (source, _) in moves.items()
                     if unit_text(base.text(source) or "", name) != unit_text(upstream.text(source) or "", name)}
    from_base = translate(base, moves, ours, mapping)
    from_upstream = translate(upstream, moves, ours, mapping)
    results, report = {}, []
    for path in sorted(set(from_base) | set(from_upstream)):
        b, u = from_base.get(path), from_upstream.get(path)
        if b == u:
            continue
        o = ours.content(path) if ours.has(path) else None
        result, count, plain, how = merge_one(path, o, b, u, scratch)
        if path in reverse:
            how.insert(0, "moved file, upstream %s" % reverse[path])
        moved_here = sorted(n for n in changed_moves if moves[n][1] == path)
        if moved_here:
            how.insert(0, "moved functions: " + ", ".join(moved_here))
        if result != o:
            source = reverse.get(path, path)
            mode = ours.modes.get(path) or upstream.modes.get(source) or "100644"
            results[path] = (result, mode == "100755")
        report.append({"path": path, "conflicts": count, "plain": plain, "how": how,
                       "marker": isinstance(result, str) and count > 0})
    return results, report


def plain_merge_conflicts(repo, ours_rev, upstream_rev):
    """How many files a plain `git merge` leaves in conflict, for comparison."""
    proc = subprocess.run(["git", "merge-tree", "--write-tree", "--name-only", "--no-messages",
                           ours_rev, upstream_rev], cwd=repo, capture_output=True)
    if proc.returncode not in (0, 1):
        return None
    # A file whose type differs on each side is listed twice, once as path~branch.
    return len({line.split("~")[0] for line in proc.stdout.decode().split("\n")[1:] if line.strip()})


def has_markers(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as handle:
            return any(line.startswith(("<<<<<<< ", ">>>>>>> ")) for line in handle)
    except (FileNotFoundError, IsADirectoryError):
        return False


def duplicate_functions(worktree):
    where = {}
    lib = os.path.join(worktree, UNIT_DIR)
    for name in sorted(os.listdir(lib)) if os.path.isdir(lib) else []:
        if name.endswith(".sh"):
            with open(os.path.join(lib, name), encoding="utf-8", errors="surrogateescape") as handle:
                for unit, _, _ in units(handle.read().split("\n")):
                    if not unit.isupper():
                        where.setdefault(unit, []).append(UNIT_DIR + name)
    return {name: paths for name, paths in where.items() if len(paths) > 1}


# ---- commands --------------------------------------------------------------

def git_path(worktree, name):
    path = git("rev-parse", "--git-path", name, cwd=worktree).strip()
    return os.path.join(worktree, path)


def write_result(worktree, path, result, executable):
    full = os.path.join(worktree, path)
    if result is None:
        git("rm", "--quiet", "--", path, cwd=worktree)
        return
    os.makedirs(os.path.dirname(full), exist_ok=True)
    if os.path.lexists(full):
        os.remove(full)
    if isinstance(result, tuple):
        os.symlink(result[1].decode(), full)
        return
    mode = "wb" if isinstance(result, bytes) else "w"
    kwargs = {} if isinstance(result, bytes) else {"encoding": "utf-8", "errors": "surrogateescape", "newline": ""}
    with open(full, mode, **kwargs) as handle:
        handle.write(result)
    os.chmod(full, 0o755 if executable else 0o644)


def finish(worktree, skip_tests, trailers):
    with open(git_path(worktree, STATE_NAME)) as handle:
        state = json.load(handle)
    left = [path for path in state["conflicts"] if has_markers(os.path.join(worktree, path))]
    if left:
        print("Still unresolved (conflict markers):")
        for path in left:
            print("  " + path)
        print("Resolve them, then run in %s: scripts/sync-upstream.py continue" % worktree)
        return 1
    duplicates = duplicate_functions(worktree)
    if duplicates:
        print("A function is defined in more than one lib/ fragment; keep one of each:")
        for name, paths in sorted(duplicates.items()):
            print("  %s: %s" % (name, ", ".join(paths)))
        return 1
    if os.path.isfile(os.path.join(worktree, "build.sh")):
        if subprocess.run(["bash", "build.sh"], cwd=worktree, stdout=subprocess.DEVNULL).returncode != 0:
            print("build.sh failed; fix the sources, then run: scripts/sync-upstream.py continue")
            return 1
    git("add", "-A", "--", ".", cwd=worktree)
    if skip_tests:
        print("Tests skipped (--skip-tests).")
    elif os.path.isfile(os.path.join(worktree, "tests", "run_all.sh")):
        print("Running tests/run_all.sh ...")
        if subprocess.run(["bash", "tests/run_all.sh"], cwd=worktree).returncode != 0:
            print("Tests failed. Fix them in %s, then run: scripts/sync-upstream.py continue" % worktree)
            return 1
    args = ["commit", "--no-edit", "--quiet"]
    for trailer in trailers:
        args += ["--trailer", trailer]
    git(*args, cwd=worktree)
    os.remove(git_path(worktree, STATE_NAME))
    print("Committed the merge of %s on %s." % (state["tag"], state["branch"]))
    print("Bring it into %s from %s with: git merge --ff-only %s"
          % (state["from_branch"], state["origin_dir"], state["branch"]))
    return 0


def default_worktree(repo, target):
    """Beside the checkout, outside any repository that encloses it: a
    checkout kept inside another repository (a cs session folder, say) would
    otherwise get a whole worktree as untracked files."""
    parent = os.path.dirname(repo)
    while True:
        proc = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=parent, capture_output=True)
        if proc.returncode != 0:
            break
        parent = os.path.dirname(proc.stdout.decode().strip())
    return os.path.join(parent, "%s-sync-%s" % (os.path.basename(repo), target.replace("/", "-")))


def require_clean(repo):
    if git("status", "--porcelain", cwd=repo).strip():
        raise SyncError("The working tree has uncommitted changes. Commit them first: the merge "
                        "starts from the last commit, and git only recognises a moved file once it is committed.")


def missing_releases(repo):
    """Release tags on <remote>/main that HEAD does not contain, oldest first."""
    out = git("tag", "--list", "v[0-9]*", "--merged", "%s/main" % REMOTE, "--no-merged", "HEAD",
              "--sort=v:refname", cwd=repo)
    return [tag for tag in out.split("\n") if tag.strip()]


def sync_worktrees(repo):
    """[(path, branch, tag)] for every worktree on a sync/<tag> branch."""
    found, path = [], None
    for line in git("worktree", "list", "--porcelain", cwd=repo).split("\n"):
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/sync/") and path:
            branch = line[len("branch refs/heads/"):]
            found.append((path, branch, branch[len("sync/"):]))
    return found


def land(repo, worktree, branch):
    """Fast-forward this checkout to a committed sync and remove its worktree."""
    git("merge", "--quiet", "--ff-only", branch, cwd=repo)
    if git_ok("worktree", "remove", worktree, cwd=repo):
        git("branch", "--quiet", "-d", branch, cwd=repo)
    else:
        print("Left %s in place: it holds files git does not track. Remove it with "
              "git worktree remove, then git branch -d %s." % (worktree, branch))


def start(args):
    repo = git("rev-parse", "--show-toplevel").strip()
    require_clean(repo)
    if not args.no_fetch:
        git("fetch", "--quiet", "--tags", REMOTE, cwd=repo)
    target = args.to or git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*",
                            "%s/main" % REMOTE, cwd=repo).strip()
    return begin(repo, target, args.worktree, args.branch, args.skip_tests, args.trailer)


def begin(repo, target, worktree=None, branch=None, skip_tests=False, trailers=()):
    """Merge target into HEAD in a new sync worktree; commit it there when
    nothing is left for a person. Returns 0 once committed (or nothing to do),
    1 when the worktree waits for a person."""
    upstream_rev = git("rev-parse", "%s^{commit}" % target, cwd=repo).strip()
    ours_rev = git("rev-parse", "HEAD", cwd=repo).strip()
    if git_ok("merge-base", "--is-ancestor", upstream_rev, ours_rev, cwd=repo):
        print("Already contains %s; nothing to merge." % target)
        return 0
    base_rev = git("merge-base", ours_rev, upstream_rev, cwd=repo).strip()
    from_branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo).strip()
    branch = branch or "sync/%s" % target
    worktree = os.path.abspath(worktree or default_worktree(repo, target))
    if os.path.exists(worktree):
        raise SyncError("%s already exists. Finish that sync with `continue` there, or remove it "
                        "(git worktree remove, then delete its branch) first." % worktree)
    git("worktree", "add", "--quiet", "-b", branch, worktree, ours_rev, cwd=repo)
    # Record the merge (two parents) but keep the fork's tree; the files are
    # merged below, in the fork's dialect.
    git("merge", "--quiet", "--no-ff", "--no-commit", "-s", "ours", upstream_rev, cwd=worktree)

    scratch = git_path(worktree, "ags-sync-scratch")
    os.makedirs(scratch, exist_ok=True)
    results, report = plan_merge(repo, base_rev, upstream_rev, ours_rev, scratch)
    for path, (result, executable) in results.items():
        write_result(worktree, path, result, executable)
    git("add", "-A", "--", ".", cwd=worktree)
    plain_total = plain_merge_conflicts(repo, ours_rev, upstream_rev)
    conflicts = [entry["path"] for entry in report if entry["marker"]]
    kept = [entry for entry in report if entry["conflicts"] and not entry["marker"]]
    plain_text = "?" if plain_total is None else str(plain_total)
    with open(git_path(worktree, "MERGE_MSG"), "w") as handle:
        handle.write("Merge upstream %s into %s\n\nMerged by scripts/sync-upstream.py: %d files changed "
                     "upstream, %d left in conflict for a person (a plain git merge left %s).\n"
                     % (target, from_branch, len(report), len(conflicts), plain_text))
    with open(git_path(worktree, STATE_NAME), "w") as handle:
        json.dump({"tag": target, "branch": branch, "from_branch": from_branch,
                   "conflicts": conflicts, "origin_dir": repo}, handle)

    print("Merging %s into %s (worktree %s)" % (target, branch, worktree))
    for entry in report:
        status = "%d conflict(s)" % entry["conflicts"] if entry["conflicts"] else "merged"
        if entry["plain"] != entry["conflicts"]:
            status += " (plain merge: %d)" % entry["plain"]
        how = " [%s]" % "; ".join(entry["how"]) if entry["how"] else ""
        print("  %-50s %s%s" % (entry["path"], status, how))
    print("%d files changed upstream; %d left in conflict (a plain git merge leaves %s)."
          % (len(report), len(conflicts) + len(kept), plain_text))
    for entry in kept:
        print("Check by hand, no markers written: %s (%s)" % (entry["path"], "; ".join(entry["how"])))
    if conflicts:
        print("Resolve the conflict markers in %s, then run there: scripts/sync-upstream.py continue" % worktree)
        return 1
    return finish(worktree, skip_tests, trailers)


def status(args):
    """Report the missing releases and dry-run the next one. Exit status 0
    when up to date, 1 when a release is missing."""
    repo = git("rev-parse", "--show-toplevel").strip()
    if not args.no_fetch:
        git("fetch", "--quiet", "--tags", REMOTE, cwd=repo)
    have = git("describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD", cwd=repo).strip()
    for path, branch, _ in sync_worktrees(repo):
        pending = os.path.isfile(git_path(path, STATE_NAME))
        print("Sync in progress: %s (%s, %s)" % (path, branch, "waiting for a person" if pending
                                                 else "committed; catch-up lands it"))
    tags = missing_releases(repo)
    if not tags:
        print("Up to date: this branch contains %s, the newest release on %s/main." % (have, REMOTE))
        return 0
    print("This branch contains %s. %d release(s) on %s/main to merge, oldest first:" % (have, len(tags), REMOTE))
    previous = have
    for tag in tags:
        files = len([f for f in git("diff", "--name-only", previous, tag, cwd=repo).split("\n") if f])
        date = git("log", "-1", "--format=%as", tag, cwd=repo).strip()
        print("  %-14s %s  %d files changed upstream" % (tag, date, files))
        previous = tag
    if args.brief:
        return 1
    ours_rev = git("rev-parse", "HEAD", cwd=repo).strip()
    upstream_rev = git("rev-parse", "%s^{commit}" % tags[0], cwd=repo).strip()
    base_rev = git("merge-base", ours_rev, upstream_rev, cwd=repo).strip()
    scratch = tempfile.mkdtemp(prefix="ags-sync-status-")
    try:
        _, report = plan_merge(repo, base_rev, upstream_rev, ours_rev, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    left = [entry["path"] for entry in report if entry["conflicts"]]
    plain = plain_merge_conflicts(repo, ours_rev, upstream_rev)
    print("Merging %s next would leave %d file(s) for a person (a plain git merge: %s)%s"
          % (tags[0], len(left), "?" if plain is None else plain, ":" if left else "."))
    for path in left:
        print("  " + path)
    print("Run: scripts/sync-upstream.py catch-up")
    return 1


def catch_up(args):
    """Merge every missing release in order. Each one that merges cleanly (and
    passes the tests) is committed and fast-forwarded into this branch; the
    first that needs a person stops the run in its sync worktree. Run again
    after `continue` there: the committed sync is landed first."""
    repo = git("rev-parse", "--show-toplevel").strip()
    require_clean(repo)
    branch_here = git("rev-parse", "--abbrev-ref", "HEAD", cwd=repo).strip()
    if branch_here == "HEAD":
        raise SyncError("This checkout is on a detached HEAD; check out the branch to bring up to date.")
    for path, branch, tag in sync_worktrees(repo):
        if os.path.isfile(git_path(path, STATE_NAME)):
            print("The sync of %s waits in %s. Resolve it, run scripts/sync-upstream.py continue there, "
                  "then run catch-up again." % (tag, path))
            return 1
        if git_ok("merge-base", "--is-ancestor", "HEAD", branch, cwd=repo):
            land(repo, path, branch)
            print("Landed %s on %s." % (tag, branch_here))
    if not args.no_fetch:
        git("fetch", "--quiet", "--tags", REMOTE, cwd=repo)
    tags = missing_releases(repo)
    if not tags:
        print("Up to date with %s/main." % REMOTE)
        return 0
    for index, tag in enumerate(tags):
        print("== %s (%d of %d)" % (tag, index + 1, len(tags)))
        code = begin(repo, tag, skip_tests=args.skip_tests, trailers=args.trailer)
        if code != 0:
            rest = tags[index + 1:]
            if rest:
                print("Still to merge after it: %s" % " ".join(rest))
            return code
        for path, branch, synced in sync_worktrees(repo):
            if synced == tag:
                land(repo, path, branch)
                print("Landed %s on %s." % (tag, branch_here))
    print("Up to date with %s/main." % REMOTE)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command")
    p_start = sub.add_parser("start", help="merge a release in a new sync worktree")
    p_start.add_argument("--to", help="tag or commit to merge (default: newest v* tag on %s/main)" % REMOTE)
    p_start.add_argument("--worktree", help="where to create the sync worktree")
    p_start.add_argument("--branch", help="branch for the merge (default: sync/<tag>)")
    p_start.add_argument("--no-fetch", action="store_true", help="do not fetch %s first" % REMOTE)
    p_cont = sub.add_parser("continue", help="check, build, test and commit a resolved sync")
    p_cont.add_argument("--worktree", default=".", help="the sync worktree (default: here)")
    p_status = sub.add_parser("status", help="list the missing releases and dry-run the next one "
                                             "(exit 1 when one is missing)")
    p_status.add_argument("--brief", action="store_true", help="list only; skip the dry run")
    p_catch = sub.add_parser("catch-up", help="merge every missing release in order, landing each one "
                                              "that needs no person")
    for p in (p_status, p_catch):
        p.add_argument("--no-fetch", action="store_true", help="do not fetch %s first" % REMOTE)
    for p in (p_start, p_cont, p_catch):
        p.add_argument("--skip-tests", action="store_true", help="do not run tests/run_all.sh")
        p.add_argument("--trailer", action="append", default=[], help="trailer for the merge commit")
    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return 2
    try:
        if args.command == "start":
            return start(args)
        if args.command == "status":
            return status(args)
        if args.command == "catch-up":
            return catch_up(args)
        worktree = git("rev-parse", "--show-toplevel", cwd=args.worktree).strip()
        if not os.path.isfile(git_path(worktree, STATE_NAME)):
            raise SyncError("No sync in progress in %s." % worktree)
        return finish(worktree, args.skip_tests, args.trailer)
    except SyncError as error:
        print("Error: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
