# Secrets Handling

Store sensitive data (API keys, tokens, passwords) in a secure backend instead of writing it into project files in plaintext. Pipe the value on stdin (the recommended path) so it never appears in argv or the command log; a value passed on the command line is honoured but warned against, since it is visible via `ps` and captured verbatim by the bash-logger hook.

## Storage Backends

The `ags -secrets` command auto-detects the best available backend for the platform:

| Backend | Platform | Storage Location | Cross-Machine Sync |
|---------|----------|------------------|-------------------|
| macOS Keychain | macOS | Login keychain | Via export-file |
| Encrypted file | Linux, WSL, and the fallback wherever no keychain is available | `~/.cs-secrets/<session>.enc` | Manual / age |

Override the choice with `CS_SECRETS_BACKEND=keychain|encrypted`. `CS_SECRETS_DIR` moves the encrypted store from `~/.cs-secrets`; the ags profile launcher points it at the profile's own directory.

`ags -list` and the session picker show how many secrets each session holds only while the keychain is the active backend. They read the counts from one keychain dump; the encrypted store would take a decrypt per session, so under it they show no count. `ags <name> -secrets list` names a session's secrets under either backend.

**Encrypted File Backend:**

The encrypted file backend uses AES-256-CBC with PBKDF2 key derivation (100,000 iterations). The encryption key is derived from a machine-specific salt stored in `~/.cs-secrets/.salt`. This provides protection against:
- Casual snooping
- Accidental git commits of the secrets directory
- Backup/sync services copying plaintext credentials

For additional security, set `CS_SECRETS_PASSWORD` to use an explicit master password instead of the auto-derived key.

Check which backend is active: `ags -secrets backend`

## Conversational capture

When you share a secret in chat, Claude invokes the `store-secret` skill to
capture it:
- "Here's my OpenAI key: sk-abc123..."
- "The password is hunter2"
- "Use this token: ghp_xxxx"

Claude picks an appropriate key name, writes the value to a scratch file and
pipes it into `ags -secrets set <name>` on stdin (never on argv), then removes the
scratch file and confirms what was stored.

## Using ags -secrets

The `ags -secrets` command manages session secrets:

```bash
# Check which storage backend is being used
ags -secrets backend

# List all secrets for current session
ags -secrets list

# Get a specific secret value
ags -secrets get API_KEY

# Store a secret manually (value read from stdin, never argv)
printf '%s' "secret-value" | ags -secrets set my_secret

# At a terminal, set prompts for the value without echoing it
ags -secrets set my_secret

# Delete a secret
ags -secrets rm API_KEY

# Delete ALL secrets for a session
ags -secrets purge

# Export all secrets as environment variables. Each is namespaced as
# CS_SECRET_<NAME> (api_key becomes CS_SECRET_API_KEY), so a secret can never
# land on PATH, PROMPT_COMMAND or another variable the shell acts on.
eval "$(ags -secrets export)"

# Use with a specific session
ags -secrets --session my-session list
```

`set` refuses a value that is a placeholder rather than a secret: anything starting with `[REDACTED:`, a run of asterisks, `<redacted>`, or `YOUR_API_KEY`. Storing one would replace a working secret with junk that breaks whatever reads it later.

### No session name?

Run interactively with no session name and `ags -secrets` lists your
sessions and asks which one to use — plain Enter accepts the default when
you are standing inside a session directory (a worktree directory defaults
to its base session). Archived sessions stay out of the list; reach them
with `--session` or by running from inside their directory. Worktree
sessions never appear — they have no secrets of their own; their secrets
live in the base session's store. Scripts and hooks are unaffected: without
a TTY the command still fails with `No session specified`.

## Syncing Secrets Across Machines

There are two ways to sync secrets: **age encryption** (recommended) or **password-based encryption** (legacy).

### Age Encryption (Recommended)

[age](https://github.com/FiloSottile/age) provides modern public-key encryption - no shared password needed:

```bash
# Initialize age (auto-downloads if needed)
ags -secrets age init

# Show your public key (share this with collaborators)
ags -secrets age pubkey

# Export secrets (auto-configures age on first use)
ags -secrets export-file

# Import on another machine (after adding your pubkey as recipient)
ags -secrets import-file
```

**Adding collaborators:**

```bash
# Add a collaborator's public key
ags -secrets age add colleague.pub

# Or add a raw key directly
ags -secrets age add age1abc123...

# List who can decrypt
ags -secrets age list

# Revoke access (re-export to re-encrypt without them)
ags -secrets age remove colleague
```

**How it works:**
- Each machine has a keypair stored in `~/.cs-secrets/age.key`
- Session recipients are stored in `<session>/.cs/age-recipients/*.pub`
- Secrets are encrypted to all recipients' public keys
- Each machine writes its own sync file (see [Per-machine sync files](#per-machine-sync-files) below)
- Anyone with their private key + being in recipients can decrypt

### Password-Based Encryption (Legacy)

For simpler setups or when age isn't available:

```bash
# Set the same password on all machines
export CS_SECRETS_PASSWORD="your-secure-password"

# Export secrets to encrypted file
ags -secrets export-file

# Import secrets from encrypted file
ags -secrets import-file

# Import and overwrite existing secrets
ags -secrets import-file --replace
```

### Per-machine sync files

Sessions are shared between machines via git, so the sync files live under `.cs/`
and are committed. To keep two machines from clobbering each other, **each machine
writes its own sync file**, named after its hostname-derived machine id:

- `.cs/secrets.<machine-id>.age` - age-encrypted (preferred when recipients configured)
- `.cs/secrets.<machine-id>.enc` - password-encrypted (requires `CS_SECRETS_PASSWORD`)

The `<machine-id>` is `${USER}@<short-hostname>` (the same id used to name age
recipients under `.cs/age-recipients/`).

Because every machine exports to a distinct file, concurrent exports produce
*added* files rather than competing edits to one shared file — git merges
additions of different paths without conflict, and no machine's secrets get
silently dropped.

`export-file` also **skips the write when nothing changed**: it decrypts the
existing file and compares the plaintext, so re-exporting an unchanged store
does not churn the file's bytes (each encryption pass would otherwise emit fresh
ciphertext from a random salt / ephemeral key).

`import-file` (with no path argument) **merges every sync file it can decrypt** —
all `.cs/secrets.*.age` / `.cs/secrets.*.enc` from every machine, plus the legacy
unsuffixed `.cs/secrets.age` / `.cs/secrets.enc` (a one-shot migration for
sessions created before per-machine naming). Files it cannot decrypt (another
machine's age key, a different password) are skipped, not fatal. Per-machine
files win key collisions over the legacy files; local secrets are preserved
unless you pass `--replace`.

Passing an explicit path (`ags -secrets import-file <file>`) imports just that
one file, as before.

## Migrating Between Backends

Move secrets from one storage backend to another:

```bash
# Migrate from current backend to encrypted file
ags -secrets migrate-backend encrypted

# Migrate from keychain to encrypted file
ags -secrets migrate-backend encrypted --from keychain

# Migrate and delete from source after successful migration
ags -secrets migrate-backend encrypted --from keychain --delete-source
```

## Migrating Existing Secrets

Sessions created before the secrets feature may hold plaintext secrets in the retired `.cs/artifacts/` directory (cs no longer creates it, but old sessions still have it). Use the migrate command to move them to secure storage:

```bash
# Scan the legacy .cs/artifacts/ files and migrate secrets (keeps originals)
ags -secrets migrate

# Migrate and redact plaintext values in place
ags -secrets migrate --redact
```

The migrate command:
1. Scans the legacy `.cs/artifacts/` files in the session
2. Detects KEY=value patterns with sensitive key names
3. Stores values in the active backend
4. Optionally replaces plaintext with `[REDACTED: stored in keychain as KEY]`

## Age Commands Reference

```bash
# Initialize keypair (auto-downloads age binary if needed)
ags -secrets age init

# Print your public key for sharing
ags -secrets age pubkey

# Add recipient to current session
ags -secrets age add <file.pub|age1...>

# List recipients who can decrypt session secrets
ags -secrets age list

# Remove a recipient (re-export to apply)
ags -secrets age remove <name>
```

## Environment Variables

- `CLAUDE_SESSION_NAME` - Current session (set automatically by `ags`)
- `CS_SECRETS_SESSION` - Overrides the session namespace; worktree feature sessions export it so their secrets land in the base session's store, and `ags <name> -secrets` sets it so an explicit target outranks ambient env
- `CS_SECRETS_BACKEND` - Force a specific backend (`keychain` or `encrypted`)
- `CS_SECRETS_PASSWORD` - Master password for legacy sync (only needed if not using age)
- `CS_SECRETS_LOCK_TIMEOUT` - Seconds to wait for the store lock before giving up (default 10)
