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
    [ -e "$meta/local/pre-open" ] && error "$name: .cs/local/pre-open already exists; cs -encrypt writes its own. Move yours aside first."
    container=$(_encrypt_container_path "$name")
    [ -e "$container" ] && error "$name: $container already exists; cs -encrypt will not reuse or overwrite it."
    return 0
}

run_encrypt() {
    [ $# -eq 1 ] || error "Usage: cs -encrypt <name>"
    _encrypt_refuse "$1"
}
