#!/usr/bin/env bash
# ABOUTME: Tests for scripts/cs-to-ags.py, which gives ags a project the stable cs adopted and leaves cs as it is.
# ABOUTME: A fixture cs with an adopted project, two feature worktrees, history and secrets, handed to a fixture profile.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
MOVE="$SCRIPT_DIR/../scripts/cs-to-ags.py"
BACK="$SCRIPT_DIR/../scripts/ags-to-cs.py"
AGS="$SCRIPT_DIR/../bin/ags"

WAP_ID=11111111-1111-4111-8111-111111111111
FEAT_ID=33333333-3333-4333-8333-333333333333
FIX_ID=44444444-4444-4444-8444-444444444444
OLD_ID=55555555-5555-4555-8555-555555555555
OTHER_ID=66666666-6666-4666-8666-666666666666
SCRATCH_ID=77777777-7777-4777-8777-777777777777

project_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

physical() {
    (cd -P "$1" && pwd)
}

cs_protocol() {
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

# A cs feature worktree as cs and branch-out make them: a linked worktree of the
# project in cs's sessions root, its state naming the base.
add_feature() {  # task branch id
    local dir="$CSROOT/wap@$1"
    git -C "$PROJECT" worktree add -q -b "$2" "$dir"
    mkdir -p "$dir/.cs/local" "$dir/.claude"
    printf 'task_branch: %s\ncs_mode: tracked\ncs_base: wap\nclaude_session_id: %s\n' "$2" "$3" > "$dir/.cs/local/state"
    cs_protocol > "$dir/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory",\n  "plansDirectory": ".cs/plans"\n}\n' "$dir" \
        > "$dir/.claude/settings.local.json"
    mkdir -p "$CLAUDE/projects/$(project_key "$(physical "$dir")")"
    printf '{"feature":"%s"}\n' "$1" > "$CLAUDE/projects/$(project_key "$(physical "$dir")")/$3.jsonl"
}

# The stable cs as it is before the move, under the test HOME: wap is a project
# cs adopted, with a cs/<task> feature and a branch-out feature; a retired
# feature and a scratch folder left conversations behind; wap-other is another
# cs session whose folder name starts like wap's features. cs-secrets is a stub
# that keeps each value in a file and logs its arguments.
make_fixture() {
    PROFILE="$HOME/.local/share/agent-sessions/home"
    CSROOT="$HOME/.claude-sessions"
    CLAUDE="$HOME/.claude"
    STUB_STORE="$TEST_TMPDIR/cs-store"
    export STUB_STORE
    mkdir -p "$PROFILE/sessions" "$PROFILE/.local/bin" "$PROFILE/.claude" "$PROFILE/.codex" \
        "$CSROOT" "$HOME/.local/bin" "$HOME/.codex" "$STUB_STORE/wap" "$CLAUDE/projects"
    cp "$SCRIPT_DIR/../bin/ags-secrets" "$PROFILE/.local/bin/ags-secrets"

    PROJECT="$TEST_TMPDIR/projects/wap"
    mkdir -p "$PROJECT/.cs/local" "$PROJECT/.claude"
    git init -q -b main "$PROJECT"
    printf '.cs/\n.claude/settings.local.json\nCLAUDE.local.md\nnode_modules/\n' > "$PROJECT/.gitignore"
    printf 'code\n' > "$PROJECT/app.js"
    git -C "$PROJECT" add -A
    git -C "$PROJECT" commit -q -m 'wap project'
    printf 'claude_session_id: %s\nsession_name: wap\nengine: claude\n' "$WAP_ID" > "$PROJECT/.cs/local/state"
    { printf 'A note of my own about `cs -list`.\n\n'; cs_protocol; } > "$PROJECT/CLAUDE.local.md"
    printf '{\n  "autoMemoryDirectory": "%s/.cs/memory"\n}\n' "$(physical "$PROJECT")" \
        > "$PROJECT/.claude/settings.local.json"
    ln -s "$PROJECT" "$CSROOT/wap"
    PROJECT_KEY=$(project_key "$(physical "$PROJECT")")
    mkdir -p "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/subagents" "$CLAUDE/file-history/$WAP_ID" \
        "$CLAUDE/session-env/$WAP_ID" "$CLAUDE/tasks/wap"
    printf '{"n":1}\n{"n":2}\n' > "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    printf '{"agent":1}\n' > "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID/subagents/agent-1.jsonl"
    printf 'before the edit\n' > "$CLAUDE/file-history/$WAP_ID/snap@v1"
    printf 'PATH=x\n' > "$CLAUDE/session-env/$WAP_ID/hook-1.sh"
    printf '{"id":"1"}\n' > "$CLAUDE/tasks/wap/1.json"

    add_feature feat cs/feat "$FEAT_ID"
    FEAT="$CSROOT/wap@feat"
    FEAT_OLD=$(physical "$FEAT")
    printf 'feature work\n' > "$FEAT/feature.txt"
    git -C "$FEAT" add feature.txt
    git -C "$FEAT" commit -q -m 'feature commit'
    printf 'staged\n' > "$FEAT/staged.txt"
    git -C "$FEAT" add staged.txt
    printf 'unstaged\n' >> "$FEAT/feature.txt"
    printf 'untracked\n' > "$FEAT/scratch.txt"
    mkdir -p "$FEAT/node_modules/dep"
    printf 'ignored\n' > "$FEAT/node_modules/dep/index.js"
    git -C "$FEAT" update-ref refs/worktree/cs/session/autosave HEAD

    add_feature fix wap-fix "$FIX_ID"
    FIX_OLD=$(physical "$CSROOT/wap@fix")
    REGISTRY="$HOME/.agent-worktrees/registry/wap-repo/wap@fix.json"
    mkdir -p "${REGISTRY%/*}"
    printf '{\n  "worktreePath": "%s",\n  "sessionName": "wap@fix",\n  "sessionManager": "cs",\n  "branch": "wap-fix"\n}\n' \
        "$CSROOT/wap@fix" > "$REGISTRY"

    # Left behind by a retired feature and a conversation's scratch folder.
    OLD_KEY=$(project_key "$(physical "$CSROOT")/wap@old")
    SCRATCH_KEY=$(project_key "/private/tmp/claude-501/$OLD_KEY/$SCRATCH_ID/scratchpad")
    mkdir -p "$CLAUDE/projects/$OLD_KEY" "$CLAUDE/projects/$SCRATCH_KEY"
    printf '{"old":1}\n' > "$CLAUDE/projects/$OLD_KEY/$OLD_ID.jsonl"
    printf '{"scratch":1}\n' > "$CLAUDE/projects/$SCRATCH_KEY/$SCRATCH_ID.jsonl"
    # Another session whose folder name starts like a wap feature's.
    mkdir -p "$CSROOT/wap-other/.cs"
    OTHER_KEY=$(project_key "$(physical "$CSROOT/wap-other")")
    mkdir -p "$CLAUDE/projects/$OTHER_KEY"
    printf '{"other":1}\n' > "$CLAUDE/projects/$OTHER_KEY/$OTHER_ID.jsonl"

    {
        printf '{"display":"main prompt","timestamp":1,"project":"%s"}\n' "$(physical "$PROJECT")"
        printf '{"display":"feature prompt","timestamp":2,"project":"%s"}\n' "$FEAT_OLD"
        printf '{"display":"retired prompt","timestamp":3,"project":"%s/wap@old"}\n' "$(physical "$CSROOT")"
        printf '{"display":"other prompt","timestamp":4,"project":"%s"}\n' "$(physical "$CSROOT/wap-other")"
    } > "$CLAUDE/history.jsonl"
    jq -n --arg p "$(physical "$PROJECT")" --arg f "$FEAT_OLD" '{projects: {
        ($p): {allowedTools: ["Bash(ls)"], hasTrustDialogAccepted: true, lastCost: 1},
        ($f): {hasTrustDialogAccepted: true}}}' > "$HOME/.claude.json"
    jq -n --arg p "$(physical "$PROJECT")" '{theme: "dark", projects: {($p): {hasTrustDialogAccepted: false}}}' \
        > "$PROFILE/.claude/.claude.json"
    printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "trusted"\n\n[projects."/elsewhere"]\ntrust_level = "untrusted"\n' \
        "$FEAT_OLD" > "$HOME/.codex/config.toml"
    printf 'model = "y"\n' > "$PROFILE/.codex/config.toml"

    printf 's3cret-value' > "$STUB_STORE/wap/TOKEN"
    cat > "$HOME/.local/bin/cs-secrets" <<'EOF'
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
    set) mkdir -p "$STUB_STORE/$session"; cat > "$STUB_STORE/$session/$2"; echo "Stored secret: $2" ;;
esac
EOF
    chmod +x "$HOME/.local/bin/cs-secrets"
}

ags_secret() {  # session name
    CS_SECRETS_BACKEND=encrypted CS_SECRETS_DIR="$PROFILE/.cs-secrets" \
        "$PROFILE/.local/bin/ags-secrets" --session "$1" get "$2"
}

# Every file and link under a directory, hashed, so a test can prove it was only read.
fingerprint() {
    (cd "$1" && find . \( -type f -o -type l \) -print | sort | while IFS= read -r f; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s %s\n' "$f" "$(shasum < "$f")"; fi
    done) | shasum
}

run_move() {
    local status=0
    python3 "$MOVE" "$@" > "$TEST_TMPDIR/out.log" 2>&1 || status=$?
    OUT=$(cat "$TEST_TMPDIR/out.log")
    return "$status"
}

# Everything the stable side has, so a test can prove the hand-over only read it.
cs_side_fingerprint() {
    {
        fingerprint "$CSROOT"
        fingerprint "$PROJECT"
        fingerprint "$CLAUDE"
        fingerprint "$HOME/.codex"
        shasum < "$HOME/.claude.json"
        shasum < "$REGISTRY"
        git -C "$PROJECT" worktree list --porcelain
        fingerprint "$STUB_STORE/wap"
    } | shasum
}

test_dry_run_changes_nothing() {
    make_fixture
    local cs_before profile_before
    cs_before=$(cs_side_fingerprint)
    profile_before=$(fingerprint "$PROFILE")
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: would link .*sessions/wap -> ' || return 1
    assert_output_contains "$OUT" 'wap@feat: would link .*sessions/wap@feat -> .*claude-sessions/wap@feat (on cs/feat)' || return 1
    assert_output_contains "$OUT" 'wap@fix: would link .*sessions/wap@fix -> ' || return 1
    assert_output_contains "$OUT" 'secrets of wap to copy: TOKEN' || return 1
    assert_output_contains "$OUT" "ags wap resumes conversation $WAP_ID" || return 1
    assert_output_contains "$OUT" 'Dry run: nothing changed' || return 1
    assert_output_not_contains "$OUT" 'remove' || return 1
    assert_output_not_contains "$OUT" 'move the worktree' || return 1
    assert_output_not_contains "$OUT" 'reword' || return 1
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "the profile changed"
}

test_apply_hands_the_session_over_and_leaves_cs_as_it_is() {
    make_fixture
    local cs_before
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || { echo "$OUT"; return 1; }

    # Not one byte of the cs side changed: links, folders, worktrees, history, settings, secrets.
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_symlink "$CSROOT/wap" || return 1
    assert_dir "$FEAT" || return 1
    assert_file_contains "$PROJECT/CLAUDE.local.md" 'managed by the cs tool' || return 1

    # ags links to the same folders.
    assert_symlink "$PROFILE/sessions/wap" || return 1
    assert_eq "$PROJECT" "$(readlink "$PROFILE/sessions/wap")" || return 1
    assert_symlink "$PROFILE/sessions/wap@feat" || return 1
    assert_eq "$FEAT_OLD" "$(physical "$PROFILE/sessions/wap@feat")" || return 1
    assert_eq "$FIX_OLD" "$(physical "$PROFILE/sessions/wap@fix")" || return 1
    assert_eq "cs/feat" "$(git -C "$PROFILE/sessions/wap@feat" branch --show-current)" || return 1

    # Conversations under the same folder names, with their side files.
    local projects="$PROFILE/.claude/projects"
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$projects/$PROJECT_KEY/$WAP_ID.jsonl" \
        || { echo "  FAIL: wap's conversation was not copied"; return 1; }
    assert_file_exists "$projects/$PROJECT_KEY/$WAP_ID/subagents/agent-1.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$FEAT_OLD")/$FEAT_ID.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$FIX_OLD")/$FIX_ID.jsonl" || return 1
    assert_file_exists "$PROFILE/.claude/file-history/$WAP_ID/snap@v1" || return 1
    assert_file_exists "$PROFILE/.claude/session-env/$WAP_ID/hook-1.sh" || return 1
    assert_file_exists "$PROFILE/.claude/tasks/wap/1.json" || return 1
    # History with no session comes too; another session's stays out.
    assert_file_exists "$projects/$OLD_KEY/$OLD_ID.jsonl" || return 1
    assert_file_exists "$projects/$SCRATCH_KEY/$SCRATCH_ID.jsonl" || return 1
    assert_not_exists "$projects/$OTHER_KEY" "wap-other's conversations came along" || return 1

    # Prompt history for the session's paths, as cs wrote it; other sessions' stay out.
    local prompts="$PROFILE/.claude/history.jsonl"
    assert_file_contains "$prompts" 'main prompt' || return 1
    assert_eq "$FEAT_OLD" "$(jq -r 'select(.display == "feature prompt") | .project' "$prompts")" || return 1
    assert_file_contains "$prompts" 'retired prompt' || return 1
    assert_file_not_contains "$prompts" 'other prompt' || return 1

    # Settings follow each path; the profile's own stay.
    local state="$PROFILE/.claude/.claude.json"
    assert_eq '["Bash(ls)"]' "$(jq -c --arg p "$(physical "$PROJECT")" '.projects[$p].allowedTools' "$state")" || return 1
    assert_eq false "$(jq --arg p "$(physical "$PROJECT")" '.projects[$p].hasTrustDialogAccepted' "$state")" \
        "a profile setting was overwritten" || return 1
    assert_eq null "$(jq --arg p "$(physical "$PROJECT")" '.projects[$p].lastCost' "$state")" || return 1
    assert_eq true "$(jq --arg p "$FEAT_OLD" '.projects[$p].hasTrustDialogAccepted' "$state")" || return 1
    assert_eq dark "$(jq -r .theme "$state")" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" "^\[projects.\"$FEAT_OLD\"\]" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" '^model = "y"' || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" 'elsewhere' || return 1

    # Secrets reach ags-secrets on stdin; argv never carries a value.
    assert_eq "s3cret-value" "$(ags_secret wap TOKEN)" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 's3cret' "the value reached argv" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'backend=encrypted' "cs-secrets got the ags backend" || return 1

    jq -e 'select(.action == "linked" and .session == "wap@feat")' "$PROFILE/.cs-to-ags/log.jsonl" >/dev/null \
        || { echo "  FAIL: the link is not in the log"; return 1; }
    assert_output_contains "$OUT" 'cs keeps wap as it was'
}

test_rerun_brings_over_only_what_grew() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf '{"n":3}\n' >> "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: already in ags at .*sessions/wap$' || return 1
    assert_output_contains "$OUT" 'wap@feat: already in ags' || return 1
    assert_output_contains "$OUT" 'Claude history of wap, 1 conversation(s), files copied: 1 grown since the last copy' || return 1
    assert_output_contains "$OUT" 'Claude history of wap@feat, 1 conversation(s): nothing new' || return 1
    assert_output_contains "$OUT" 'secrets of wap ags already has, kept: TOKEN' || return 1
    assert_output_not_contains "$OUT" 'prompt history' || return 1
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$PROFILE/.claude/projects/$PROJECT_KEY/$WAP_ID.jsonl" \
        || { echo "  FAIL: the grown conversation was not brought over"; return 1; }
    assert_eq 3 "$(wc -l < "$PROFILE/.claude/history.jsonl" | tr -d ' ')" "a rerun duplicated the prompt history"
}

# cs execs claude in its place, which takes the lock with it: an engine or a
# session manager running in a folder shows the session is open. It is named,
# since what it writes later needs a rerun; nothing moves, so nothing waits.
test_a_session_open_in_cs_is_named_and_still_handed_over() {
    make_fixture
    echo $$ > "$FEAT/.cs/session.lock"
    local claude_pid shell_pid
    (cd "$PROJECT" && exec -a claude sleep 30) &
    claude_pid=$!
    (cd "$CSROOT/wap@fix" && exec sleep 30) &
    shell_pid=$!
    sleep 0.3
    run_move --session wap --apply || { kill "$claude_pid" "$shell_pid"; echo "$OUT"; return 1; }
    kill "$claude_pid" "$shell_pid" 2>/dev/null; wait "$claude_pid" "$shell_pid" 2>/dev/null
    assert_output_contains "$OUT" "note: open in cs right now: wap .pid $claude_pid: claude 30., wap@feat\. What it writes" || return 1
    assert_output_not_contains "$OUT" 'wap@fix .pid' "a plain process counted as an open session" || return 1
    assert_symlink "$PROFILE/sessions/wap@feat" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$PROJECT_KEY/$WAP_ID.jsonl"
}

test_sessions_the_script_does_not_hand_over_say_why() {
    make_fixture
    local status=0
    run_move --session wap-other || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'cs created this session in its own folder' || return 1
    status=0
    run_move --session nope || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'No cs session named nope' || return 1
    status=0
    run_move --session wap@feat || status=$?
    assert_eq 2 "$status" || return 1
    assert_output_contains "$OUT" 'name a base session' || return 1

    # A feature ags already has under that name, and a folder git does not list, stay out; the rest comes.
    mkdir -p "$PROFILE/sessions/wap@feat" "$CSROOT/wap@gone/.cs"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap@feat: not linked: ags already has a different wap@feat' || return 1
    assert_output_contains "$OUT" "wap@gone: not linked: not a registered worktree of wap's repository" || return 1
    assert_symlink "$PROFILE/sessions/wap@fix" || return 1
    assert_not_exists "$PROFILE/sessions/wap@gone" || return 1

    rm -rf "$PROFILE/sessions"/*
    ln -s "$TEST_TMPDIR/somewhere-else" "$PROFILE/sessions/wap"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'ags already has a different wap' || return 1
    assert_not_exists "$PROFILE/sessions/wap@fix"
}

test_an_ags_session_running_leaves_the_shared_config_files() {
    make_fixture
    local before
    before=$(shasum < "$PROFILE/.claude/.claude.json")
    # Anything run from the profile's bin may rewrite .claude.json under us.
    bash -c "exec -a '$(physical "$PROFILE")/.local/bin/ags' sleep 30" &
    local pid=$!
    sleep 0.5
    run_move --session wap --apply || { kill "$pid"; echo "$OUT"; return 1; }
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    assert_output_contains "$OUT" 'an ags session is running' || return 1
    assert_eq "$before" "$(shasum < "$PROFILE/.claude/.claude.json")" || return 1
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'Claude project settings merged' || return 1
    assert_output_contains "$OUT" 'Codex trust added'
}

# The way back: ags-to-cs.py finds cs already has every folder, and brings the
# conversations ags went on with into ~/.claude.
test_round_trip_with_ags_to_cs() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf '{"n":"ags"}\n' >> "$PROFILE/.claude/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    local cs_root_before
    cs_root_before=$(fingerprint "$CSROOT")
    python3 "$BACK" --apply --session wap --session wap@feat --session wap@fix > "$TEST_TMPDIR/back.log" 2>&1 \
        || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/back.log" 'already in cs at .*claude-sessions/wap@feat' || return 1
    assert_eq "$cs_root_before" "$(fingerprint "$CSROOT")" "the way back changed cs's sessions" || return 1
    cmp -s "$PROFILE/.claude/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" \
        || { echo "  FAIL: the conversation ags went on with did not come back"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'Claude history of wap, 1 conversation(s): nothing new'
}

# What ags itself makes of the result: it lists both features and resumes each
# session's conversation from the profile's copy.
test_ags_opens_the_handed_over_session_and_its_features() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TEST_TMPDIR/claude-argv" > "$TEST_TMPDIR/claude"
    chmod +x "$TEST_TMPDIR/claude"
    local env_profile=(CS_SESSIONS_ROOT="$PROFILE/sessions" CS_TRANSCRIPTS_DIR="$PROFILE/.claude/projects"
        CLAUDE_CONFIG_DIR="$PROFILE/.claude" CS_CLAUDE_DIR="$PROFILE/.claude" CLAUDE_CODE_BIN="$TEST_TMPDIR/claude")
    local features
    features=$(env "${env_profile[@]}" "$AGS" wap -features --porcelain 2>&1) || { echo "$features"; return 1; }
    assert_output_contains "$features" 'feat' || return 1
    assert_output_contains "$features" 'fix' || return 1
    env "${env_profile[@]}" "$AGS" wap < /dev/null > "$TEST_TMPDIR/launch.log" 2>&1 \
        || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/claude-argv" "name wap --resume $WAP_ID" || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    env "${env_profile[@]}" "$AGS" wap@feat < /dev/null > "$TEST_TMPDIR/launch.log" 2>&1 \
        || { cat "$TEST_TMPDIR/launch.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/claude-argv" "name wap@feat --resume $FEAT_ID" || { cat "$TEST_TMPDIR/launch.log"; return 1; }
}

run_test test_dry_run_changes_nothing
run_test test_apply_hands_the_session_over_and_leaves_cs_as_it_is
run_test test_rerun_brings_over_only_what_grew
run_test test_a_session_open_in_cs_is_named_and_still_handed_over
run_test test_sessions_the_script_does_not_hand_over_say_why
run_test test_an_ags_session_running_leaves_the_shared_config_files
run_test test_round_trip_with_ags_to_cs
run_test test_ags_opens_the_handed_over_session_and_its_features
report_results
