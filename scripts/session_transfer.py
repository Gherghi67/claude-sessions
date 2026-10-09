# ABOUTME: Helpers shared by ags-to-cs.py and cs-to-ags.py, which carry sessions between the stable cs and ags.
# ABOUTME: Claude folder names, open-session checks, the append-only transcript merge and the protocol wording.
"""What both directions of a session transfer need.

The two scripts copy the same kinds of things in opposite directions: Claude
Code's transcript folders, the session protocol in CLAUDE.local.md, and
secrets. Their rules live here so the two cannot drift apart.
"""

import ctypes
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile

# ags's session protocol says ags where the stable cs's says cs; nothing else
# in the template differs. Only lines from the first cs sentinel on are
# reworded, so text the user wrote above the protocol stays as it is.
AGS_TO_CS_WORDING = (
    ("managed by agent-sessions (ags).", "managed by the cs tool."),
    ("`ags -", "`cs -"),
    ("$(ags -", "$(cs -"),
    ("the ags session store", "the cs session store"),
    ("(ags redirects via", "(cs redirects via"),
    ("tombstone — ags treats", "tombstone — cs treats"),
    ("ags does not copy your first prompt", "cs does not copy your first prompt"),
)


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


def reword_protocol(text, wording):
    lines = text.split("\n")
    start = next((i for i, line in enumerate(lines) if "<!-- cs:" in line), None)
    if start is None:
        return text
    for i in range(start, len(lines)):
        for old, new in wording:
            lines[i] = lines[i].replace(old, new)
    return "\n".join(lines)


def scrubbed_env():
    """The caller's environment without what an ags or cs session exports."""
    env = {}
    for key, value in os.environ.items():
        if key.startswith(("CS_", "AGS_", "CLAUDE_SESSION_")):
            continue
        if key in ("CLAUDE_CONFIG_DIR", "CODEX_HOME", "CLAUDE_SECURESTORAGE_CONFIG_DIR"):
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
