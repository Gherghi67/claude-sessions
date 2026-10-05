# ABOUTME: Dispatch from 'ags -secrets' to the cs-secrets helper, locating it on disk.
# ABOUTME: Thin wrapper; the secrets logic lives in bin/cs-secrets.

run_secrets() {
    local secrets_script
    secrets_script=$(find_secrets_script) || error "ags-secrets not found. Try reinstalling with: ags -update --force"
    exec "$secrets_script" "$@"
}

# ============================================================================
# SECRETS HELPER
# ============================================================================

# Find the secrets helper script
find_secrets_script() {
    local script_dir
    script_dir="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")"

    for loc in "$script_dir/ags-secrets" "${CS_INSTALL_DIR:-$HOME/.local/bin}/ags-secrets" "/usr/local/bin/ags-secrets" "$script_dir/cs-secrets" "${CS_INSTALL_DIR:-$HOME/.local/bin}/cs-secrets" "/usr/local/bin/cs-secrets"; do
        if [ -x "$loc" ]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

# Create session .gitignore
