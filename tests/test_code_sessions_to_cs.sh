#!/usr/bin/env bash
# ABOUTME: Tests for scripts/code-sessions-to-cs.py, the way back from the code-sessions profile to the stable cs.
# ABOUTME: A fixture profile with a created and an adopted session, transcripts and secrets, copied into a fixture cs.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
COPY="$SCRIPT_DIR/../scripts/code-sessions-to-cs.py"

ALPHA_ID=11111111-1111-4111-8111-111111111111
BETA_ID=22222222-2222-4222-8222-222222222222

# Claude Code's folder name for a path.
project_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

physical() {
    (cd -P "$1" && pwd)
}

session_protocol() {
    cat <<'EOF'
<!-- cs:session-protocol -->
# Session Documentation Protocol

This is a Claude Code session managed by the cs tool. Session metadata lives in the .cs/ directory.

Secrets live in the cs session store, never in a project file. `cs -secrets set`
Consume a secret inline — `some-command --token "$(cs -secrets get API_KEY)"` —

<!-- cs:wrap-cues -->
To opt out, keep the `cs:wrap-cues` HTML comment as a tombstone — cs treats the sentinel's presence as "managed, do not re-add."
EOF
}

# The profile as setup.sh leaves it, under the test HOME, so the script's
# defaults find it. alpha is a session code-sessions created (its own repository, with a
# linked worktree); beta is a project code-sessions adopted. A different session named
# alpha already lives in cs. cs-secrets is a stub that keeps each value in a
# file and logs its arguments and the backend variables it was given.
make_fixture() {
    PROFILE="$HOME/.local/share/code-sessions/home"
    CSROOT="$HOME/.claude-sessions"
    CLAUDE="$HOME/.claude"
    STUB_STORE="$TEST_TMPDIR/cs-store"
    export STUB_STORE
    mkdir -p "$PROFILE/sessions" "$PROFILE/.local/bin" "$CSROOT/alpha/.cs" "$HOME/.local/bin" "$STUB_STORE"
    cp "$SCRIPT_DIR/../bin/cs-secrets" "$PROFILE/.local/bin/cs-secrets"

    ALPHA="$PROFILE/sessions/alpha"
    mkdir -p "$ALPHA/.cs/local" "$ALPHA/.claude"
    git init -q -b main "$ALPHA"
    printf '.cs/local/\n.claude/settings.local.json\nCLAUDE.local.md\n' > "$ALPHA/.gitignore"
    printf '# Session: alpha\n' > "$ALPHA/.cs/README.md"
    { printf 'A note of my own about `ccs -list`.\n\n'; session_protocol; } > "$ALPHA/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory",\n  "plansDirectory": ".cs/plans",\n  "mine": 1\n}\n' \
        "$PROFILE/.claude-sessions/alpha" > "$ALPHA/.claude/settings.local.json"
    git -C "$ALPHA" add -A
    git -C "$ALPHA" commit -q -m 'alpha session'
    git -C "$ALPHA" worktree add -q -b side "$TEST_TMPDIR/alpha-side"
    printf 'claude_session_id: %s\nsession_name: alpha\nengine: claude\n' "$ALPHA_ID" > "$ALPHA/.cs/local/state"

    BETA_PROJECT="$TEST_TMPDIR/projects/beta"
    mkdir -p "$BETA_PROJECT/.cs/local"
    printf 'claude_session_id: %s\nsession_name: beta\n' "$BETA_ID" > "$BETA_PROJECT/.cs/local/state"
    session_protocol > "$BETA_PROJECT/CLAUDE.local.md"
    ln -s "$BETA_PROJECT" "$PROFILE/sessions/beta"
    printf '# Sessions\n' > "$PROFILE/sessions/index.md"

    ALPHA_KEY=$(project_key "$(physical "$ALPHA")")
    BETA_KEY=$(project_key "$(physical "$BETA_PROJECT")")
    BETA_CS_KEY=$(project_key "$(physical "$CSROOT")/beta")
    mkdir -p "$PROFILE/.claude/projects/$ALPHA_KEY" "$PROFILE/.claude/projects/$BETA_KEY/$BETA_ID/subagents" \
        "$PROFILE/.claude/file-history/$ALPHA_ID"
    printf '{"n":1}\n{"n":2}\n' > "$PROFILE/.claude/projects/$ALPHA_KEY/$ALPHA_ID.jsonl"
    printf '{"b":1}\n' > "$PROFILE/.claude/projects/$BETA_KEY/$BETA_ID.jsonl"
    printf '{"agent":1}\n' > "$PROFILE/.claude/projects/$BETA_KEY/$BETA_ID/subagents/agent-1.jsonl"
    printf 'before the edit\n' > "$PROFILE/.claude/file-history/$ALPHA_ID/snap@v1"

    printf 's3cret-value' > "$TEST_TMPDIR/value"
    CS_SECRETS_BACKEND=encrypted CS_SECRETS_DIR="$PROFILE/.cs-secrets" \
        "$PROFILE/.local/bin/cs-secrets" --session beta set TOKEN < "$TEST_TMPDIR/value" >/dev/null

    STUB="$HOME/.local/bin/cs-secrets"
    cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -eu
session=""
if [ "$1" = --session ]; then session=$2; shift 2; fi
echo "$* backend=${CS_SECRETS_BACKEND:-unset} dir=${CS_SECRETS_DIR:-unset}" >> "$STUB_STORE/argv.log"
case "$1" in
    list)
        if [ -d "$STUB_STORE/$session" ] && [ -n "$(ls "$STUB_STORE/$session")" ]; then
            echo "Secrets for session: $session"
            for f in "$STUB_STORE/$session"/*; do echo "  - ${f##*/}"; done
        else
            echo "No secrets stored for session: $session"
        fi ;;
    get) cat "$STUB_STORE/$session/$2"; echo ;;
    set)
        mkdir -p "$STUB_STORE/$session"
        cat > "$STUB_STORE/$session/$2"
        echo "Stored secret: $2" ;;
esac
EOF
    chmod +x "$STUB"
}

FEAT_ID=33333333-3333-4333-8333-333333333333
FIX_ID=44444444-4444-4444-8444-444444444444

# A feature worktree of each base, as code-sessions makes them: a linked
# worktree in the profile's sessions root on cs/<task>, its state naming the
# base. alpha@feat has a commit of its own, a staged change, an unstaged one,
# an untracked file and a per-worktree ref; beta (adopted) becomes a repository
# so it can have beta@fix.
add_features() {
    FEAT="$PROFILE/sessions/alpha@feat"
    git -C "$ALPHA" worktree add -q -b cs/feat "$FEAT"
    printf 'feature work\n' > "$FEAT/feature.txt"
    git -C "$FEAT" add feature.txt
    git -C "$FEAT" commit -q -m 'feature commit'
    printf 'staged\n' > "$FEAT/staged.txt"
    git -C "$FEAT" add staged.txt
    printf 'unstaged\n' >> "$FEAT/feature.txt"
    printf 'untracked\n' > "$FEAT/scratch.txt"
    git -C "$FEAT" update-ref refs/worktree/cs/session/autosave HEAD
    mkdir -p "$FEAT/.cs/local"
    printf 'task_branch: cs/feat\ncs_mode: tracked\ncs_base: alpha\nclaude_session_id: %s\n' "$FEAT_ID" \
        > "$FEAT/.cs/local/state"
    session_protocol > "$FEAT/CLAUDE.local.md"

    git -C "$BETA_PROJECT" init -q -b main
    printf '.cs/\nCLAUDE.local.md\n' > "$BETA_PROJECT/.gitignore"
    git -C "$BETA_PROJECT" add .gitignore
    git -C "$BETA_PROJECT" commit -q -m 'beta project'
    FIX="$PROFILE/sessions/beta@fix"
    git -C "$BETA_PROJECT" worktree add -q -b cs/fix "$FIX"
    mkdir -p "$FIX/.cs/local"
    printf 'task_branch: cs/fix\ncs_mode: ignored\ncs_base: beta\nclaude_session_id: %s\n' "$FIX_ID" \
        > "$FIX/.cs/local/state"
    session_protocol > "$FIX/CLAUDE.local.md"

    FEAT_KEY=$(project_key "$(physical "$FEAT")")
    FIX_KEY=$(project_key "$(physical "$FIX")")
    mkdir -p "$PROFILE/.claude/projects/$FEAT_KEY" "$PROFILE/.claude/projects/$FIX_KEY"
    printf '{"f":1}\n' > "$PROFILE/.claude/projects/$FEAT_KEY/$FEAT_ID.jsonl"
    printf '{"x":1}\n' > "$PROFILE/.claude/projects/$FIX_KEY/$FIX_ID.jsonl"
}

# Every file and link under a directory, hashed, so a test can prove it was only read.
fingerprint() {
    (cd "$1" && find . \( -type f -o -type l \) -print | sort | while IFS= read -r f; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(shasum < "$f")"; fi
    done) | shasum
}

profile_fingerprint() {
    fingerprint "$PROFILE"
}

run_copy() {
    local status=0
    python3 "$COPY" "$@" > "$TEST_TMPDIR/out.log" 2>&1 || status=$?
    OUT=$(cat "$TEST_TMPDIR/out.log")
    return "$status"
}

test_dry_run_changes_nothing() {
    make_fixture
    local before
    before=$(profile_fingerprint)
    run_copy || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'alpha -> cs alpha-ccs (cs already has a different alpha)' || return 1
    assert_output_contains "$OUT" 'would copy the session directory to .*claude-sessions/alpha-ccs' || return 1
    assert_output_contains "$OUT" 'would copy the session directory to .*claude-sessions/beta' || return 1
    assert_output_not_contains "$OUT" 'link' || return 1
    assert_output_contains "$OUT" 'secrets to copy: TOKEN' || return 1
    assert_output_contains "$OUT" 'Dry run: nothing changed' || return 1
    assert_eq "alpha" "$(ls "$CSROOT")" "cs gained a session on a dry run" || return 1
    assert_not_exists "$CLAUDE" || return 1
    assert_not_exists "$STUB_STORE/beta" || return 1
    assert_eq "$before" "$(profile_fingerprint)" "the profile changed"
}

test_apply_copies_sessions_conversations_and_secrets() {
    make_fixture
    local before copy beta_before
    before=$(profile_fingerprint)
    beta_before=$(fingerprint "$BETA_PROJECT")
    run_copy --apply || { echo "$OUT"; return 1; }
    copy="$CSROOT/alpha-ccs"

    # The created session is copied under a free name, git history and local state included.
    assert_dir "$copy" || return 1
    assert_eq "alpha session" "$(git -C "$copy" log -1 --format=%s)" || return 1
    assert_eq "" "$(git -C "$copy" status --porcelain)" "the copy has changes the original did not" || return 1
    assert_not_exists "$copy/.git/worktrees" "the original's linked worktrees came along" || return 1
    assert_file_contains "$copy/.cs/local/state" "claude_session_id: $ALPHA_ID" || return 1
    assert_file_contains "$copy/.cs/local/state" '^session_name: alpha-ccs' || return 1
    assert_eq "$(physical "$ALPHA")" "$(cat "$copy/.cs/local/code-sessions-origin")" || return 1
    assert_eq "$CSROOT/alpha-ccs/.cs/memory" \
        "$(jq -r .autoMemoryDirectory "$copy/.claude/settings.local.json")" || return 1
    assert_eq 1 "$(jq -r .mine "$copy/.claude/settings.local.json")" "another setting was lost" || return 1
    # Both sides word the protocol alike, so it comes over as it is.
    cmp "$ALPHA/CLAUDE.local.md" "$copy/CLAUDE.local.md" || return 1
    # The cs session that already had the name is untouched.
    assert_eq "" "$(ls -A "$CSROOT/alpha/.cs")" || return 1

    # The adopted session is copied too: cs gets a folder of its own, and the
    # project code-sessions adopted is left as it is.
    [ -d "$CSROOT/beta" ] && [ ! -L "$CSROOT/beta" ] || { echo "  FAIL: beta is not a copy of its own"; return 1; }
    assert_file_contains "$CSROOT/beta/CLAUDE.local.md" 'cs treats the sentinel' || return 1
    assert_eq "$beta_before" "$(fingerprint "$BETA_PROJECT")" "the project code-sessions adopted changed" || return 1

    # Conversations land under the folder Claude Code gives each cs path.
    local alpha_dst
    alpha_dst="$CLAUDE/projects/$(project_key "$(physical "$copy")")"
    cmp -s "$PROFILE/.claude/projects/$ALPHA_KEY/$ALPHA_ID.jsonl" "$alpha_dst/$ALPHA_ID.jsonl" \
        || { echo "  FAIL: alpha's conversation was not copied to $alpha_dst"; return 1; }
    assert_file_exists "$CLAUDE/projects/$BETA_CS_KEY/$BETA_ID.jsonl" || return 1
    assert_file_exists "$CLAUDE/projects/$BETA_CS_KEY/$BETA_ID/subagents/agent-1.jsonl" || return 1
    assert_file_exists "$CLAUDE/file-history/$ALPHA_ID/snap@v1" || return 1

    # Secrets reach cs-secrets on stdin, under the cs name, without the code-sessions backend.
    assert_eq 12 "$(wc -c < "$STUB_STORE/beta/TOKEN" | tr -d ' ')" || return 1
    assert_eq "s3cret-value" "$(cat "$STUB_STORE/beta/TOKEN")" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 's3cret' "the value reached argv" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'backend=encrypted' "cs-secrets got the code-sessions backend" || return 1

    assert_output_contains "$OUT" "cs alpha-ccs resumes conversation $ALPHA_ID" || return 1
    assert_eq "$before" "$(profile_fingerprint)" "the profile changed"
}

test_rerun_brings_over_only_what_grew() {
    make_fixture
    run_copy --apply || { echo "$OUT"; return 1; }
    local alpha_dst beta_dst
    alpha_dst="$CLAUDE/projects/$(project_key "$(physical "$CSROOT/alpha-ccs")")"
    beta_dst="$CLAUDE/projects/$BETA_CS_KEY"
    # alpha went on in code-sessions; beta went on in both; beta's subagent went on in cs only.
    printf '{"n":3}\n' >> "$PROFILE/.claude/projects/$ALPHA_KEY/$ALPHA_ID.jsonl"
    printf '{"b":"code-sessions"}\n' >> "$PROFILE/.claude/projects/$BETA_KEY/$BETA_ID.jsonl"
    printf '{"b":"cs"}\n' >> "$beta_dst/$BETA_ID.jsonl"
    printf '{"agent":2}\n' >> "$beta_dst/$BETA_ID/subagents/agent-1.jsonl"
    git -C "$ALPHA" commit -q --allow-empty -m 'later work in code-sessions'
    printf 'code-sessions note\n' > "$ALPHA/.cs/note.md"
    printf 'Run `cs -secrets list` here.\n' >> "$ALPHA/CLAUDE.local.md"
    printf 'cs note\n' > "$CSROOT/beta/.cs/cs-note.md"
    # Both sides: the session README.
    printf 'code-sessions readme\n' >> "$ALPHA/.cs/README.md"
    printf 'cs readme\n' >> "$CSROOT/alpha-ccs/.cs/README.md"
    # A stat-dirty index: a git status in code-sessions's folder would rewrite its index.
    touch "$ALPHA/.gitignore"
    # Past the marks' 2 s margin, as between real runs: a change inside it is looked at again next time.
    sleep 2.1

    local status=0 before
    before=$(profile_fingerprint)
    run_copy --apply || status=$?
    assert_eq 1 "$status" "a conversation continued on both sides must fail the run" || { echo "$OUT"; return 1; }
    assert_eq "$before" "$(profile_fingerprint)" "the rerun changed the profile" || return 1
    assert_output_contains "$OUT" 'in cs at .*alpha-ccs since an earlier run' || return 1
    assert_output_contains "$OUT" "alpha-ccs: took code-sessions's HEAD and index: main at " || return 1
    assert_file_contains "$CSROOT/alpha-ccs/.cs/note.md" 'code-sessions note' || return 1
    assert_file_contains "$CSROOT/alpha-ccs/CLAUDE.local.md" 'Run .cs -secrets list. here' \
        "a protocol line code-sessions added did not come over" || return 1
    assert_file_contains "$CSROOT/beta/.cs/cs-note.md" 'cs note' || return 1
    assert_output_contains "$OUT" "alpha-ccs: kept cs's .cs/README.md (changed on both sides)" || return 1
    assert_file_contains "$CSROOT/alpha-ccs/.cs/README.md" 'cs readme' || return 1
    assert_eq "$(git -C "$ALPHA" status --porcelain)" "$(git -C "$CSROOT/alpha-ccs" status --porcelain)" \
        "the copy's working state differs from code-sessions's" || return 1
    assert_output_contains "$OUT" '1 grown since the last copy' || return 1
    assert_output_contains "$OUT" 'continued in both code-sessions and cs' || return 1
    assert_output_contains "$OUT" 'went on past the code-sessions copy' || return 1
    cmp -s "$PROFILE/.claude/projects/$ALPHA_KEY/$ALPHA_ID.jsonl" "$alpha_dst/$ALPHA_ID.jsonl" \
        || { echo "  FAIL: the grown conversation was not brought over"; return 1; }
    assert_file_contains "$beta_dst/$BETA_ID.jsonl" '"cs"' || return 1
    assert_file_not_contains "$beta_dst/$BETA_ID.jsonl" '"code-sessions"' || return 1
    assert_file_contains "$beta_dst/$BETA_ID/subagents/agent-1.jsonl" '"agent":2' || return 1
    assert_eq "alpha alpha-ccs" "$(cd "$CSROOT" && echo alpha*)" "a rerun made another copy" || return 1
    assert_eq "$(git -C "$ALPHA" rev-parse HEAD)" "$(git -C "$CSROOT/alpha-ccs" rev-parse HEAD)" || return 1
    assert_eq "$(git -C "$ALPHA" rev-parse HEAD)" "$(git -C "$CSROOT/alpha-ccs" rev-parse refs/remotes/code-sessions/main)" || return 1
    # Said once: the next run does not report the README again.
    run_copy --apply || true
    assert_output_not_contains "$OUT" 'README.md' "a file kept on both sides was reported twice"
}

test_a_secret_cs_already_has_is_kept() {
    make_fixture
    mkdir -p "$STUB_STORE/beta"
    printf 's3cret-value' > "$STUB_STORE/beta/TOKEN"
    run_copy --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'secrets cs already has: TOKEN' || return 1
    # One whose value differs is said, never overwritten, and never shown.
    printf 'old' > "$STUB_STORE/beta/TOKEN"
    local status=0
    run_copy --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "secret TOKEN differs between code-sessions and cs; cs's is kept" || return 1
    assert_output_not_contains "$OUT" 's3cret' || return 1
    assert_eq "old" "$(cat "$STUB_STORE/beta/TOKEN")"
}

test_open_encrypted_and_orphaned_sessions_stay_behind_with_a_reason() {
    make_fixture
    mkdir -p "$PROFILE/sessions/gamma/.cs" "$PROFILE/sessions/delta/.cs/local" "$PROFILE/sessions/zeta@x/.cs"
    echo $$ > "$PROFILE/sessions/gamma/.cs/session.lock"
    printf '#!/bin/bash\n' > "$PROFILE/sessions/delta/.cs/local/pre-open"
    ln -s "$TEST_TMPDIR/projects/gone" "$PROFILE/sessions/epsilon"
    local status=0
    run_copy --apply || status=$?
    assert_eq 1 "$status" "a session left behind must fail the run" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'open in code-sessions right now' || return 1
    assert_output_contains "$OUT" 'encrypted' || return 1
    assert_output_contains "$OUT" 'its base zeta is not a code-sessions session' || return 1
    assert_output_contains "$OUT" 'projects/gone no longer exists' || return 1
    assert_not_exists "$CSROOT/gamma" || return 1
    assert_not_exists "$CSROOT/epsilon" || return 1
    assert_not_exists "$CSROOT/delta" || return 1
    assert_not_exists "$CSROOT/zeta@x" || return 1
    # The rest is still copied.
    assert_dir "$CSROOT/beta" || return 1
    assert_output_contains "$OUT" 'Copied what could be copied'
}

test_a_failure_in_one_session_leaves_the_others_to_copy() {
    make_fixture
    # A file where alpha's conversation folder must go.
    mkdir -p "$CLAUDE/projects"
    local key
    key=$(project_key "$(physical "$CSROOT")/alpha-ccs")
    printf 'in the way\n' > "$CLAUDE/projects/$key"
    local status=0
    run_copy --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'stopped:' || return 1
    assert_output_not_contains "$OUT" 'Traceback' || return 1
    assert_dir "$CSROOT/beta" || return 1
    assert_file_exists "$CLAUDE/projects/$BETA_CS_KEY/$BETA_ID.jsonl" || return 1
    assert_file_exists "$STUB_STORE/beta/TOKEN"
}

test_feature_worktrees_follow_their_base() {
    make_fixture
    add_features
    local before status_before list_before copy
    before=$(profile_fingerprint)
    status_before=$(git -C "$FEAT" status --porcelain)
    list_before=$(git -C "$ALPHA" worktree list --porcelain)
    run_copy || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'would copy the feature worktree to .*alpha-ccs@feat, a worktree of cs alpha-ccs on cs/feat' || return 1
    assert_output_contains "$OUT" 'would copy the feature worktree to .*beta@fix, a worktree of cs beta on cs/fix' || return 1
    run_copy --apply || { echo "$OUT"; return 1; }
    copy="$CSROOT/alpha-ccs@feat"

    # A worktree of the base's cs copy, on the same branch, with the same changes.
    assert_dir "$copy" || return 1
    assert_eq "cs/feat" "$(git -C "$copy" branch --show-current)" || return 1
    assert_eq "$status_before" "$(git -C "$copy" status --porcelain)" "the uncommitted changes differ" || return 1
    assert_eq "$(physical "$CSROOT/alpha-ccs")/.git" "$(cd "$copy" && cd -P "$(git rev-parse --git-common-dir)" && pwd)" \
        "the copy is not a worktree of the base's cs copy" || return 1
    git -C "$CSROOT/alpha-ccs" worktree list --porcelain | grep -qxF "worktree $(physical "$copy")" \
        || { echo "  FAIL: the base's cs copy does not list the feature"; return 1; }
    assert_eq "$(git -C "$FEAT" rev-parse refs/worktree/cs/session/autosave)" \
        "$(git -C "$copy" rev-parse refs/worktree/cs/session/autosave)" "the per-worktree ref was lost" || return 1
    assert_file_contains "$copy/.cs/local/state" '^cs_base: alpha-ccs' || return 1
    assert_file_contains "$copy/.cs/local/state" '^task_branch: cs/feat' || return 1
    assert_file_contains "$copy/CLAUDE.local.md" 'managed by the cs tool' || return 1
    assert_file_exists "$CLAUDE/projects/$(project_key "$(physical "$copy")")/$FEAT_ID.jsonl" || return 1

    # The original is still the original repository's worktree, and a commit in
    # the copy leaves it alone.
    assert_eq "$list_before" "$(git -C "$ALPHA" worktree list --porcelain)" || return 1
    assert_eq "$status_before" "$(git -C "$FEAT" status --porcelain)" || return 1
    local tip
    tip=$(git -C "$ALPHA" rev-parse cs/feat)
    git -C "$copy" commit -q -m 'continued in cs'
    assert_eq "$tip" "$(git -C "$ALPHA" rev-parse cs/feat)" "a commit in cs moved the code-sessions branch" || return 1

    # The adopted base's feature is copied the same way, into the cs copy of beta.
    [ -d "$CSROOT/beta@fix" ] && [ ! -L "$CSROOT/beta@fix" ] || { echo "  FAIL: beta@fix is not a copy"; return 1; }
    assert_eq "$(physical "$CSROOT/beta")/.git" \
        "$(cd "$CSROOT/beta@fix" && cd -P "$(git rev-parse --git-common-dir)" && pwd)" || return 1
    assert_eq "cs/fix" "$(git -C "$CSROOT/beta@fix" branch --show-current)" || return 1
    assert_file_contains "$CSROOT/beta@fix/CLAUDE.local.md" 'managed by the cs tool' || return 1
    assert_file_exists "$CLAUDE/projects/$(project_key "$(physical "$CSROOT/beta@fix")")/$FIX_ID.jsonl" || return 1
    assert_eq "$before" "$(profile_fingerprint)" "the profile changed" || return 1

    # A rerun finds both and adds no second worktree entry; cs's commit in its copy is kept.
    run_copy --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "in cs at .*alpha-ccs@feat since an earlier run" || return 1
    assert_output_contains "$OUT" "alpha-ccs@feat: HEAD and index moved on in cs only, kept" || return 1
    assert_eq 2 "$(git -C "$CSROOT/alpha-ccs" worktree list --porcelain | grep -c '^worktree ')" || return 1
    assert_eq "alpha-ccs@feat" "$(ls "$CSROOT/alpha-ccs/.git/worktrees")" || return 1

    # A copy cs removed stays removed.
    rm -rf "$CSROOT/alpha-ccs@feat"
    git -C "$CSROOT/alpha-ccs" worktree prune
    run_copy --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'cs removed its copy .*alpha-ccs@feat after an earlier run; not copied again' || return 1
    assert_not_exists "$CSROOT/alpha-ccs@feat"
}

test_a_feature_comes_only_with_its_base() {
    make_fixture
    add_features
    local status=0
    run_copy --apply --session alpha@feat || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'its base alpha is not in cs yet; copy it too (--session alpha)' || return 1
    assert_not_exists "$CSROOT/alpha-ccs@feat" || return 1
    # Once the base is in cs, the feature alone is enough.
    run_copy --apply --session alpha || { echo "$OUT"; return 1; }
    run_copy --apply --session alpha@feat || { echo "$OUT"; return 1; }
    assert_eq "cs/feat" "$(git -C "$CSROOT/alpha-ccs@feat" branch --show-current)" || return 1
    status=0
    run_copy --rename alpha@feat=other || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" "a feature worktree takes its base's cs name"
}

test_rename_and_session_pick_what_is_copied() {
    make_fixture
    run_copy --apply --session alpha --rename alpha=alpha2 || { echo "$OUT"; return 1; }
    assert_dir "$CSROOT/alpha2" || return 1
    assert_not_exists "$CSROOT/alpha-ccs" || return 1
    assert_not_exists "$CSROOT/beta" || return 1
    local status=0
    run_copy --apply --session beta --rename beta=alpha || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'cs already has alpha' || return 1
    assert_not_exists "$CSROOT/beta" || return 1
    status=0
    run_copy --session nope || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'No code-sessions session named nope'
}

# Inside a code-sessions session these name the profile; the copy must still go to cs.
test_a_code_sessions_environment_does_not_redirect_the_copy() {
    make_fixture
    env CODE_SESSIONS_HOME="$PROFILE" CS_SESSIONS_ROOT="$PROFILE/sessions" CS_TRANSCRIPTS_DIR="$PROFILE/.claude/projects" \
        CLAUDE_CONFIG_DIR="$PROFILE/.claude" CS_SECRETS_BACKEND=encrypted \
        CS_SECRETS_DIR="$PROFILE/.cs-secrets" CS_SESSION_NAME=alpha \
        python3 "$COPY" --apply > "$TEST_TMPDIR/out.log" 2>&1 || { cat "$TEST_TMPDIR/out.log"; return 1; }
    assert_dir "$CSROOT/beta" || return 1
    assert_file_exists "$CLAUDE/projects/$BETA_CS_KEY/$BETA_ID.jsonl" || return 1
    assert_file_exists "$STUB_STORE/beta/TOKEN" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'backend=encrypted' || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'dir=/' || return 1
}

run_test test_dry_run_changes_nothing
run_test test_apply_copies_sessions_conversations_and_secrets
run_test test_rerun_brings_over_only_what_grew
run_test test_a_secret_cs_already_has_is_kept
run_test test_open_encrypted_and_orphaned_sessions_stay_behind_with_a_reason
run_test test_a_failure_in_one_session_leaves_the_others_to_copy
run_test test_feature_worktrees_follow_their_base
run_test test_a_feature_comes_only_with_its_base
run_test test_rename_and_session_pick_what_is_copied
run_test test_a_code_sessions_environment_does_not_redirect_the_copy
report_results
