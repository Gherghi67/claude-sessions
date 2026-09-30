#!/usr/bin/env bash
# ABOUTME: Tests for auto memory directory redirect into .cs/memory/
# ABOUTME: Validates settings.local.json creation, gitignore, and migration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"

# Override teardown to also unset session env vars
teardown() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset CS_SESSIONS_ROOT CLAUDE_CODE_BIN
    unset CLAUDE_SESSION_NAME CLAUDE_SESSION_DIR CLAUDE_SESSION_META_DIR 2>/dev/null || true
}

# ============================================================================
# Tests
# ============================================================================

test_new_session_creates_memory_dir() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created" || return 1
}

test_new_session_creates_settings_local() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_exists "$session_dir/.claude/settings.local.json" "settings.local.json should exist" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" "autoMemoryDirectory" \
        "settings.local.json should contain autoMemoryDirectory" || return 1
    assert_file_contains "$session_dir/.claude/settings.local.json" ".cs/memory" \
        "autoMemoryDirectory should point to .cs/memory" || return 1
}

# A hand-edited settings.local.json that jq cannot parse must survive the merge.
# Redirecting jq's output straight onto the file truncates it before jq reads it,
# so a single trailing comma costs the user every setting in the file — and the
# damage is permanent, since jq on empty input succeeds and writes nothing.
test_unparseable_settings_local_survives_merge() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local settings="$CS_SESSIONS_ROOT/test-session/.claude/settings.local.json"
    printf '%s' '{ "permissions": { "allow": ["Bash(ls:*)"] }, }' > "$settings"
    local before
    before=$(cat "$settings")
    # Phase 4 only re-runs the merge when memory, plans or settings is missing.
    # A session predating plansDirectory is the state that reaches it with a
    # settings file already on disk.
    rm -rf "$CS_SESSIONS_ROOT/test-session/.cs/plans"

    # stdout only: create_worktree_session returns its directory by echoing it
    # and lib/99-main.sh captures that, so a complaint on stdout would land
    # inside a worktree session's path.
    local out
    out=$("$CS_BIN" test-session <<< "" 2>/dev/null) || true

    local after
    after=$(cat "$settings")
    assert_eq "$before" "$after" "unparseable settings.local.json must be left intact" || return 1
    if [ -e "$settings.tmp" ]; then
        echo "  FAIL: left $settings.tmp behind"
        return 1
    fi
    assert_output_not_contains "$out" "Could not parse" \
        "the complaint belongs on stderr, where a command substitution cannot capture it" || return 1
    # The absence above is only half the contract: with the warn deleted
    # entirely it still holds, and the user is then left with a settings file cs
    # silently declined to touch. Pin that it is actually SAID, on stderr.
    rm -rf "$CS_SESSIONS_ROOT/test-session/.cs/plans"
    printf '%s' '{ "permissions": { "allow": ["Bash(ls:*)"] }, }' > "$settings"
    local err
    err=$("$CS_BIN" test-session <<< "" 2>&1 >/dev/null) || true
    assert_output_contains "$err" "Could not parse" \
        "cs must say it left the file alone, not decline in silence" || return 1
}

test_settings_local_is_gitignored() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local session_dir="$CS_SESSIONS_ROOT/test-session"
    assert_file_contains "$session_dir/.gitignore" ".claude/settings.local.json" \
        ".gitignore should exclude settings.local.json" || return 1
}

test_adopt_creates_memory_dir() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_dir "$project_dir/.cs/memory" ".cs/memory/ should be created on adopt" || return 1
    assert_exists "$project_dir/.claude/settings.local.json" \
        "settings.local.json should exist on adopt" || return 1
}

test_adopt_adds_settings_to_gitignore() {
    local project_dir="$TEST_TMPDIR/my-project"
    mkdir -p "$project_dir"

    (cd "$project_dir" && git init -q && echo "node_modules/" > .gitignore && git add -A && git commit -q -m "init")

    (cd "$project_dir" && "$CS_BIN" -adopt my-session) 2>&1

    assert_file_contains "$project_dir/.gitignore" ".claude/settings.local.json" \
        "Existing .gitignore should get settings.local.json entry" || return 1
}

test_migration_creates_memory_and_settings() {
    local session_dir="$CS_SESSIONS_ROOT/old-session"
    mkdir -p "$session_dir/.cs/local"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" old-session <<< "" 2>&1 || true

    assert_dir "$session_dir/.cs/memory" ".cs/memory/ should be created on migration" || return 1
    assert_exists "$session_dir/.claude/settings.local.json" \
        "settings.local.json should be created on migration" || return 1
}

test_migration_moves_existing_auto_memory() {
    local session_dir="$CS_SESSIONS_ROOT/mem-session"
    mkdir -p "$session_dir/.cs/local"
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    local real_path
    real_path="$(cd "$session_dir" && pwd -P)"
    local encoded_path
    encoded_path=$(echo "$real_path" | sed 's|/|-|g; s|\.|-|g')
    local old_memory_dir="$HOME/.claude/projects/${encoded_path}/memory"
    mkdir -p "$old_memory_dir"
    echo "build command: cargo test" > "$old_memory_dir/MEMORY.md"
    echo "debug notes here" > "$old_memory_dir/debugging.md"

    "$CS_BIN" mem-session <<< "" 2>&1 || true

    assert_exists "$session_dir/.cs/memory/MEMORY.md" \
        "MEMORY.md should be migrated to .cs/memory/" || return 1
    assert_file_contains "$session_dir/.cs/memory/MEMORY.md" "cargo test" \
        "MEMORY.md content should be preserved" || return 1
    assert_exists "$session_dir/.cs/memory/debugging.md" \
        "debugging.md should be migrated to .cs/memory/" || return 1

    if [[ -d "$old_memory_dir" ]] && [[ "$(ls -A "$old_memory_dir" 2>/dev/null)" ]]; then
        echo "  FAIL: old memory dir should be empty after migration"
        return 1
    fi

    rm -rf "$HOME/.claude/projects/${encoded_path}" 2>/dev/null || true
}

# ============================================================================
# Frontmatter migration for old sessions
# ============================================================================

# Helper: create an old-style session (no frontmatter in README)
create_old_session() {
    local name="$1"
    local session_dir="$CS_SESSIONS_ROOT/$name"
    mkdir -p "$session_dir/.cs"/{local,memory}
    # Old README.md: no frontmatter, starts with heading
    cat > "$session_dir/.cs/README.md" << 'EOF'
# Session: test-old

**Started:** 2026-03-15 10:30:00
**Location:** macbook:~/projects

## Objective

Fix the database connection pooling issue

## Environment

Production PostgreSQL server

## Outcome

[pending]
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q -b main && git config user.email t@t && git config user.name T && git add -A && git commit -q -m "init")
}

test_migration_adds_frontmatter_to_old_readme() {
    create_old_session "test-old"
    # Verify no frontmatter before migration
    local first_line
    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "# Session: test-old" "$first_line" "Old README should not have frontmatter" || return 1

    # Open session to trigger migration
    "$CS_BIN" test-old <<< "" 2>&1 || true

    first_line=$(head -1 "$CS_SESSIONS_ROOT/test-old/.cs/README.md")
    assert_eq "---" "$first_line" "Migrated README should have frontmatter" || return 1
}

test_migration_preserves_existing_content() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "database connection pooling" \
        "Migration should preserve objective text" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "Production PostgreSQL" \
        "Migration should preserve environment text" || return 1
}

test_migration_derives_created_date() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should derive created date from the "Started:" line (2026-03-15)
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" "created: 2026-03-15" \
        "Should derive created date from Started line" || return 1
}

test_migration_adds_aliases_from_session_name() {
    create_old_session "test-old"
    "$CS_BIN" test-old <<< "" 2>&1 || true

    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'aliases:' \
        "Should add aliases" || return 1
    assert_file_contains "$CS_SESSIONS_ROOT/test-old/.cs/README.md" 'test-old' \
        "Aliases should contain session name" || return 1
}

test_migration_skips_if_frontmatter_exists() {
    create_old_session "test-old"
    # Manually add frontmatter
    local readme="$CS_SESSIONS_ROOT/test-old/.cs/README.md"
    local content
    content=$(cat "$readme")
    {
        echo "---"
        echo "status: completed"
        echo "created: 2026-01-01"
        echo "tags: [custom]"
        echo 'aliases: ["my-custom-alias"]'
        echo "---"
        echo "$content"
    } > "$readme"

    "$CS_BIN" test-old <<< "" 2>&1 || true

    # Should NOT overwrite existing frontmatter
    assert_file_contains "$readme" "status: completed" \
        "Should preserve existing status" || return 1
    assert_file_contains "$readme" "created: 2026-01-01" \
        "Should preserve existing created date" || return 1
    assert_file_contains "$readme" "my-custom-alias" \
        "Should preserve existing aliases" || return 1
}

# ============================================================================
# Session narrative topic file (narrative.md) — relocation of discoveries
# ============================================================================

test_new_session_creates_narrative_file() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$CS_SESSIONS_ROOT/test-session/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_exists "$narrative" "a per-actor narrative file should be created in .cs/memory/" || return 1
    assert_file_contains "$narrative" "type: narrative" \
        "narrative should carry the narrative type" || return 1
}

test_new_session_adds_narrative_pointer() {
    "$CS_BIN" test-session <<< "" 2>&1 || true

    local index="$CS_SESSIONS_ROOT/test-session/.cs/memory/MEMORY.md"
    assert_file_contains "$index" "](narrative." \
        "MEMORY.md should carry a pointer to the per-actor narrative" || return 1
}

test_narrative_pointer_idempotent_readd() {
    "$CS_BIN" test-session <<< "" 2>&1 || true
    local session_dir="$CS_SESSIONS_ROOT/test-session"
    # Simulate the harness regenerating MEMORY.md and dropping the pointer
    : > "$session_dir/.cs/memory/MEMORY.md"
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m init 2>/dev/null) || true

    "$CS_BIN" test-session <<< "" 2>&1 || true

    local index="$session_dir/.cs/memory/MEMORY.md"
    assert_file_contains "$index" "](narrative." \
        "Dropped narrative pointer should be re-added on resume" || return 1
    # Must not duplicate when already present
    local count
    count=$(grep -c '](narrative\.' "$index")
    assert_eq "1" "$count" "narrative pointer should appear exactly once" || return 1
}

test_resume_folds_discoveries_into_narrative() {
    local session_dir="$CS_SESSIONS_ROOT/disc-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## A real finding worth keeping
The widget frobnicator needs a retry on EAGAIN.
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" disc-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "frobnicator needs a retry on EAGAIN" \
        "discoveries content should be folded into the narrative on resume" || return 1
    # One-shot: the original is consumed so it is not re-folded
    if [ -f "$session_dir/.cs/discoveries.md" ]; then
        echo "  FAIL: discoveries.md should be consumed after fold"
        return 1
    fi
}

test_discoveries_fold_header_uses_git_date() {
    # The fold header date must come from shared git history, not the local
    # clock — two machines folding the same legacy discoveries.md on
    # different days would otherwise write divergent blocks into the same
    # tracked narrative and conflict on merge.
    local session_dir="$CS_SESSIONS_ROOT/disc-dated"
    mkdir -p "$session_dir/.cs"/{local,memory}
    cat > "$session_dir/.cs/discoveries.md" << 'EOF'
# Discoveries & Notes

## A dated finding
Dated content.
EOF
    echo "# Session" > "$session_dir/CLAUDE.md"
    (cd "$session_dir" && git init -q && git config user.email t@t \
        && git config user.name T && git add -A \
        && GIT_AUTHOR_DATE="2026-01-15T09:00:00" GIT_COMMITTER_DATE="2026-01-15T09:00:00" \
           git commit -q -m init)

    "$CS_BIN" disc-dated <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "Folded from discoveries.md (2026-01-15)" \
        "fold header should carry the git date of discoveries.md, not today" || return 1
}

test_resume_folds_compact_when_discoveries_header_only() {
    local session_dir="$CS_SESSIONS_ROOT/compact-session"
    mkdir -p "$session_dir/.cs"/{local,memory}
    # Active file is header-only, but the compact companion holds real content
    printf '# Discoveries & Notes\n\n' > "$session_dir/.cs/discoveries.md"
    cat > "$session_dir/.cs/discoveries.compact.md" << 'EOF'
## Condensed finding from an earlier compaction
The cache must be invalidated on tenant switch.
EOF
    cat > "$session_dir/CLAUDE.md" << 'EOF'
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.
EOF
    (cd "$session_dir" && git init -q && git add -A && git commit -q -m "init")

    "$CS_BIN" compact-session <<< "" 2>&1 || true

    local narrative
    narrative=$(ls "$session_dir/.cs/memory/"narrative.*.md 2>/dev/null | head -1)
    assert_file_contains "$narrative" "invalidated on tenant switch" \
        "compact.md content must be folded even when discoveries.md is header-only" || return 1
    if [ -f "$session_dir/.cs/discoveries.compact.md" ]; then
        echo "  FAIL: discoveries.compact.md should be consumed after fold"
        return 1
    fi
}

# ============================================================================
# Encrypted storage: .cs/memory and .cs/plans as symlinks into a mountpoint
# ============================================================================

# A session whose memory and plans live on an encrypted volume mounted at
# .cs/vault-mnt, the layout session `rel` uses. Unmounting removes the
# mountpoint, which leaves both symlinks dangling.
_make_vaulted_session() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    "$CS_BIN" "$1" <<< "" >/dev/null 2>&1 || true
    mkdir -p "$meta/vault-mnt"
    mv "$meta/memory" "$meta/vault-mnt/memory"
    mv "$meta/plans" "$meta/vault-mnt/plans"
    ln -s "$meta/vault-mnt/memory" "$meta/memory"
    ln -s "$meta/vault-mnt/plans" "$meta/plans"
}

# Records each launch, so a test can tell a refusal from a launch.
_make_launch_sentinel() {
    printf '#!/bin/bash\necho launched >> "%s"\n' "$TEST_TMPDIR/launched" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude"
}

test_unmounted_storage_refuses_open() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/memory points at $meta/vault-mnt/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling link and nothing else" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
    assert_not_exists "$meta/vault-mnt" "nothing may be created where the volume mounts" || return 1
}

# Writes .cs/local/pre-open with the given body and makes it executable.
_write_pre_open() {  # session, body
    local hook="$CS_SESSIONS_ROOT/$1/.cs/local/pre-open"
    printf '#!/bin/bash\n%s\n' "$2" > "$hook"
    chmod +x "$hook"
}

test_pre_open_mounts_then_session_opens() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _write_pre_open vt "pwd -P > \"$TEST_TMPDIR/pre-open-cwd\"; mv \"$TEST_TMPDIR/unmounted\" .cs/vault-mnt"
    _make_launch_sentinel

    local rc=0
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "cs should open once pre-open mounted the storage" || return 1
    assert_eq "launched" "$(cat "$TEST_TMPDIR/launched" 2>/dev/null)" "claude should launch once" || return 1
    assert_eq "$(cd "$CS_SESSIONS_ROOT/vt" && pwd -P)" "$(cat "$TEST_TMPDIR/pre-open-cwd")" \
        "pre-open should run in the session directory" || return 1
}

test_pre_open_failure_aborts_open() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "exit 3"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/local/pre-open exited 3; not opening the session." "$out" \
        "cs should name the failed pre-open and its status" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_pre_open_not_executable_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "exit 0"
    chmod -x "$CS_SESSIONS_ROOT/vt/.cs/local/pre-open"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/local/pre-open is not executable; chmod +x it, or remove it." "$out" \
        "cs should refuse a pre-open it cannot run rather than skip it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# .cs/local/ is gitignored, but `git add -f` can still commit a file there, and
# a clone then checks it out. A committed pre-open would run code from whoever
# wrote the repo, so cs refuses one git tracks.
test_pre_open_tracked_by_git_is_refused() {
    "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true
    _write_pre_open vt "touch \"$TEST_TMPDIR/pre-open-ran\""
    git -C "$CS_SESSIONS_ROOT/vt" add -f .cs/local/pre-open
    git -C "$CS_SESSIONS_ROOT/vt" commit -q -m "track pre-open"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: .cs/local/ is tracked in git (per-actor state must stay local). Fix with: git -C \"$CS_SESSIONS_ROOT/vt\" rm -r --cached .cs/local && git commit -m 'stop tracking .cs/local'" \
        "$out" "cs should refuse a committed .cs/local before running anything in it" || return 1
    assert_file_not_exists "$TEST_TMPDIR/pre-open-ran" "the committed pre-open must not run" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

test_pre_open_success_without_mount_still_refuses() {
    _make_vaulted_session vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _write_pre_open vt "exit 0"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/memory points at $meta/vault-mnt/memory, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "the dangling-link refusal should still fire" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A session whose Claude Code config lives on its encrypted volume: .cs/claude-config
# is a symlink into vault-mnt, the same shape as memory and plans.
_make_vaulted_config() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$meta/vault-mnt/claude-config"
    ln -s "$meta/vault-mnt/claude-config" "$meta/claude-config"
}

# Records the Claude Code config variables each launch sees; "unset" when absent.
_make_config_sentinel() {
    cat > "$TEST_TMPDIR/claude" <<EOF
#!/bin/bash
echo "config=\${CLAUDE_CONFIG_DIR-unset} secure=\${CLAUDE_SECURESTORAGE_CONFIG_DIR-unset}" >> "$TEST_TMPDIR/launched"
EOF
    chmod +x "$TEST_TMPDIR/claude"
    export CLAUDE_CODE_BIN="$TEST_TMPDIR/claude"
}

test_claude_config_link_moves_claude_code_into_the_vault() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    local rc=0
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc=$?

    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq "config=$CS_SESSIONS_ROOT/vt/.cs/claude-config secure=" "$(cat "$TEST_TMPDIR/launched")" \
        "claude should keep its config in the vault and its login in the default keychain entry" || return 1
}

# A cs launched from inside an encrypted session inherits that session's config
# variables; the session it opens has no vault, so it must get the shell's
# config, not the parent's vault. A config dir the user set themselves is theirs.
test_session_without_claude_config_drops_an_inherited_vault_config() {
    "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    _make_config_sentinel

    CLAUDE_CONFIG_DIR="$TEST_TMPDIR/other/.cs/claude-config" CLAUDE_SECURESTORAGE_CONFIG_DIR="" \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true
    CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" plain <<< "" >/dev/null 2>&1 || true

    assert_eq "config=unset secure=unset
config=$TEST_TMPDIR/profile-b secure=unset" "$(cat "$TEST_TMPDIR/launched")" \
        "an inherited vault config is dropped; the user's own config dir is kept" || return 1
}

# Under a non-default profile the login lives in that profile's keychain entry.
test_claude_config_link_keeps_the_shell_profile_login() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq "config=$CS_SESSIONS_ROOT/vt/.cs/claude-config secure=$TEST_TMPDIR/profile-b" \
        "$(cat "$TEST_TMPDIR/launched")" "the keychain entry follows the shell's profile" || return 1
}

test_unmounted_claude_config_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    # memory and plans stay reachable, so the refusal can only come from claude-config.
    mkdir -p "$TEST_TMPDIR/elsewhere"
    mv "$meta/vault-mnt/memory" "$meta/vault-mnt/plans" "$TEST_TMPDIR/elsewhere/"
    rm "$meta/memory" "$meta/plans"
    ln -s "$TEST_TMPDIR/elsewhere/memory" "$meta/memory"
    ln -s "$TEST_TMPDIR/elsewhere/plans" "$meta/plans"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/claude-config points at $meta/vault-mnt/claude-config, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling config link" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch with its config unmounted" || return 1
}

# Opens vt, with its config in the vault, from a shell with no config variables.
_open_vaulted_config_session() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1
}

# The vault config shares the user's settings, instructions and extensions with
# ~/.claude, so an encrypted session runs with the same hooks, skills and plugins.
test_claude_config_links_the_shared_config() {
    mkdir -p "$HOME/.claude/skills/demo"
    printf '{"model":"base"}\n' > "$HOME/.claude/settings.json"

    local rc=0
    _open_vaulted_config_session || rc=$?

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq "$HOME/.claude/settings.json" "$(readlink "$config/settings.json")" \
        "settings.json should link to the shell's config" || return 1
    assert_eq "$HOME/.claude/skills" "$(readlink "$config/skills")" \
        "skills should link to the shell's config" || return 1
}

# Under a non-default profile the shared config is that profile's.
test_claude_config_links_the_shell_profile_config() {
    mkdir -p "$HOME/.claude" "$TEST_TMPDIR/profile-b"
    printf '{"model":"home"}\n' > "$HOME/.claude/settings.json"
    printf '{"model":"profile-b"}\n' > "$TEST_TMPDIR/profile-b/settings.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq "$TEST_TMPDIR/profile-b/settings.json" \
        "$(readlink "$CS_SESSIONS_ROOT/vt/.cs/claude-config/settings.json")" \
        "settings.json should link to the profile's config, not ~/.claude" || return 1
}

# A link to an entry the shell's config lacks would dangle.
test_claude_config_skips_what_the_shell_config_lacks() {
    mkdir -p "$HOME/.claude"
    printf '{}\n' > "$HOME/.claude/settings.json"

    _open_vaulted_config_session || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "settings.json" "$(ls -A "$config")" \
        "only the entry the shell's config has should be linked" || return 1
}

# The session may keep its own settings, or a link it made by hand; and a
# second launch finds its own links already there.
test_claude_config_keeps_its_own_entries() {
    mkdir -p "$HOME/.claude/skills"
    printf '{"model":"base"}\n' > "$HOME/.claude/settings.json"
    printf '{}\n' > "$HOME/.claude/keybindings.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    printf '{"model":"own"}\n' > "$config/settings.json"
    ln -s "$TEST_TMPDIR/gone" "$config/keybindings.json"
    _make_launch_sentinel

    local rc1=0 rc2=0
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc1=$?
    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || rc2=$?

    assert_eq "0 0" "$rc1 $rc2" "both launches should open the session" || return 1
    assert_eq "launched
launched" "$(cat "$TEST_TMPDIR/launched")" "claude should launch twice" || return 1
    assert_eq '{"model":"own"}' "$(cat "$config/settings.json")" \
        "the session's own settings should be kept" || return 1
    assert_eq "$TEST_TMPDIR/gone" "$(readlink "$config/keybindings.json")" \
        "a link the session already has should be kept" || return 1
}

# What Claude Code writes about conversations is the leak the vault closes;
# linking it back to ~/.claude would reopen it.
test_claude_config_never_links_conversation_state() {
    mkdir -p "$HOME/.claude/projects" "$HOME/.claude/backups" "$HOME/.claude/todos"
    printf '{}\n' > "$HOME/.claude/history.jsonl"

    _open_vaulted_config_session || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "" "$(ls -A "$config")" \
        "no conversation state should be shared with the shell's config" || return 1
}

# The vault's .claude.json starts as a copy of the shell's, so onboarding and
# preferences carry over, minus every project's record: each one keeps that
# project's last prompt in plaintext.
test_claude_config_seeds_claude_json_without_projects() {
    printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{"/p":{"lastSessionFirstPrompt":"private words"}}}' \
        > "$HOME/.claude.json"

    local rc=0
    _open_vaulted_config_session || rc=$?

    local seeded="$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json"
    assert_eq "0" "$rc" "cs should open the session" || return 1
    assert_eq '{"hasCompletedOnboarding":true,"projects":{}}' "$(jq -c . "$seeded")" \
        "the copy should keep the settings and drop every project" || return 1
    assert_eq "$seeded" "$(find "$seeded" -perm 600)" "the copy should be readable by its owner only" || return 1
}

# Claude Code keeps .claude.json in $HOME by default, but inside the config dir
# when CLAUDE_CONFIG_DIR is set; the copy comes from wherever the shell's is.
test_claude_config_seeds_the_shell_profile_claude_json() {
    mkdir -p "$TEST_TMPDIR/profile-b"
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    printf '{"from":"profile-b"}\n' > "$TEST_TMPDIR/profile-b/.claude.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel

    env -u CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CONFIG_DIR="$TEST_TMPDIR/profile-b" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq '{"from":"profile-b","projects":{}}' \
        "$(jq -c . "$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json")" \
        "the copy should come from the profile's .claude.json" || return 1
}

# A cs launched from inside another encrypted session inherits that session's
# vault as CLAUDE_CONFIG_DIR; sharing from it would tie this vault to that one.
test_claude_config_shares_from_the_shell_config_not_an_inherited_vault() {
    local other="$TEST_TMPDIR/other/.cs/claude-config"
    mkdir -p "$other" "$HOME/.claude"
    printf '{"model":"other"}\n' > "$other/settings.json"
    printf '{"from":"other"}\n' > "$other/.claude.json"
    printf '{"model":"home"}\n' > "$HOME/.claude/settings.json"
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_config_sentinel

    CLAUDE_CONFIG_DIR="$other" CLAUDE_SECURESTORAGE_CONFIG_DIR="" \
        "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    local config="$CS_SESSIONS_ROOT/vt/.cs/claude-config"
    assert_eq "$HOME/.claude/settings.json" "$(readlink "$config/settings.json")" \
        "settings.json should link to the shell's config" || return 1
    assert_eq '{"from":"home","projects":{}}' "$(jq -c . "$config/.claude.json")" \
        "the copy should come from the shell's .claude.json" || return 1
    assert_eq "config=$config secure=" "$(cat "$TEST_TMPDIR/launched")" \
        "claude should run on this vault and the default login" || return 1
}

# A session whose cs files (command log, mail, traces) live on its encrypted
# volume: .cs/private links into vault-mnt. The log cs wrote at creation is
# moved in, as a migration would.
_make_vaulted_private() {  # name
    local meta="$CS_SESSIONS_ROOT/$1/.cs"
    mkdir -p "$meta/vault-mnt/private"
    mv "$meta/local/session.log" "$meta/vault-mnt/private/session.log"
    ln -s "$meta/vault-mnt/private" "$meta/private"
}

test_private_link_session_opens() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "0" "$rc" "cs should open the session: $out" || return 1
    assert_eq "launched" "$(cat "$TEST_TMPDIR/launched")" "claude should launch once" || return 1
    assert_file_not_exists "$CS_SESSIONS_ROOT/vt/.cs/local/session.log" \
        "the open must not write a plaintext log" || return 1
}

test_unmounted_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    # memory and plans stay reachable, so the refusal can only come from private.
    mkdir -p "$TEST_TMPDIR/elsewhere"
    mv "$meta/vault-mnt/memory" "$meta/vault-mnt/plans" "$TEST_TMPDIR/elsewhere/"
    rm "$meta/memory" "$meta/plans"
    ln -s "$TEST_TMPDIR/elsewhere/memory" "$meta/memory"
    ln -s "$TEST_TMPDIR/elsewhere/plans" "$meta/plans"
    mv "$meta/vault-mnt" "$TEST_TMPDIR/unmounted"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private points at $meta/vault-mnt/private, which is missing (encrypted storage not mounted?). Mount it, then reopen." \
        "$out" "cs should name the dangling private link" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# Once a session keeps its cs files in the vault, a copy left in .cs/local is
# plaintext the vault was meant to hold; cs names it rather than open beside it.
test_plaintext_left_beside_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    printf 'old log\n' > "$meta/local/session.log"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds session.log in plaintext. Move it into .cs/private or delete it, then reopen." \
        "$out" "cs should name the plaintext file" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# A mailbox is a directory, not a file: a plaintext one left in .cs/local is
# named the same way, whatever it holds.
test_plaintext_mailbox_left_beside_private_refuses_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs"
    mkdir -p "$meta/local/mail/cur"
    _make_launch_sentinel

    local out rc=0
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?

    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds mail in plaintext. Move it into .cs/private or delete it, then reopen." \
        "$out" "cs should name the plaintext mailbox" || return 1
    assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
}

# The queue, its inbox, the traces and the pending-handoff marker are cs
# files too: each one left in .cs/local is named the same way.
test_plaintext_queue_files_left_beside_private_refuse_open() {
    _make_vaulted_session vt
    _make_vaulted_private vt
    local meta="$CS_SESSIONS_ROOT/vt/.cs" name out rc
    for name in queue queue.tmp queue.state queue.done queue.declined queue.migrating \
                notifications.jsonl notifications.seen failures rewrite.trace pending-handoff; do
        case "$name" in queue|queue.tmp) mkdir -p "$meta/local/$name" ;; *) printf 'x\n' > "$meta/local/$name" ;; esac
        rc=0
        out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
        assert_eq "1" "$rc" "cs should exit 1 on $name" || return 1
        assert_eq "Error: vt: .cs/private keeps this session's cs files in its vault, but .cs/local still holds $name in plaintext. Move it into .cs/private or delete it, then reopen." \
            "$out" "cs should name $name" || return 1
        rm -rf "${meta:?}/local/$name"
    done
}

# A regular file where a vault link belongs is neither a vault nor a place
# cs can write; the open names it rather than treat the session as locked.
test_a_file_at_a_vault_link_refuses_open() {
    _make_vaulted_session vt
    _make_launch_sentinel
    local meta="$CS_SESSIONS_ROOT/vt/.cs" out rc=0
    printf 'not a vault\n' > "$meta/private"
    out=$("$CS_BIN" vt <<< "" 2>&1) || rc=$?
    assert_eq "1" "$rc" "cs should exit 1" || return 1
    assert_eq "Error: vt: .cs/private is a file, not a directory or a link into encrypted storage. Remove it, or link it into the vault, then reopen." \
        "$out" "cs should name the file" || return 1
    assert_not_exists "$TEST_TMPDIR/launched" "claude never starts" || return 1
}

# After the first launch the session's .claude.json is Claude Code's to write.
test_claude_config_seeds_claude_json_once() {
    printf '{"from":"home"}\n' > "$HOME/.claude.json"
    _open_vaulted_config_session || true
    local seeded="$CS_SESSIONS_ROOT/vt/.cs/claude-config/.claude.json"
    printf '{"from":"session"}\n' > "$seeded"

    env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" >/dev/null 2>&1 || true

    assert_eq '{"from":"session"}' "$(jq -c . "$seeded")" \
        "a second launch should keep the session's own .claude.json" || return 1
}

# Without a readable copy Claude Code would start the session as a fresh
# install; an empty file is the case jq alone lets through.
test_claude_config_refuses_an_unreadable_claude_json() {
    _make_vaulted_session vt
    _make_vaulted_config vt
    _make_launch_sentinel
    local content out rc
    for content in '{"projects": {,}' ''; do
        printf '%s' "$content" > "$HOME/.claude.json"

        rc=0
        out=$(env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$CS_BIN" vt <<< "" 2>&1) || rc=$?

        assert_eq "1" "$rc" "cs should exit 1 for '$content'" || return 1
        # The line before it is the stale-lock notice the fixture's own
        # creating launch leaves behind.
        assert_eq "Error: $HOME/.claude.json is not a JSON object cs can copy into $CS_SESSIONS_ROOT/vt/.cs/claude-config; fix it, then reopen." \
            "$(tail -n 1 <<< "$out")" "cs should name the source it cannot copy" || return 1
        assert_file_not_exists "$TEST_TMPDIR/launched" "claude must not launch" || return 1
        assert_eq "" "$(ls -A "$CS_SESSIONS_ROOT/vt/.cs/claude-config")" \
            "nothing should be left in the session's config" || return 1
    done
}

# ============================================================================
# Runner
# ============================================================================

echo ""
echo "cs auto-memory tests"
echo "===================="
echo ""

run_test test_new_session_creates_memory_dir
run_test test_new_session_creates_settings_local
run_test test_unparseable_settings_local_survives_merge
run_test test_settings_local_is_gitignored
run_test test_adopt_creates_memory_dir
run_test test_adopt_adds_settings_to_gitignore
run_test test_migration_creates_memory_and_settings
run_test test_migration_moves_existing_auto_memory

# Frontmatter migration
run_test test_migration_adds_frontmatter_to_old_readme
run_test test_migration_preserves_existing_content
run_test test_migration_derives_created_date
run_test test_migration_adds_aliases_from_session_name
run_test test_migration_skips_if_frontmatter_exists

# Session narrative topic file
run_test test_new_session_creates_narrative_file
run_test test_new_session_adds_narrative_pointer
run_test test_narrative_pointer_idempotent_readd
run_test test_resume_folds_discoveries_into_narrative
run_test test_discoveries_fold_header_uses_git_date
run_test test_resume_folds_compact_when_discoveries_header_only

# Encrypted storage
run_test test_unmounted_storage_refuses_open
run_test test_pre_open_mounts_then_session_opens
run_test test_pre_open_failure_aborts_open
run_test test_pre_open_not_executable_is_refused
run_test test_pre_open_tracked_by_git_is_refused
run_test test_pre_open_success_without_mount_still_refuses
run_test test_claude_config_link_moves_claude_code_into_the_vault
run_test test_unmounted_claude_config_refuses_open
run_test test_session_without_claude_config_drops_an_inherited_vault_config
run_test test_claude_config_link_keeps_the_shell_profile_login
run_test test_claude_config_links_the_shared_config
run_test test_claude_config_links_the_shell_profile_config
run_test test_claude_config_skips_what_the_shell_config_lacks
run_test test_claude_config_keeps_its_own_entries
run_test test_claude_config_never_links_conversation_state
run_test test_claude_config_seeds_claude_json_without_projects
run_test test_claude_config_seeds_the_shell_profile_claude_json
run_test test_claude_config_shares_from_the_shell_config_not_an_inherited_vault
run_test test_claude_config_seeds_claude_json_once
run_test test_claude_config_refuses_an_unreadable_claude_json
run_test test_private_link_session_opens
run_test test_unmounted_private_refuses_open
run_test test_plaintext_left_beside_private_refuses_open
run_test test_plaintext_mailbox_left_beside_private_refuses_open
run_test test_plaintext_queue_files_left_beside_private_refuse_open
run_test test_a_file_at_a_vault_link_refuses_open

report_results
