# ABOUTME: cs -encrypt: moves an existing, closed session's private files into an
# ABOUTME: hdiutil-encrypted sparsebundle and links the four vault names into its mount.

# The four names under .cs/ that link into the vault; see docs/session-layout.md
# "Encrypted sessions".
ENCRYPT_VAULT_LINKS="memory plans claude-config private"

# Where the container lives: outside every session directory, so neither
# cs -rm nor the autosave snapshot ever reaches it.
_encrypt_container_path() {  # session_name
    printf '%s/.local/share/cs/vaults/%s.sparsebundle' "$HOME" "$1"
}

# Every precondition, checked before anything is written.
_encrypt_refuse() {  # session_name
    local name="$1" dir meta sub container
    [ "$(uname -s)" = "Darwin" ] || error "cs -encrypt needs macOS (hdiutil); Linux is not supported yet."
    case "$name" in
        *@*) error "$name: encrypt the base session, not a feature worktree." ;;
    esac
    validate_session_name "$name"
    dir="$SESSIONS_ROOT/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || error "No such session: $name"
    [ -L "$dir" ] && error "$name: an adopted session cannot be encrypted; its .cs/ lives in the project checkout."
    cs_interactive || error "cs -encrypt asks for the vault password; run it from a terminal."
    meta="$dir/.cs"
    session_is_live "$meta" && error "$name: the session is running; close it, then encrypt."
    for sub in $ENCRYPT_VAULT_LINKS; do
        [ -L "$meta/$sub" ] && error "$name: .cs/$sub is already a link; the session is encrypted, or half set up by hand."
    done
    # memory and plans move into the vault; these two are only linked, so a
    # real one would take the link inside it and keep its files in plaintext.
    for sub in claude-config private; do
        [ -e "$meta/$sub" ] && error "$name: .cs/$sub already exists and is not a link; cs -encrypt links it into the vault. Move it aside first."
    done
    [ -e "$meta/local/pre-open" ] && error "$name: .cs/local/pre-open already exists; cs -encrypt writes its own. Move yours aside first."
    container=$(_encrypt_container_path "$name")
    [ -e "$container" ] && error "$name: $container already exists; cs -encrypt will not reuse or overwrite it."
    if ! _tags_has_frontmatter "$meta/README.md" || _tags_has_block_style "$meta/README.md"; then
        error "$name: .cs/README.md has no YAML frontmatter to carry the encrypted tag."
    fi
    return 0
}

# Each "source destination" pair to move, source relative to .cs/, destination
# relative to the mount. Only sources that exist are listed.
_encrypt_moves() {  # meta_dir
    local meta="$1" f
    [ -e "$meta/memory" ] && echo "memory memory"
    [ -e "$meta/plans" ] && echo "plans plans"
    for f in $CS_PRIVATE_LOCAL_FILES; do
        [ -e "$meta/local/$f" ] && echo "local/$f private/$f"
    done
    for f in handoffs checkpoints narrative-archive; do
        [ -e "$meta/$f" ] && echo "$f private/$f"
    done
    return 0
}

# Moves one name at a time. A failure stops and names what moved and what did
# not: a rollback would be more moves that can fail the same way.
_encrypt_move_content() {  # session_name, meta_dir
    local name="$1" meta="$2" mnt="$2/vault-mnt" moves src dst moved="" rest
    moves=$(_encrypt_moves "$meta")
    mkdir -p "$mnt/private" "$mnt/claude-config"
    while read -r src dst; do
        [ -n "$src" ] || continue
        if ! mv "$meta/$src" "$mnt/$dst" 2>/dev/null; then
            rest=$(printf '%s\n' "$moves" | awk -v s="$src" 'found || $1 == s { found = 1; printf " .cs/%s", $1 }')
            error "$name: could not move .cs/$src into the vault. Already moved:${moved:- nothing}. Not moved:$rest. The vault is still mounted at .cs/vault-mnt; finish by hand or move those back, then detach it."
        fi
        moved="$moved .cs/$src"
    done <<< "$moves"
    mkdir -p "$mnt/memory" "$mnt/plans"
}

# The hook cs runs before every open: attaches the vault, asking for its
# password each time. A mount whose session is not running is a leftover (a
# crash, or a detach that failed), so it is detached and asked for again.
_encrypt_write_pre_open() {  # meta_dir, container
    local hook="$1/local/pre-open"
    {
        echo '#!/bin/bash'
        echo '# Written by cs -encrypt: mounts this session vault, asking for its password at every open.'
        echo 'set -euo pipefail'
        printf 'container=%q\n' "$2"
        cat <<'EOF'
mkdir -p .cs/vault-mnt
mnt=$(cd .cs/vault-mnt && pwd -P)
mounted() { mount | grep -F " on $mnt (" >/dev/null; }
lock_alive() {
    local pid
    pid=$(tr -d '[:space:]' < .cs/session.lock 2>/dev/null) || return 1
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null
}
if mounted; then
    lock_alive && exit 0
    if [ -f .cs/local/vault-waiter.pid ]; then
        kill "$(cat .cs/local/vault-waiter.pid)" 2>/dev/null || true
        rm -f .cs/local/vault-waiter.pid
    fi
    if ! hdiutil detach "$mnt"; then
        echo "cs: the vault is still mounted from a conversation that ended, and it would not detach. Close whatever holds it, run: hdiutil detach $mnt" >&2
        exit 1
    fi
fi
if ! { [ -t 0 ] || [ "${CS_ASSUME_TTY:-}" = "1" ]; }; then
    echo "cs: this session is encrypted and needs a terminal to ask for the vault password." >&2
    exit 1
fi
hdiutil attach -nobrowse -mountpoint "$mnt" "$container"
EOF
    } > "$hook"
    chmod +x "$hook"
}

# The mountpoint of a vault this cs run's pre-open mounted. An open that stops
# before exec'ing claude (a refusal, or a cancelled prompt) detaches it on the
# way out; exec replaces cs and drops the EXIT trap, so claude keeps it.
CS_OPENED_VAULT_MNT=""

_arm_vault_detach() {  # session_dir
    local meta="$1/.cs" mnt
    [ -f "$meta/local/vault" ] || return 0
    # pre-open joined the mount a running conversation holds; not ours to detach.
    session_is_live "$meta" && return 0
    mnt=$(cd "$meta/vault-mnt" 2>/dev/null && pwd -P) || return 0
    mount | grep -F " on $mnt (" >/dev/null || return 0
    CS_OPENED_VAULT_MNT="$mnt"
    trap _detach_opened_vault EXIT
}

_detach_opened_vault() {
    [ -n "$CS_OPENED_VAULT_MNT" ] || return 0
    hdiutil detach "$CS_OPENED_VAULT_MNT" >/dev/null 2>&1 \
        || warn "The vault is still mounted at $CS_OPENED_VAULT_MNT; the next open detaches it, or run: hdiutil detach $CS_OPENED_VAULT_MNT"
}

run_encrypt() {
    [ $# -eq 1 ] || error "Usage: cs -encrypt <name>"
    local name="$1" meta container mnt sub
    _encrypt_refuse "$name"
    meta="$SESSIONS_ROOT/$name/.cs"
    mnt="$meta/vault-mnt"
    container=$(_encrypt_container_path "$name")

    mkdir -p "$(dirname "$container")"
    info "Creating the encrypted container; hdiutil asks for the new password."
    hdiutil create -size 50g -type SPARSEBUNDLE -fs APFS -encryption AES-256 \
        -volname "cs-$name" "$container" \
        || error "$name: hdiutil create failed; the session is unchanged."
    mkdir -p "$mnt"
    info "Mounting it; hdiutil asks for the password again."
    if ! hdiutil attach -nobrowse -mountpoint "$mnt" "$container"; then
        rmdir "$mnt" 2>/dev/null || true
        error "$name: hdiutil could not attach $container; the session is unchanged. Delete the container before retrying."
    fi
    # Spotlight indexing holds files open and turns a detach busy.
    touch "$mnt/.metadata_never_index"

    _encrypt_move_content "$name" "$meta"
    for sub in $ENCRYPT_VAULT_LINKS; do
        ln -s "vault-mnt/$sub" "$meta/$sub"
    done
    _encrypt_write_pre_open "$meta" "$container"
    printf '%s\n' "$container" > "$meta/local/vault"
    ( CLAUDE_SESSION_META_DIR="$meta" _tag_mutate add encrypted ) \
        || error "$name: the vault is built but the encrypted tag could not be written; add it with cs $name -tag add encrypted."

    hdiutil detach "$mnt" \
        || error "$name: encrypted, but the vault would not detach; run hdiutil detach $mnt before opening it."
    info "$name is encrypted. Every open asks for the vault password; the vault detaches when the last conversation ends."
    echo "cs could not move copies made before today; remove them by hand if they matter:"
    echo "  - this session's transcripts in ~/.claude/projects/"
    echo "  - its lines in ~/.claude/history.jsonl"
    echo "  - its project entries in ~/.claude.json and that file's backups"
    echo "  - .cs/summary.md and .cs/brief.md, which stay plaintext"
    echo "  - git history of anything committed before, and backups or snapshots"
}
