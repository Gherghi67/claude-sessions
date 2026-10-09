#!/usr/bin/env bash
# ABOUTME: Tests for scripts/cs-to-ags.py, which gives ags its own copy of a project the stable cs adopted.
# ABOUTME: A fixture cs with an adopted project, two features, history and secrets, copied and re-synced into a profile.
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
    # Links into the project by absolute path, as some features have them.
    mkdir -p "$PROJECT/node_modules/pkg"
    printf 'pkg\n' > "$PROJECT/node_modules/pkg/index.js"
    printf 'A=1\n' > "$PROJECT/.env.x"
    ln -s "$CSROOT/wap/node_modules" "$CSROOT/wap@fix/node_modules"
    ln -s "$PROJECT/.env.x" "$CSROOT/wap@fix/.env.x"
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

# Where the copies land, by the physical path Claude Code keys its folders on.
ags_dir() {  # session name
    printf '%s/%s' "$(physical "$PROFILE/sessions")" "$1"
}

test_dry_run_changes_nothing() {
    make_fixture
    local cs_before profile_before
    cs_before=$(cs_side_fingerprint)
    profile_before=$(fingerprint "$PROFILE")
    run_move --session wap || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'would copy .*projects/wap to .*sessions/wap, with a repository of its own' || return 1
    assert_output_contains "$OUT" "wap@feat: would copy it to .*sessions/wap@feat, a worktree of ags's wap on cs/feat" || return 1
    assert_output_contains "$OUT" "wap@fix: would copy it to .*sessions/wap@fix, a worktree of ags's wap on wap-fix" || return 1
    assert_output_contains "$OUT" 'secrets of wap to copy: TOKEN' || return 1
    assert_output_contains "$OUT" "ags wap resumes conversation $WAP_ID" || return 1
    assert_output_contains "$OUT" 'Dry run: nothing changed' || return 1
    assert_output_not_contains "$OUT" 'link' || return 1
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1
    assert_eq "$profile_before" "$(fingerprint "$PROFILE")" "the profile changed"
}

test_apply_copies_the_session_and_leaves_cs_as_it_is() {
    make_fixture
    echo $$ > "$PROJECT/.cs/session.lock"
    # A git command and a process running in cs leave a lock and a pipe behind.
    : > "$PROJECT/.git/index.lock"
    mkfifo "$PROJECT/.cs/local/pipe"
    local cs_before
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || { echo "$OUT"; return 1; }

    # Not one byte of the cs side changed: folders, worktrees, history, settings, secrets.
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the cs side changed" || return 1

    # ags has its own copy and its own repository, which knows only its own worktrees.
    local wap feat fix
    wap=$(ags_dir wap); feat=$(ags_dir wap@feat); fix=$(ags_dir wap@fix)
    [ -d "$wap" ] && [ ! -L "$PROFILE/sessions/wap" ] || { echo "  FAIL: wap is not a folder of its own"; return 1; }
    [ ! -L "$PROFILE/sessions/wap@feat" ] || { echo "  FAIL: wap@feat is a link"; return 1; }
    assert_eq "$wap/.git" "$(cd "$feat" && cd -P "$(git rev-parse --git-common-dir)" && pwd)" || return 1
    assert_eq "$(printf '%s\n' "$wap" "$feat" "$fix")" \
        "$(git -C "$wap" worktree list --porcelain | sed -n 's/^worktree //p')" || return 1
    assert_file_not_exists "$wap/.cs/session.lock" || return 1
    assert_file_not_exists "$wap/.git/index.lock" "cs's git lock came along" || return 1
    assert_not_exists "$wap/.cs/local/pipe" "cs's pipe came along" || return 1
    assert_file_exists "$wap/app.js" || return 1

    # A feature keeps its branch, index, uncommitted, untracked and ignored files, and its own refs.
    assert_eq "cs/feat" "$(git -C "$feat" branch --show-current)" || return 1
    assert_eq "staged.txt" "$(git -C "$feat" diff --cached --name-only)" || return 1
    assert_file_contains "$feat/feature.txt" '^unstaged$' || return 1
    assert_file_exists "$feat/scratch.txt" || return 1
    assert_file_exists "$feat/node_modules/dep/index.js" || return 1
    # A link into cs's project points at ags's copy, so nothing writes through to cs.
    assert_eq "$PROFILE/sessions/wap/node_modules" "$(readlink "$fix/node_modules")" || return 1
    assert_eq "$PROFILE/sessions/wap/.env.x" "$(readlink "$fix/.env.x")" || return 1
    git -C "$feat" rev-parse -q --verify refs/worktree/cs/session/autosave >/dev/null \
        || { echo "  FAIL: the feature's own ref did not come along"; return 1; }
    assert_eq "$PROFILE/sessions/wap@feat/.cs/memory" \
        "$(jq -r .autoMemoryDirectory "$feat/.claude/settings.local.json")" || return 1
    assert_eq "$PROFILE/sessions/wap/.cs/memory" "$(jq -r .autoMemoryDirectory "$wap/.claude/settings.local.json")" || return 1
    assert_file_contains "$wap/CLAUDE.local.md" 'managed by the cs tool' || return 1

    # Conversations under the copies' folder names, with their side files.
    local projects="$PROFILE/.claude/projects"
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        || { echo "  FAIL: wap's conversation was not copied"; return 1; }
    assert_file_exists "$projects/$(project_key "$wap")/$WAP_ID/subagents/agent-1.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$feat")/$FEAT_ID.jsonl" || return 1
    assert_file_exists "$projects/$(project_key "$fix")/$FIX_ID.jsonl" || return 1
    assert_not_exists "$projects/$PROJECT_KEY" "a conversation stayed under cs's folder name" || return 1
    assert_file_exists "$PROFILE/.claude/file-history/$WAP_ID/snap@v1" || return 1
    assert_file_exists "$PROFILE/.claude/session-env/$WAP_ID/hook-1.sh" || return 1
    assert_file_exists "$PROFILE/.claude/tasks/wap/1.json" || return 1
    # History with no session comes too; another session's stays out.
    assert_file_exists "$projects/$OLD_KEY/$OLD_ID.jsonl" || return 1
    assert_file_exists "$projects/$SCRATCH_KEY/$SCRATCH_ID.jsonl" || return 1
    assert_not_exists "$projects/$OTHER_KEY" "wap-other's conversations came along" || return 1

    # Prompt history under the copies' paths; other sessions' stay out.
    local prompts="$PROFILE/.claude/history.jsonl"
    assert_eq "$wap" "$(jq -r 'select(.display == "main prompt") | .project' "$prompts")" || return 1
    assert_eq "$feat" "$(jq -r 'select(.display == "feature prompt") | .project' "$prompts")" || return 1
    assert_file_contains "$prompts" 'retired prompt' || return 1
    assert_file_not_contains "$prompts" 'other prompt' || return 1

    # Settings follow each path to its copy; the profile's own stay.
    local state="$PROFILE/.claude/.claude.json"
    assert_eq '["Bash(ls)"]' "$(jq -c --arg p "$wap" '.projects[$p].allowedTools' "$state")" || return 1
    assert_eq null "$(jq --arg p "$wap" '.projects[$p].lastCost' "$state")" || return 1
    assert_eq true "$(jq --arg p "$feat" '.projects[$p].hasTrustDialogAccepted' "$state")" || return 1
    assert_eq false "$(jq --arg p "$(physical "$PROJECT")" '.projects[$p].hasTrustDialogAccepted' "$state")" \
        "a profile setting was overwritten" || return 1
    assert_eq dark "$(jq -r .theme "$state")" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" "^\[projects.\"$feat\"\]" || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" "\"$FEAT_OLD\"" || return 1
    assert_file_contains "$PROFILE/.codex/config.toml" '^model = "y"' || return 1
    assert_file_not_contains "$PROFILE/.codex/config.toml" 'elsewhere' || return 1

    # Secrets reach ags-secrets on stdin; argv never carries a value.
    assert_eq "s3cret-value" "$(ags_secret wap TOKEN)" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 's3cret' "the value reached argv" || return 1
    assert_file_not_contains "$STUB_STORE/argv.log" 'backend=encrypted' "cs-secrets got the ags backend" || return 1

    jq -e 'select(.action == "copied-feature" and .session == "wap@feat")' "$PROFILE/.cs-to-ags/log.jsonl" >/dev/null \
        || { echo "  FAIL: the copy is not in the log"; return 1; }
    assert_file_exists "$PROFILE/.cs-to-ags/wap/record.json" || return 1
    assert_output_contains "$OUT" 'cs keeps wap as it was'
}

# What cs did after the first copy comes over where ags left the same thing
# alone; what ags did is kept; something both did keeps ags's and is said once.
test_rerun_brings_over_what_cs_changed_and_keeps_what_ags_changed() {
    make_fixture
    git -C "$PROJECT" branch topic main
    git -C "$PROJECT" commit -q --allow-empty -m 'main moves on'
    git -C "$PROJECT" branch -f topic main
    printf 'abcd\n' > "$PROJECT/same-size.txt"
    printf '#!/bin/sh\n' > "$PROJECT/tool.sh"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap feat
    wap=$(ags_dir wap); feat=$(ags_dir wap@feat)
    sleep 0.05

    # cs: an uncommitted edit, a commit on a feature, a new branch, a deletion,
    # a note, a new binding, a grown conversation.
    printf 'cs edit\n' >> "$PROJECT/app.js"
    printf 'wxyz\n' > "$PROJECT/same-size.txt"
    chmod +x "$PROJECT/tool.sh"
    printf 'committed in cs\n' > "$FEAT/later.txt"
    git -C "$FEAT" add later.txt
    git -C "$FEAT" commit -q -m 'cs commit'
    git -C "$PROJECT" branch cs/new main
    rm "$FEAT/scratch.txt"
    mkdir -p "$PROJECT/.cs/memory"
    printf 'cs note\n' > "$PROJECT/.cs/memory/note.md"
    sed -i.bak "s/^claude_session_id: .*/claude_session_id: $OTHER_ID/" "$PROJECT/.cs/local/state"
    rm "$PROJECT/.cs/local/state.bak"
    printf '{"n":3}\n' >> "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl"
    printf 'cs side\n' > "$PROJECT/both.txt"
    # A stat-dirty index: a git status here would rewrite cs's index.
    touch "$PROJECT/.gitignore"
    # A branch cs rewrote, a change staged only in cs, a setting cs added.
    git -C "$PROJECT" branch -f topic main~1
    printf 'staged in cs\n' > "$FEAT/staged2.txt"
    git -C "$FEAT" add staged2.txt
    jq '.cs_added = 1' "$FEAT/.claude/settings.local.json" > "$TEST_TMPDIR/s.json"
    cat "$TEST_TMPDIR/s.json" > "$FEAT/.claude/settings.local.json"
    # Both sides: the protocol file and a state key.
    printf 'cs line\n' >> "$PROJECT/CLAUDE.local.md"
    sed -i.bak 's/^engine: .*/engine: cs-side/' "$PROJECT/.cs/local/state"
    rm "$PROJECT/.cs/local/state.bak"
    # ags: its own file, its own state key, and the same file as cs.
    printf 'ags only\n' > "$wap/ags-notes.txt"
    printf 'claude_session_color: pink\n' >> "$wap/.cs/local/state"
    sed -i.bak 's/^engine: .*/engine: ags-side/' "$wap/.cs/local/state"
    rm "$wap/.cs/local/state.bak"
    printf 'ags side\n' > "$wap/both.txt"
    printf 'ags line\n' >> "$wap/CLAUDE.local.md"
    rm "$feat/node_modules/dep/index.js"

    local cs_before status=0
    cs_before=$(cs_side_fingerprint)
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" "a file changed on both sides was not reported" || { echo "$OUT"; return 1; }
    assert_eq "$cs_before" "$(cs_side_fingerprint)" "the rerun changed the cs side" || return 1
    assert_output_contains "$OUT" 'in ags at .*sessions/wap since an earlier run' || return 1
    assert_output_contains "$OUT" 'branches new in cs, added: cs/new' || return 1
    assert_output_contains "$OUT" "wap@feat: took cs's HEAD and index: cs/feat at " || return 1
    assert_output_contains "$OUT" "wap: kept ags's both.txt (added on both sides)" || return 1
    assert_output_contains "$OUT" "wap: kept ags's CLAUDE.local.md (changed on both sides)" || return 1
    assert_output_contains "$OUT" "wap: kept ags's .cs/local/state (engine changed on both sides)" || return 1
    assert_output_contains "$OUT" 'branches cs moved on, moved along: topic' || return 1
    assert_output_contains "$OUT" 'Claude history of wap, 1 conversation(s), files copied: 1 grown since the last copy' || return 1
    assert_output_contains "$OUT" 'secrets of wap ags already has: TOKEN' || return 1
    assert_output_not_contains "$OUT" 'prompt history' || return 1

    assert_file_contains "$wap/app.js" '^cs edit$' || return 1
    assert_file_contains "$wap/same-size.txt" '^wxyz$' "a change that kept the size did not come" || return 1
    [ -x "$wap/tool.sh" ] || { echo "  FAIL: a mode cs changed did not come"; return 1; }
    # A blob staged only in cs reached ags's repository, not just its index.
    assert_eq 'staged in cs' "$(git -C "$feat" show :staged2.txt 2>&1)" || return 1
    assert_file_contains "$wap/.cs/memory/note.md" 'cs note' || return 1
    assert_file_contains "$wap/ags-notes.txt" 'ags only' || return 1
    assert_file_contains "$wap/both.txt" 'ags side' || return 1
    assert_file_contains "$wap/.cs/local/state" "^claude_session_id: $OTHER_ID$" || return 1
    assert_file_contains "$wap/.cs/local/state" '^claude_session_color: pink$' || return 1
    assert_file_contains "$wap/.cs/local/state" '^engine: ags-side$' || return 1
    assert_file_contains "$wap/CLAUDE.local.md" '^ags line$' || return 1
    assert_file_not_contains "$wap/CLAUDE.local.md" '^cs line$' || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse topic)" "$(git -C "$wap" rev-parse topic)" "the branch cs rewrote" || return 1
    assert_eq 1 "$(jq .cs_added "$feat/.claude/settings.local.json")" "cs's new setting did not come" || return 1
    assert_eq "$PROFILE/sessions/wap@feat/.cs/memory" \
        "$(jq -r .autoMemoryDirectory "$feat/.claude/settings.local.json")" "the setting came under cs's path" || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse cs/new)" "$(git -C "$wap" rev-parse cs/new)" || return 1
    assert_eq "$(git -C "$FEAT" rev-parse HEAD)" "$(git -C "$feat" rev-parse HEAD)" || return 1
    assert_eq "$(git -C "$FEAT" rev-parse HEAD)" "$(git -C "$wap" rev-parse refs/remotes/cs/cs/feat)" || return 1
    assert_file_contains "$feat/later.txt" 'committed in cs' || return 1
    assert_file_not_exists "$feat/scratch.txt" || return 1
    assert_eq "$(git -C "$FEAT" status --porcelain)" "$(git -C "$feat" status --porcelain)" \
        "the feature's working state differs from cs's" || return 1
    cmp -s "$CLAUDE/projects/$PROJECT_KEY/$WAP_ID.jsonl" "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        || { echo "  FAIL: the grown conversation was not brought over"; return 1; }
    assert_eq 3 "$(wc -l < "$PROFILE/.claude/history.jsonl" | tr -d ' ')" "a rerun duplicated the prompt history" || return 1

    # Said once: the next rerun has nothing to report, and ags's side stays.
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: nothing new in cs' || return 1
    assert_output_not_contains "$OUT" '!' || return 1
    assert_file_contains "$wap/both.txt" 'ags side' || return 1
    assert_file_not_exists "$feat/node_modules/dep/index.js" "a file ags deleted came back"
}

test_git_moved_on_both_sides_is_left_and_reported_once() {
    make_fixture
    git -C "$PROJECT" branch side main
    git -C "$PROJECT" branch ff main
    printf 'old\n' > "$PROJECT/notes.txt"
    printf 'gone\n' > "$PROJECT/gone.txt"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap feat
    wap=$(ags_dir wap); feat=$(ags_dir wap@feat)
    sleep 0.05
    git -C "$FEAT" commit -q --allow-empty -m 'cs feature commit'
    git -C "$feat" commit -q --allow-empty -m 'ags feature commit'
    local ags_head
    ags_head=$(git -C "$feat" rev-parse HEAD)
    commit_on() {  # repo branch message
        local tree parent
        tree=$(git -C "$1" rev-parse "$2^{tree}"); parent=$(git -C "$1" rev-parse "$2")
        git -C "$1" update-ref "refs/heads/$2" "$(git -C "$1" commit-tree "$tree" -p "$parent" -m "$3")"
    }
    commit_on "$PROJECT" side 'cs side'
    commit_on "$wap" side 'ags side'
    # ff: ags moved it, and cs took that commit and went on from it.
    commit_on "$wap" ff 'ags on ff'
    git -C "$PROJECT" fetch -q "$wap" ff:ff
    commit_on "$PROJECT" ff 'cs on top'
    printf 'cs memory\n' > "$FEAT/.cs/cs-note.md"
    printf 'cs work\n' >> "$FEAT/feature.txt"
    # The project too: commits on main on both sides, and file changes in cs.
    git -C "$PROJECT" commit -q --allow-empty -m 'cs main'
    git -C "$wap" commit -q --allow-empty -m 'ags main'
    printf 'cs notes\n' > "$PROJECT/notes.txt"
    rm "$PROJECT/gone.txt"
    # Past the marks' 2 s margin, as between real runs.
    sleep 2.1
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: git left as ags has it' || return 1
    assert_file_contains "$wap/notes.txt" '^old$' "a file came over while git disagreed" || return 1
    assert_output_contains "$OUT" 'branch side moved on in both cs and ags; ags.s is kept, cs.s is at refs/remotes/cs/side' || return 1
    assert_output_contains "$OUT" 'wap@feat: git left as ags has it: HEAD or the index moved on both sides; only its .cs/ is brought over' || return 1
    assert_eq "$ags_head" "$(git -C "$feat" rev-parse HEAD)" || return 1
    assert_output_contains "$OUT" 'branches cs moved on, moved along: ff' || return 1
    assert_eq "$(git -C "$PROJECT" rev-parse ff)" "$(git -C "$wap" rev-parse ff)" || return 1
    assert_file_contains "$feat/.cs/cs-note.md" 'cs memory' || return 1
    assert_file_not_contains "$feat/feature.txt" 'cs work' "a tracked file came over onto ags's own commit" || return 1

    # Once git agrees again, what cs changed meanwhile comes over: nothing was dropped.
    git -C "$wap" reset -q --hard "$(git -C "$PROJECT" rev-parse main)"
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_not_contains "$OUT" '!' || return 1
    assert_file_contains "$wap/notes.txt" '^cs notes$' "cs's change made while git disagreed was dropped" || return 1
    assert_file_not_exists "$wap/gone.txt" "the path record lost what lies outside .cs/"
}

test_features_cs_starts_or_ends_and_ags_removes() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    add_feature late cs/late 88888888-8888-4888-8888-888888888888
    git -C "$PROJECT" worktree remove --force "$CSROOT/wap@fix"
    rm -rf "$PROFILE/sessions/wap@feat"
    git -C "$(ags_dir wap)" worktree prune
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap@late: copy it to .*sessions/wap@late, a worktree of ags's wap on cs/late" || return 1
    assert_output_contains "$OUT" 'wap@feat: ags removed its copy after an earlier run; not copied again' || return 1
    assert_output_contains "$OUT" 'wap@fix: cs no longer has it; ags keeps its copy' || return 1
    assert_eq "cs/late" "$(git -C "$(ags_dir wap@late)" branch --show-current)" || return 1
    assert_not_exists "$PROFILE/sessions/wap@feat" || return 1
    assert_dir "$PROFILE/sessions/wap@fix" || return 1

    # A feature on a commit no branch holds cannot become a worktree of ags's repository.
    local loose status=0
    loose=$(git -C "$PROJECT" commit-tree "$(git -C "$PROJECT" rev-parse 'main^{tree}')" -p main -m loose)
    git -C "$PROJECT" worktree add -q --detach "$CSROOT/wap@det" "$loose"
    mkdir -p "$CSROOT/wap@det/.cs/local"
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "wap@det: not copied: its detached HEAD ${loose:0:10} is on no branch the copy has" || return 1
    assert_not_exists "$PROFILE/sessions/wap@det"
}

# Without the paths both sides had, every file ags deleted would look new in cs.
test_a_lost_record_stops_the_sync() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    rm "$PROFILE/.cs-to-ags/wap/wap.paths.gz"
    rm "$(ags_dir wap)/app.js"
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "stopped: the record of wap's last sync has lost" || return 1
    assert_file_not_exists "$(ags_dir wap)/app.js" "a file ags deleted came back"
}

# cs execs claude in its place, which takes the lock with it: an engine or a
# session manager running in a folder shows the session is open. It is named,
# since what it writes later needs a rerun; the copy goes ahead.
test_a_session_open_in_cs_is_named_and_still_copied() {
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
    assert_dir "$PROFILE/sessions/wap@feat" || return 1
    assert_file_not_exists "$PROFILE/sessions/wap@feat/.cs/session.lock" "cs's lock came along" || return 1
    assert_file_exists "$PROFILE/.claude/projects/$(project_key "$(ags_dir wap)")/$WAP_ID.jsonl"
}

test_sessions_the_script_does_not_copy_say_why() {
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
    assert_output_contains "$OUT" 'wap@feat: not copied: ags already has a different wap@feat' || return 1
    assert_output_contains "$OUT" "wap@gone: not copied: not a registered worktree of wap's repository" || return 1
    assert_dir "$PROFILE/sessions/wap@fix" || return 1
    assert_not_exists "$PROFILE/sessions/wap@gone" || return 1

    rm -rf "$PROFILE/sessions"/* "$PROFILE/.cs-to-ags"
    ln -s "$PROJECT" "$PROFILE/sessions/wap"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || return 1
    assert_output_contains "$OUT" 'ags already has a different wap' || return 1
    assert_not_exists "$PROFILE/sessions/wap@fix" || return 1

    # A folder of that name this script did not copy is ags's own, not a copy to update.
    rm "$PROFILE/sessions/wap"
    mkdir -p "$PROFILE/sessions/wap/.cs"
    status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'ags already has a different wap' || return 1
    assert_not_exists "$PROFILE/sessions/wap/app.js"
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

# A secret is never overwritten: a value that differs is said, and kept.
test_a_secret_that_differs_is_reported_and_kept() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    printf 'changed-in-cs' > "$STUB_STORE/wap/TOKEN"
    local status=0
    run_move --session wap --apply || status=$?
    assert_eq 1 "$status" || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" "secret TOKEN of wap differs between cs and ags; ags's is kept" || return 1
    assert_output_not_contains "$OUT" 'changed-in-cs' || return 1
    assert_eq "s3cret-value" "$(ags_secret wap TOKEN)"
}

# The way back: ags-to-cs.py gives cs a copy of its own, and cs's original
# stays as it was.
test_round_trip_with_ags_to_cs() {
    make_fixture
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    local wap
    wap=$(ags_dir wap)
    printf '{"n":"ags"}\n' >> "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl"
    local project_before feat_before
    project_before=$(fingerprint "$PROJECT"); feat_before=$(fingerprint "$FEAT")
    python3 "$BACK" --apply --session wap --session wap@feat --session wap@fix > "$TEST_TMPDIR/back.log" 2>&1 \
        || { cat "$TEST_TMPDIR/back.log"; return 1; }
    assert_file_contains "$TEST_TMPDIR/back.log" 'wap -> cs wap-ags' || return 1
    assert_eq "$project_before" "$(fingerprint "$PROJECT")" "the way back changed cs's project" || return 1
    assert_eq "$feat_before" "$(fingerprint "$FEAT")" "the way back changed cs's feature" || return 1
    [ -d "$CSROOT/wap-ags" ] && [ ! -L "$CSROOT/wap-ags" ] || { echo "  FAIL: cs got no copy of its own"; return 1; }
    assert_eq "cs/feat" "$(git -C "$CSROOT/wap-ags@feat" branch --show-current)" || return 1
    cmp -s "$PROFILE/.claude/projects/$(project_key "$wap")/$WAP_ID.jsonl" \
        "$CLAUDE/projects/$(project_key "$(physical "$CSROOT")/wap-ags")/$WAP_ID.jsonl" \
        || { echo "  FAIL: the conversation ags went on with did not come back"; return 1; }
    run_move --session wap --apply || { echo "$OUT"; return 1; }
    assert_output_contains "$OUT" 'wap: files: nothing new in cs'
}

# What ags itself makes of the result: it lists both features and resumes each
# session's conversation from the profile's copy.
test_ags_opens_the_copied_session_and_its_features() {
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
run_test test_apply_copies_the_session_and_leaves_cs_as_it_is
run_test test_rerun_brings_over_what_cs_changed_and_keeps_what_ags_changed
run_test test_git_moved_on_both_sides_is_left_and_reported_once
run_test test_features_cs_starts_or_ends_and_ags_removes
run_test test_a_lost_record_stops_the_sync
run_test test_a_session_open_in_cs_is_named_and_still_copied
run_test test_sessions_the_script_does_not_copy_say_why
run_test test_an_ags_session_running_leaves_the_shared_config_files
run_test test_a_secret_that_differs_is_reported_and_kept
run_test test_round_trip_with_ags_to_cs
run_test test_ags_opens_the_copied_session_and_its_features
report_results
