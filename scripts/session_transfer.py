# ABOUTME: Helpers shared by code-sessions-to-cs.py and cs-to-code-sessions.py, which carry sessions between the stable cs and code-sessions.
# ABOUTME: Claude folder names, open-session checks, the append-only transcript merge and the protocol wording.
"""What both directions of a session transfer need.

The two scripts copy the same kinds of things in opposite directions: Claude
Code's transcript folders, the session protocol in CLAUDE.local.md, and
secrets. Their rules live here so the two cannot drift apart.
"""

import ctypes
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


def tilde(path):
    home = os.path.expanduser("~")
    if path == home or path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def claude_project_key(path):
    """Claude Code names a transcript folder after the path, every other character a '-'."""
    return re.sub(r"[^A-Za-z0-9]", "-", path)


def pid_alive(value):
    try:
        pid = int(str(value).strip())
    except ValueError:
        return False
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def session_is_open(meta):
    """True when a lock or run lease in .cs names a live process."""
    try:
        with open(os.path.join(meta, "session.lock")) as f:
            if pid_alive(f.read()):
                return True
    except OSError:
        pass
    try:
        with open(os.path.join(meta, "local", "run-lease.json")) as f:
            lease = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(lease, dict) and any(
        pid_alive(lease.get(key, "")) for key in ("owner_pid", "native_pid"))


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def state_value(meta, key):
    text = read_text(os.path.join(meta, "local", "state")) or ""
    for line in text.splitlines():
        if line.startswith(key + ":"):
            return line[len(key) + 1:].strip()
    return ""


def write_atomic(path, data, like=None, prefix=".session-transfer."):
    """Replace path with data (bytes), keeping the mode of like or of path itself."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=prefix)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        source = like if like is not None else path
        if os.path.exists(source):
            shutil.copystat(source, tmp)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _load_clonefile():
    if sys.platform != "darwin":
        return None
    try:
        clone = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).clonefile
    except (OSError, AttributeError):
        return None
    clone.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32)
    clone.restype = ctypes.c_int
    return clone


_CLONEFILE = _load_clonefile()


def copy_file(src, dst):
    """Copy src to dst, which must not exist yet, with copy2's metadata.

    On APFS the copy is a clone: it shares the original's blocks until either
    side writes, so carrying gigabytes of transcripts costs no disk space.
    Anywhere a clone is refused (another volume, another file system) it is an
    ordinary copy.
    """
    if _CLONEFILE is not None and _CLONEFILE(os.fsencode(src), os.fsencode(dst), 0) == 0:
        shutil.copystat(src, dst)
        return
    shutil.copy2(src, dst)


def files_equal_prefix(shorter, longer, length):
    """True when the first length bytes of longer equal the file shorter."""
    with open(shorter, "rb") as a, open(longer, "rb") as b:
        remaining = length
        while remaining > 0:
            chunk = a.read(min(1 << 20, remaining))
            if not chunk or b.read(len(chunk)) != chunk:
                return False
            remaining -= len(chunk)
    return True


class Tally:
    def __init__(self):
        self.new = 0
        self.grown = 0
        self.same = 0
        self.ahead = 0
        self.diverged = []

    def add(self, other):
        self.new += other.new
        self.grown += other.grown
        self.same += other.same
        self.ahead += other.ahead
        self.diverged += other.diverged

    def pending(self):
        return self.new + self.grown


def merge_tree(src, dst, apply, tmp_suffix=".session-transfer.tmp"):
    """Copy files of src missing from dst, and replace those that only grew.

    Claude Code appends to a transcript and never rewrites it, so a copy that
    is an unchanged start of the source's file is safe to replace. A copy that
    holds more than the source's is a conversation continued on the receiving
    side; one that differs inside is a conversation continued on both sides.
    Both are left alone.
    """
    tally = Tally()
    if not os.path.isdir(src):
        return tally
    for root, dirs, files in os.walk(src):
        dirs.sort()
        rel = os.path.relpath(root, src)
        target_dir = dst if rel == "." else os.path.join(dst, rel)
        for name in sorted(files):
            s = os.path.join(root, name)
            d = os.path.join(target_dir, name)
            if os.path.islink(s) or not os.path.isfile(s):
                continue
            if not os.path.lexists(d):
                tally.new += 1
                if apply:
                    if not os.path.isdir(target_dir):
                        os.makedirs(target_dir)
                        shutil.copystat(root, target_dir)
                    _replace_with_copy(s, d, tmp_suffix)
                continue
            if os.path.islink(d) or not os.path.isfile(d):
                tally.diverged.append(d)
                continue
            s_size, d_size = os.path.getsize(s), os.path.getsize(d)
            if d_size < s_size and files_equal_prefix(d, s, d_size):
                tally.grown += 1
                if apply:
                    _replace_with_copy(s, d, tmp_suffix)
            elif d_size == s_size and files_equal_prefix(d, s, d_size):
                tally.same += 1
            elif d_size > s_size and files_equal_prefix(s, d, s_size):
                tally.ahead += 1
            else:
                tally.diverged.append(d)
    return tally


def _replace_with_copy(src, dst, tmp_suffix):
    tmp = dst + tmp_suffix
    if os.path.lexists(tmp):
        os.unlink(tmp)
    copy_file(src, tmp)
    os.replace(tmp, dst)


def special_files(directory, names):
    """copytree's ignore: sockets and pipes belong to a running process, and copying one blocks."""
    out = []
    for name in names:
        mode = os.lstat(os.path.join(directory, name)).st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)):
            out.append(name)
    return out


def scrubbed_env():
    """The caller's environment without what a code-sessions or cs session exports."""
    env = {}
    for key, value in os.environ.items():
        if key.startswith(("CS_", "CLAUDE_SESSION_")):
            continue
        if key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODE_SESSIONS_HOME"):
            continue
        env[key] = value
    return env


class SecretsError(Exception):
    pass


def secret_names(command, env, session):
    try:
        result = subprocess.run(command + ["--session", session, "list"], env=env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError as error:
        raise SecretsError("could not run %s: %s" % (tilde(command[0]), error.strerror))
    if result.returncode != 0:
        detail = (result.stderr.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        raise SecretsError("%s could not list %s: %s" % (os.path.basename(command[0]), session, detail))
    return [line[4:] for line in result.stdout.splitlines() if line.startswith("  - ")]


def secret_differs(first_command, first_env, second_command, second_env):
    """True when two secrets get commands give different values, or one fails; neither value is shown."""
    values = []
    for command, env in ((first_command, first_env), (second_command, second_env)):
        got = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, capture_output=True)
        if got.returncode != 0:
            return True
        values.append(got.stdout[:-1] if got.stdout.endswith(b"\n") else got.stdout)
    return values[0] != values[1]


def copy_secret(get_command, get_env, set_command, set_env):
    """Move one value from a secrets get to a secrets set, on stdin only; True when stored.

    Neither command's output is shown: a refusal quotes the value it refused.
    """
    got = subprocess.run(get_command, env=get_env, stdin=subprocess.DEVNULL, capture_output=True)
    if got.returncode != 0:
        return False
    value = got.stdout[:-1] if got.stdout.endswith(b"\n") else got.stdout
    stored = subprocess.run(set_command, env=set_env, input=value, capture_output=True)
    return stored.returncode == 0


# --- copies that keep in step with their source ---------------------------
#
# Each direction makes its own copy of a session (never a link, so neither
# manager writes into the other's folders) and keeps a record of the last
# sync beside the receiving side. A rerun brings over what the source changed
# since: a file changed only there is copied, one changed only in the copy is
# kept, and one changed on both sides keeps the copy's and is reported, once.
# Files are told apart by their inode change time (ctime), which nothing but
# the kernel sets: each side has a mark, taken before that side is read, and
# a file whose ctime is past its side's mark changed since. The copy's own
# writes are recorded with their ctimes, so they are not taken for changes
# made in the copy. The record holds the paths both sides had at the last
# sync, so a deletion is told from an addition.

CLONE_NOFOLLOW = 1
STATE = os.path.join(".cs", "local", "state")
SESSION_META = ".cs"
# Taken off every mark, so a clock coarser than a nanosecond hides nothing.
# The price: a change made in the 2 s before a run is looked at again on the
# next one (a copy is then a no-op; a conflict is reported a second time).
MARGIN_NS = 2 * 10 ** 9
# What belongs to the process holding a session open, or to the manager that
# stamped it: a copy never carries these, and a sync leaves them be.
PROCESS_FILES = frozenset(os.path.join(".cs", *parts) for parts in (
    ("session.lock",), ("local", "run-lease.json"), ("local", "run-lease.guard"), ("local", "migrated")))
PROCESS_PREFIXES = (os.path.join(".cs", "local", ".session-lock."), os.path.join(".cs", "local", ".run-lease."))
LOGGED = 1000


def left_out(rel):
    return rel in PROCESS_FILES or rel.startswith(PROCESS_PREFIXES)


def mark_now():
    return time.time_ns() - MARGIN_NS


def relinker(roots):
    """A function that moves an absolute link target inside one of roots (old -> new) to its new place.

    A worktree may link node_modules or an .env file to the project by an
    absolute path; copied as it is, the copy would write through the link
    into the folder it was copied from.
    """
    pairs = sorted(((os.path.normpath(old), new) for old, new in roots.items()), key=lambda p: -len(p[0]))

    def relink(target):
        if not os.path.isabs(target):
            return target
        for old, new in pairs:
            if target == old or target.startswith(old + os.sep):
                return new + target[len(old):]
        return target
    return relink


def clone_tree(src, dst, relink=None):
    """Copy the directory src to dst, which must not exist; the paths a sync tracks.

    On APFS one clonefile call clones the whole tree, sharing every block
    until either side writes, and keeps each file's times. Elsewhere it is a
    copy, file by file. Sockets, pipes and the session's lock and lease belong
    to a process on the other side and are dropped from the copy; a link into
    the source is pointed at the copy (see relinker).
    """
    if _CLONEFILE is None or _CLONEFILE(os.fsencode(src), os.fsencode(dst), CLONE_NOFOLLOW) != 0:
        if os.path.lexists(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True, ignore=special_files, copy_function=copy_file)
    drop_git_locks(os.path.join(dst, ".git"))
    paths = set()
    for rel, st in _walk(dst, None, keep_special=True):
        path = os.path.join(dst, rel)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)) or left_out(rel):
            os.unlink(path)
            continue
        if relink and stat.S_ISLNK(st.st_mode):
            target = os.readlink(path)
            if relink(target) != target:
                os.unlink(path)
                os.symlink(relink(target), path)
        paths.add(rel)
    return paths


def reap(directory, prefix):
    """Remove what a copy stopped by a kill left in directory under its temporary prefix."""
    for name in os.listdir(directory) if os.path.isdir(directory) else []:
        path = os.path.join(directory, name)
        if name.startswith(prefix) and os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)


def copy_admin_dir(src, dst):
    """Copy a worktree's administrative directory (HEAD, index, its own refs) from a repository's .git/worktrees."""
    shutil.copytree(src, dst, symlinks=True, ignore=special_files, copy_function=copy_file)
    drop_git_locks(dst)


def admin_dir_for(worktrees, stem, back_link):
    """A free name in worktrees for a worktree's administrative directory, clearing one an earlier copy left."""
    admin_id, n = stem, 1
    while os.path.lexists(os.path.join(worktrees, admin_id)):
        if read_text(os.path.join(worktrees, admin_id, "gitdir")) == back_link:
            # Left by a copy that stopped before its rename.
            shutil.rmtree(os.path.join(worktrees, admin_id))
            break
        n += 1
        admin_id = "%s%d" % (stem, n)
    return os.path.join(worktrees, admin_id)


def drop_git_locks(git_dir):
    """A git command running on the other side while it was copied leaves its locks in the copy."""
    if not os.path.isdir(git_dir) or os.path.islink(git_dir):
        return
    for name in os.listdir(git_dir):
        if name.endswith(".lock") or name == "gc.pid":
            path = os.path.join(git_dir, name)
            if os.path.isfile(path) and not os.path.islink(path):
                os.unlink(path)
    for root, _, files in os.walk(os.path.join(git_dir, "refs")):
        for name in files:
            if name.endswith(".lock"):
                os.unlink(os.path.join(root, name))


def _walk(root, only, keep_special=False, unreadable=None):
    """(relative path, lstat) of every file and link under root, past the top-level .git and left_out paths.

    A folder that cannot be read is added to unreadable (a list), when given.
    """
    stack = [only.rstrip(os.sep)] if only else [""]
    while stack:
        rel_dir = stack.pop()
        try:
            entries = os.scandir(os.path.join(root, rel_dir) if rel_dir else root)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            if unreadable is None:
                raise
            unreadable.append(rel_dir)
            continue
        with entries:
            for entry in entries:
                if not rel_dir and entry.name == ".git":
                    continue
                rel = os.path.join(rel_dir, entry.name) if rel_dir else entry.name
                try:
                    st = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if stat.S_ISDIR(st.st_mode):
                    stack.append(rel)
                elif keep_special or ((stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)) and not left_out(rel)):
                    yield rel, st


def _same(src, dst, s, d, data, relink):
    """True when the copy dst holds what src would put there (data: src's bytes after a rewrite, if any)."""
    if stat.S_ISLNK(s.st_mode) or stat.S_ISLNK(d.st_mode):
        if not (stat.S_ISLNK(s.st_mode) and stat.S_ISLNK(d.st_mode)):
            return False
        target = os.readlink(src)
        return (relink(target) if relink else target) == os.readlink(dst)
    if (s.st_mode & 0o777) != (d.st_mode & 0o777):
        return False
    if data is not None:
        return d.st_size == len(data) and _read_bytes(dst) == data
    return s.st_size == d.st_size and files_equal_prefix(src, dst, s.st_size)


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _put(src, dst, data, relink, tmp_suffix):
    """Make dst what src is (or the rewritten bytes data), replacing it whole."""
    parent = os.path.dirname(dst)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    tmp = dst + tmp_suffix
    if os.path.lexists(tmp):
        os.unlink(tmp)
    if os.path.islink(src):
        target = os.readlink(src)
        os.symlink(relink(target) if relink else target, tmp)
    elif data is not None:
        with open(tmp, "wb") as f:
            f.write(data)
        shutil.copymode(src, tmp)
    else:
        copy_file(src, tmp)
    os.replace(tmp, dst)


def parse_state(text):
    """The key: value lines of .cs/local/state, in order."""
    out = {}
    for line in (text or "").splitlines():
        key, sep, value = line.partition(":")
        if sep and key and " " not in key:
            out[key] = value.strip()
    return out


def merge_state(base, src, dst, pinned=()):
    """Bring each key the source changed since base into dst's state; (text, keys changed on both sides)."""
    b, s, d = parse_state(base), parse_state(src), parse_state(dst)
    merged = dict(d)
    conflicts = []
    for key in list(s) + [k for k in b if k not in s]:
        if key in pinned or s.get(key) == b.get(key) or s.get(key) == d.get(key):
            continue
        if d.get(key) != b.get(key):
            conflicts.append(key)
        elif key in s:
            merged[key] = s[key]
        else:
            merged.pop(key, None)
    if merged == d:
        return dst, conflicts
    lines = []
    for line in (dst or "").splitlines():
        key, sep, _ = line.partition(":")
        if sep and key in d and " " not in key:
            if key in merged:
                lines.append("%s: %s" % (key, merged.pop(key)))
            continue
        lines.append(line)
    lines += ["%s: %s" % (key, merged[key]) for key in merged if key not in d]
    return "\n".join(lines) + "\n", conflicts


class FileSync:
    def __init__(self):
        self.copied = 0
        self.deleted = 0
        self.kept = 0           # changed on the receiving side only
        self.conflicts = []     # (path, why): the receiving side's is kept
        self.failed = 0         # reads or writes that did not happen; the marks then stay
        self.paths = set()
        self.written = {}       # path -> ctime of what this sync wrote there
        self.state = None       # the source's state, the next merge's base


def _inside(rel, folder):
    return not folder or rel == folder or rel.startswith(folder + os.sep)


def sync_files(src, dst, mark, apply, rewrites=None, relink=None, only=None, pinned=(),
               tmp_suffix=".session-transfer.tmp"):
    """Bring what src changed since the last sync into its copy dst; see the comment above.

    mark holds the last sync: since ({folder: [src mark, dst mark]}, "" for
    the whole tree; the latest that holds a path counts), written (path ->
    ctime of the copy's own last writes), paths (on both sides then) and
    state (src's .cs/local/state then). Each side's mark must have been taken
    before that side was read. rewrites maps a path to a function of its
    bytes giving what the copy should hold, or None to copy it as is; relink
    places absolute link targets. With only, just that folder is synced.
    """
    out = FileSync()
    rewrites = rewrites or {}
    known = mark["paths"]
    since = mark.get("since") or {"": [0, 0]}
    written = mark.get("written") or {}
    out.paths = {p for p in known if not _inside(p, only)}
    blind = []
    s_files = dict(_walk(src, only, unreadable=blind))
    d_files = dict(_walk(dst, only, unreadable=blind))
    for folder in sorted(set(blind)):
        out.failed += 1
        out.conflicts.append((folder or ".", "could not read this folder on one side; left as it is"))

    def marks(rel):
        held = [v for k, v in since.items() if _inside(rel, k)]
        return max(v[0] for v in held), max(v[1] for v in held)

    def attempt(rel, action, *args):
        try:
            action(*args)
            path = os.path.join(dst, rel)
            if os.path.lexists(path):
                out.written[rel] = os.lstat(path).st_ctime_ns
            return True
        except OSError as error:
            out.failed += 1
            out.conflicts.append((rel, "could not write it: %s" % (error.strerror or error)))
            return False

    def unchanged_since_read(rel, d):
        """The copy's file is still what was read, so a write cannot lose an edit made during the sync."""
        try:
            now = os.lstat(os.path.join(dst, rel))
        except FileNotFoundError:
            return d is None
        if d is None or now.st_ctime_ns != d.st_ctime_ns:
            out.conflicts.append((rel, "changed here while the sync ran"))
            return False
        return True

    for rel in sorted(set(s_files) | set(d_files)):
        if any(_inside(rel, folder) for folder in blind):
            if rel in known:
                out.paths.add(rel)
            continue
        s, d = s_files.get(rel), d_files.get(rel)
        s_since, d_since = marks(rel)
        s_new = s is not None and s.st_ctime_ns > s_since
        d_new = d is not None and d.st_ctime_ns > d_since and written.get(rel) != d.st_ctime_ns
        was = rel in known
        sp, dp = os.path.join(src, rel), os.path.join(dst, rel)
        try:
            if s is not None and d is not None:
                out.paths.add(rel)
                if rel == STATE:
                    text = read_text(sp)
                    out.state = text
                    if s_new:
                        merged, keys = merge_state(mark.get("state"), text, read_text(dp), pinned)
                        if merged != read_text(dp):
                            out.copied += 1
                            if apply and unchanged_since_read(rel, d):
                                attempt(rel, write_atomic, dp, merged.encode(), None,
                                        os.path.basename(tmp_suffix))
                        out.conflicts += [(rel, "%s changed on both sides" % k) for k in keys]
                    elif d_new:
                        out.kept += 1
                    continue
                if not s_new:
                    out.kept += d_new
                    continue
                data = (rewrites[rel](_read_bytes(sp))
                        if rel in rewrites and stat.S_ISREG(s.st_mode) else None)
                if was and not d_new:
                    if not _same(sp, dp, s, d, data, relink):
                        out.copied += 1
                        if apply and unchanged_since_read(rel, d):
                            attempt(rel, _put, sp, dp, data, relink, tmp_suffix)
                elif not _same(sp, dp, s, d, data, relink):
                    out.conflicts.append((rel, "changed on both sides" if was else "added on both sides"))
            elif s is not None:
                if was:
                    # Deleted in the copy: it stays deleted, and the path is
                    # remembered so the next sync does not bring it back.
                    out.paths.add(rel)
                    if s_new:
                        out.conflicts.append((rel, "deleted here, changed in the source"))
                    continue
                if os.path.lexists(dp):
                    out.conflicts.append((rel, "a folder here, a file in the source"))
                    continue
                data = (rewrites[rel](_read_bytes(sp))
                        if rel in rewrites and stat.S_ISREG(s.st_mode) else None)
                out.copied += 1
                if not apply:
                    out.paths.add(rel)
                elif unchanged_since_read(rel, None) and attempt(rel, _put, sp, dp, data, relink, tmp_suffix):
                    out.paths.add(rel)
            else:
                if not was:
                    out.kept += d_new
                elif d_new:
                    out.conflicts.append((rel, "deleted in the source, changed here"))
                else:
                    out.deleted += 1
                    if apply and unchanged_since_read(rel, d):
                        attempt(rel, os.unlink, dp)
        except OSError as error:
            out.failed += 1
            out.conflicts.append((rel, "could not read it: %s" % (error.strerror or error)))
            if was:
                out.paths.add(rel)
    if out.state is None and os.path.isfile(os.path.join(src, STATE)):
        out.state = read_text(os.path.join(src, STATE))
    return out


# --- git: the copy's own repository, kept in step with the source's --------
#
# Commands on the source run with GIT_OPTIONAL_LOCKS=0 and only ever read:
# a status-like refresh would otherwise rewrite the source's index.

def _git_env(extra=None):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY"):
        env.pop(key, None)
    env.update(extra or {})
    return env


def git(cwd, *args, **kwargs):
    """Run git in cwd; text output unless binary=True. input= goes to its stdin, env= adds variables."""
    binary = kwargs.pop("binary", False)
    data = kwargs.pop("input", None)
    extra = kwargs.pop("env", None)
    return subprocess.run(["git", "-C", cwd] + list(args), env=_git_env(extra), capture_output=True,
                          input=data, stdin=None if data is not None else subprocess.DEVNULL,
                          text=not binary)


def git_ok(cwd, *args, **kwargs):
    result = git(cwd, *args, **kwargs)
    if result.returncode != 0:
        err = result.stderr if isinstance(result.stderr, str) else result.stderr.decode(errors="replace")
        detail = (err.strip().splitlines() or ["exit %d" % result.returncode])[-1]
        raise OSError("git %s failed in %s: %s" % (args[0], tilde(cwd), detail))
    return result


def head_state(worktree):
    """HEAD as '<ref or detached> <commit>'."""
    ref = git(worktree, "symbolic-ref", "-q", "HEAD").stdout.strip()
    sha = git(worktree, "rev-parse", "-q", "--verify", "HEAD").stdout.strip()
    return "%s %s" % (ref or "detached", sha)


def index_digest(worktree):
    """What the index holds (modes, blobs, paths), not its stat cache."""
    listing = git(worktree, "ls-files", "-s", "-z", binary=True).stdout
    return hashlib.sha1(listing).hexdigest()


def branch_heads(repo):
    out = git(repo, "for-each-ref", "--format=%(refname:strip=2) %(objectname)", "refs/heads").stdout
    return dict(line.rsplit(" ", 1) for line in out.splitlines() if " " in line)


def checked_out(repo):
    """Branch name -> the worktree that has it checked out."""
    out, path = {}, None
    for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/") and path:
            out[line[len("branch refs/heads/"):]] = path
    return out


def _is_ancestor(repo, a, b):
    """True or False; None when repo lacks one of the commits."""
    rc = git(repo, "merge-base", "--is-ancestor", a, b).returncode
    return {0: True, 1: False}.get(rc)


def relation(dst_repo, src_repo, d, s):
    """same, behind (the copy's commit is an ancestor of the source's), ahead or diverged."""
    if d == s:
        return "same"
    for a, b, answer in ((d, s, "behind"), (s, d, "ahead")):
        found = _is_ancestor(dst_repo, a, b)
        if found is None:
            found = _is_ancestor(src_repo, a, b)
        if found:
            return answer
    return "diverged"


def fetch_source(dst_repo, src_repo, label):
    """The source's branches as refs/remotes/<label>/* in the copy; the source is only read."""
    git_ok(dst_repo, "fetch", "--quiet", "--no-tags", "--prune", src_repo, "+refs/heads/*:refs/remotes/%s/*" % label)


class BranchSync:
    def __init__(self):
        self.created = []
        self.moved = []
        self.ahead = []
        self.diverged = []
        self.heads = {}


def sync_branches(src_repo, dst_repo, recorded, apply, skip=()):
    """Bring each branch the source moved into the copy, unless the copy moved it too.

    recorded maps each branch to where both sides had it at the last sync.
    Branches in skip (checked out in the copy) are left to their worktree,
    and so is their record.
    """
    out = BranchSync()
    src, dst = branch_heads(src_repo), branch_heads(dst_repo)
    out.heads = dict(recorded)
    for name, s in sorted(src.items()):
        if name in skip:
            continue
        d, r = dst.get(name), recorded.get(name)
        # Past this sync, the source's tip is the base: a branch that moved
        # on both sides is reported once, not on every run.
        out.heads[name] = s
        if d == s:
            continue
        if d is None:
            if r is None:
                out.created.append(name)
                if apply:
                    git_ok(dst_repo, "update-ref", "refs/heads/" + name, s, "")
            # else: deleted in the copy since the last sync; it stays deleted.
            continue
        if s == r:
            continue            # only the copy moved it
        how = "taken" if d == r else relation(dst_repo, src_repo, d, s)
        if how in ("taken", "behind"):
            out.moved.append(name)
            if apply:
                git_ok(dst_repo, "update-ref", "refs/heads/" + name, s, d)
        elif how == "ahead":
            out.ahead.append(name)
        else:
            out.diverged.append(name)
    return out


def copy_index(src_worktree, dst_worktree):
    """Give the copy's worktree the source's index, staged blobs included.

    The new index is built beside the old one and renamed over it, so a run
    stopped halfway leaves the old index, never an empty one.
    """
    listing = git_ok(src_worktree, "ls-files", "-s", "-z", binary=True).stdout
    entries = [e for e in listing.split(b"\0") if e]
    blobs = sorted({e.split(b" ", 2)[1] for e in entries if not e.startswith(b"160000")})
    if blobs:
        check = git_ok(dst_worktree, "cat-file", "--batch-check", input=b"\n".join(blobs) + b"\n", binary=True).stdout
        for line in check.splitlines():
            if line.endswith(b" missing"):
                sha = line.split()[0].decode()
                blob = git_ok(src_worktree, "cat-file", "blob", sha, binary=True).stdout
                git_ok(dst_worktree, "hash-object", "-w", "--stdin", input=blob, binary=True)
    index = git_ok(dst_worktree, "rev-parse", "--path-format=absolute", "--git-path", "index").stdout.strip()
    tmp = index + ".session-transfer"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    try:
        git_ok(dst_worktree, "read-tree", "--empty", env={"GIT_INDEX_FILE": tmp})
        git_ok(dst_worktree, "update-index", "-z", "--index-info", input=listing, binary=True,
               env={"GIT_INDEX_FILE": tmp})
        os.replace(tmp, index)
    finally:
        if os.path.lexists(tmp):
            os.unlink(tmp)


def copy_blocker(src_worktree, dst_repo, due=()):
    """Why a feature worktree cannot join dst_repo as a worktree as it stands, or None.

    due: branches this run moves or adds in the copy (a dry run has not yet).
    """
    ref, sha = head_state(src_worktree).split(" ", 1)
    if not sha:
        return "it has no commit checked out"
    if ref == "detached":
        if git(dst_repo, "cat-file", "-e", sha + "^{commit}").returncode != 0:
            return "its detached HEAD %s is on no branch the copy has" % sha[:10]
        return None
    name = ref[len("refs/heads/"):]
    where = checked_out(dst_repo).get(name)
    if where:
        return "%s is checked out in %s already" % (name, tilde(where))
    if branch_heads(dst_repo).get(name) != sha and name not in due:
        return "the copy's %s is not where the source's is (see the branches above)" % name
    return None


def sync_worktree_git(src_worktree, dst_worktree, src_repo, dst_repo, mark, heads, apply, busy=()):
    """Bring the source worktree's HEAD and index over when the copy left its own alone.

    Returns (what, detail): same, kept (only the copy moved), taken,
    diverged (moved on both sides; diverged-seen when the source has not moved
    since that was reported) or refused, with the reason. mark holds head and
    index of the last sync; heads is the branch record, updated for a branch
    this moves.
    """
    sh, si = head_state(src_worktree), index_digest(src_worktree)
    dh, di = head_state(dst_worktree), index_digest(dst_worktree)
    rh, ri = mark.get("head"), mark.get("index")
    if (sh, si) == (dh, di):
        mark.update(head=sh, index=si)
        mark.pop("diverged", None)
        return "same", None
    if (sh, si) == (rh, ri):
        mark.pop("diverged", None)
        return "kept", None
    if (dh, di) != (rh, ri):
        # The record keeps the state both had, so files stay pending until
        # git agrees again; the source's state now is remembered so this is
        # reported once.
        seen = mark.get("diverged") == [sh, si]
        mark["diverged"] = [sh, si]
        return ("diverged-seen" if seen else "diverged"), "HEAD or the index moved on both sides"
    ref, sha = sh.split(" ", 1)
    if not sha:
        return "refused", "the source has no commit checked out"
    if git(dst_repo, "cat-file", "-e", sha + "^{commit}").returncode != 0 and apply:
        return "refused", "its commit %s is on no branch the copy fetched" % sha[:10]
    if ref != "detached":
        name = ref[len("refs/heads/"):]
        d = branch_heads(dst_repo).get(name)
        if name in busy:
            return "refused", "%s is checked out in another worktree of the copy" % name
        if d not in (None, sha) and dh.split(" ", 1)[0] != ref:
            how = "taken" if d == heads.get(name) else relation(dst_repo, src_repo, d, sha)
            if how not in ("taken", "behind"):
                return "refused", "the copy's %s moved on since the last sync" % name
    if apply:
        # The index first: stopped after it, the copy shows the source's
        # changes as staged, which loses nothing; the refs last.
        copy_index(src_worktree, dst_worktree)
        if ref != "detached":
            git_ok(dst_repo, "update-ref", ref, sha)
            git_ok(dst_worktree, "symbolic-ref", "HEAD", ref)
            heads[ref[len("refs/heads/"):]] = sha
        else:
            git_ok(dst_worktree, "update-ref", "--no-deref", "HEAD", sha)
    mark.update(head=sh, index=si)
    mark.pop("diverged", None)
    return "taken", None


class Record:
    """What the last sync of one session family left: a JSON file, and per session its paths and own writes."""

    def __init__(self, directory):
        self.dir = directory
        self.data = json.loads(read_text(os.path.join(directory, "record.json")) or "{}")
        self.data.setdefault("sessions", {})
        self._paths = {}
        self._written = {}
        self._dirty = set()

    def session(self, name):
        return self.data["sessions"].setdefault(name, {})

    def _load(self, name, suffix, empty):
        path = os.path.join(self.dir, name + suffix)
        try:
            with gzip.open(path, "rt") as f:
                return f.read()
        except FileNotFoundError:
            if self.data["sessions"].get(name):
                # Without it every file deleted on the receiving side would
                # look new on the source's and come back.
                raise OSError("the record of %s's last sync has lost %s; move %s aside to copy it afresh"
                              % (name, tilde(path), tilde(self.dir)))
            return empty
        except (OSError, EOFError, ValueError) as error:
            raise OSError("the record of %s's last sync is unreadable (%s): %s"
                          % (name, tilde(path), getattr(error, "strerror", None) or error))

    def paths(self, name):
        if name not in self._paths:
            self._paths[name] = set(self._load(name, ".paths.gz", "").split("\0")) - {""}
        return self._paths[name]

    def written(self, name):
        if name not in self._written:
            try:
                self._written[name] = json.loads(self._load(name, ".written.gz", "{}"))
            except OSError:
                self._written[name] = {}
        return self._written[name]

    def set_paths(self, name, paths, written=None):
        self._paths[name] = paths
        self._written[name] = written or {}
        self._dirty.add(name)

    def forget(self, name):
        self.data["sessions"].pop(name, None)
        self._paths[name] = None
        self._written[name] = None
        self._dirty.add(name)

    def save(self):
        if not self.data["sessions"] and not os.path.isdir(self.dir):
            return
        os.makedirs(self.dir, exist_ok=True)
        for name in sorted(self._dirty):
            paths, written = self._paths.get(name), self._written.get(name)
            self._save(name + ".paths.gz", None if paths is None else "\0".join(sorted(paths)))
            self._save(name + ".written.gz", None if written is None else json.dumps(written))
        self._dirty.clear()
        write_atomic(os.path.join(self.dir, "record.json"),
                     (json.dumps(self.data, indent=1, sort_keys=True) + "\n").encode(), prefix=".record.")

    def _save(self, filename, text):
        target = os.path.join(self.dir, filename)
        if text is None:
            if os.path.lexists(target):
                os.unlink(target)
            return
        fd, tmp = tempfile.mkstemp(dir=self.dir, prefix=".record.")
        os.close(fd)
        with gzip.open(tmp, "wt") as f:
            f.write(text)
        os.replace(tmp, target)


def shown(names, limit=10):
    if len(names) <= limit:
        return ", ".join(names)
    return "%s and %d more" % (", ".join(names[:limit]), len(names) - limit)


class Syncer:
    """Brings a copy up to date with its source, saying what it did; both directions use it.

    src and dst are what the reader calls the two sides (cs, code-sessions). say,
    problem and log are the calling script's.
    """

    SHOWN = 10

    def __init__(self, src, dst, apply, say, problem, log, log_path, tmp_suffix):
        self.src, self.dst = src, dst
        self.apply = apply
        self.say, self.problem, self.log = say, problem, log
        self.log_path = log_path
        self.tmp_suffix = tmp_suffix
        self.fetched = set()

    def fetch(self, src_repo, dst_repo):
        if self.apply and dst_repo not in self.fetched:
            fetch_source(dst_repo, src_repo, self.src)
            self.fetched.add(dst_repo)

    def repo(self, name, src_repo, dst_repo, record):
        """Fetch the source's branches into the copy and move along those the copy left alone."""
        self.fetch(src_repo, dst_repo)
        busy = checked_out(dst_repo)
        result = sync_branches(src_repo, dst_repo, record.data.get("heads", {}), self.apply, skip=set(busy))
        record.data["heads"] = result.heads
        verb = "" if self.apply else "would be "
        if result.created:
            self.say("branches new in %s, %sadded: %s" % (self.src, verb, shown(result.created)))
        if result.moved:
            self.say("branches %s moved on, %smoved along: %s" % (self.src, verb, shown(result.moved)))
        if result.ahead:
            self.say("branches %s moved past %s, kept: %s" % (self.dst, self.src, shown(result.ahead)))
        for branch in result.diverged:
            self.problem("branch %s moved on in both %s and %s; %s's is kept, %s's is at refs/remotes/%s/%s"
                         % (branch, self.src, self.dst, self.dst, self.src, self.src, branch))
        if result.moved or result.created:
            self.log("synced-branches", session=name, created=result.created, moved=result.moved)
        return result

    def session(self, name, src, dst, src_repo, dst_repo, record, rewrites=None, relink=None, pinned=(),
                is_repo=True):
        """Bring one worktree's git state and files over where the copy left them alone."""
        mark = record.session(name)
        only = None
        if is_repo:
            self.fetch(src_repo, dst_repo)
            busy = {b for b, where in checked_out(dst_repo).items()
                    if os.path.realpath(where) != os.path.realpath(dst)}
            how, why = sync_worktree_git(src, dst, src_repo, dst_repo, mark, record.data.setdefault("heads", {}),
                                         self.apply, busy)
            if how == "taken":
                ref, sha = head_state(src).split(" ", 1)
                self.say("%s: %s %s's HEAD and index: %s at %s" % (
                    name, "took" if self.apply else "would take", self.src,
                    ref.replace("refs/heads/", "") if ref != "detached" else "a detached HEAD", sha[:10]))
            elif how == "kept":
                self.say("%s: HEAD and index moved on in %s only, kept" % (name, self.dst))
            elif how in ("diverged", "refused"):
                self.problem("%s: git left as %s has it: %s; only its .cs/ is brought over until git agrees "
                             "again" % (name, self.dst, why))
            if how in ("diverged", "diverged-seen", "refused"):
                only = SESSION_META
        # Each side's mark is taken before that side is read.
        since = mark_now()
        last = {"paths": record.paths(name), "since": mark.get("since"), "written": record.written(name),
                "state": mark.get("state")}
        result = sync_files(src, dst, last, self.apply, rewrites=rewrites, relink=relink, only=only,
                            pinned=pinned, tmp_suffix=self.tmp_suffix)
        if self.apply:
            if is_repo:
                git(dst, "update-index", "-q", "--refresh")
            if result.failed:
                # The marks stay, so what could not be read or written is
                # looked at again next time.
                written = dict(record.written(name))
                written.update(result.written)
                record.set_paths(name, result.paths, written)
            else:
                marks = dict(mark.get("since") or {})
                if only:
                    marks[only] = [since, since]
                else:
                    marks = {"": [since, since]}
                written = {p: c for p, c in record.written(name).items() if only and not _inside(p, only)}
                written.update(result.written)
                record.set_paths(name, result.paths, written)
                mark.update(since=marks, state=result.state)
        parts = []
        if result.copied:
            parts.append("%d %s from %s" % (result.copied, "copied" if self.apply else "to copy", self.src))
        if result.deleted:
            parts.append("%d %s as in %s" % (result.deleted, "deleted" if self.apply else "to delete", self.src))
        if result.kept:
            parts.append("%d changed in %s only, kept" % (result.kept, self.dst))
        what = "files" if not only else "files in %s/" % only
        self.say("%s: %s: %s" % (name, what, ", ".join(parts) if parts else "nothing new in %s" % self.src))
        for rel, why in result.conflicts[:self.SHOWN]:
            self.problem("%s: kept %s's %s (%s)" % (name, self.dst, rel, why))
        if len(result.conflicts) > self.SHOWN:
            self.problem("%s: and %d more kept as %s has them; the first %d are in %s"
                         % (name, len(result.conflicts) - self.SHOWN, self.dst, LOGGED, tilde(self.log_path)))
        if result.copied or result.deleted or result.conflicts:
            self.log("synced-files", session=name, copied=result.copied, deleted=result.deleted,
                     kept_on_both_sides=[rel for rel, _ in result.conflicts[:LOGGED]],
                     kept_on_both_sides_count=len(result.conflicts))
        return result


def mark_copied(record, name, source, since, state, worktree, is_repo, paths):
    """Note in record a session just copied from source to worktree.

    The copy did not exist while it was made, so nothing in it can be an edit
    made meanwhile: its mark is the moment it is complete.
    """
    mark = record.session(name)
    mark.clear()
    mark.update(source=source, since={"": [since, time.time_ns()]}, state=state)
    if is_repo:
        mark.update(head=head_state(worktree), index=index_digest(worktree))
    record.set_paths(name, paths)
