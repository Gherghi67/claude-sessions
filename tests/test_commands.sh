#!/usr/bin/env bash
# ABOUTME: Content invariants for skills/*/SKILL.md (the four former commands included)
# ABOUTME: Guards single-source doctrine, engine-neutral helper paths, and frontmatter correctness

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

SKILLS_DIR="$SCRIPT_DIR/../skills"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
RELEASE_MD="$SCRIPT_DIR/../.claude/commands/release.md"

# ============================================================================
# Frontmatter correctness
# ============================================================================

test_checkpoint_allowed_tools_hyphenated() {
    assert_file_contains "$SKILLS_DIR/checkpoint/SKILL.md" "allowed-tools:" \
        "checkpoint.md must use the hyphenated allowed-tools key" || return 1
    assert_file_not_contains "$SKILLS_DIR/checkpoint/SKILL.md" "allowed_tools" \
        "the underscore form is silently ignored by Claude Code" || return 1
}

test_store_secret_has_frontmatter() {
    local first_line
    first_line=$(head -1 "$SKILLS_DIR/store-secret/SKILL.md")
    assert_eq "---" "$first_line" \
        "store-secret SKILL.md must open with a YAML frontmatter block" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "name: store-secret" \
        "frontmatter must declare the skill name" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "description:" \
        "frontmatter must declare a description (the activation trigger)" || return 1
}

test_store_secret_backend_neutral() {
    assert_file_not_contains "$SKILLS_DIR/store-secret/SKILL.md" "keychain" \
        "storage backend may be the encrypted-file fallback, not a keychain" || return 1
}

# ============================================================================
# Single-source doctrine: sweep owns the memory bar, summary owns the
# skeleton and prose gate, the prose-hygiene skill owns the scoring rubric
# ============================================================================

test_no_dangling_bucket_guidance_reference() {
    # The CLAUDE.md bucket-guidance table was retired in v2026.5.5 (bin/cs
    # Phase 9 strips it); no skill may still point at it.
    local hits
    hits=$(grep -l "bucket-guidance" "$SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no skill may reference the retired CLAUDE.md bucket-guidance table" || return 1
}

test_sweep_owns_bucket_routing_table() {
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" 'user_\*.md' \
        "sweep.md must carry the bucket routing table (user row)" || return 1
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" 'reference_\*.md' \
        "sweep.md must carry the bucket routing table (reference row)" || return 1
}

test_sweep_routes_discovered_constraints() {
    # The project_* bucket is dominated by constraints found through work, not user
    # utterances. sweep must route them and must NOT blanket-drop them as "just a discovery".
    assert_file_not_contains "$SKILLS_DIR/sweep/SKILL.md" "that's a discovery, not a memory" \
        "the blanket 'discovery is not a memory' exclusion drops the project_* class" || return 1
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "discover while working" \
        "sweep must carry a routing path for constraints discovered through work" || return 1
}

test_sweep_updates_memory_index() {
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "MEMORY.md" \
        "sweep.md must instruct updating the MEMORY.md index after writing an entry" || return 1
}

test_wrap_family_pinned_to_opus() {
    # Distilling a whole session's documentation into what is worth keeping is
    # judgment work, and the summary is the artifact the session is remembered
    # by, so these three passes run on the strongest model.
    # The family alias, not a point release: `claude-opus-5` would keep an
    # older Opus once a newer one ships.
    local cmd
    for cmd in wrap sweep summary; do
        assert_file_contains "$SKILLS_DIR/$cmd/SKILL.md" "^model: opus$" \
            "$cmd must pin the opus family, not a point release, in frontmatter" || return 1
        if [ "$(head -1 "$SKILLS_DIR/$cmd/SKILL.md")" != "---" ]; then
            echo "  FAIL: $cmd must open with a YAML frontmatter block"
            return 1
        fi
    done
}

# wrap reads its passes from the sibling skills wherever this engine deployed
# them. A ~/.claude path resolves against the real HOME, which under the ags
# profile is the stable cs install, and under Codex is no install at all.
test_wrap_references_sibling_skills() {
    assert_file_contains "$SKILLS_DIR/wrap/SKILL.md" '`../sweep/SKILL.md`' \
        "wrap must read the sweep skill beside its own directory" || return 1
    assert_file_contains "$SKILLS_DIR/wrap/SKILL.md" '`../summary/SKILL.md`' \
        "wrap must read the summary skill beside its own directory" || return 1
    assert_file_not_contains "$SKILLS_DIR/wrap/SKILL.md" 'commands/' \
        "the passes are skills now, never command files" || return 1
}

# The guard ships inside the sweep skill, so sweep runs it relative to its own
# directory, and must take the snapshot that check and restore compare against.
test_sweep_runs_the_memory_index_guard() {
    local sub
    for sub in snapshot check restore; do
        assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "bash <skill-dir>/scripts/memory-index-guard.sh $sub" \
            "sweep must run its bundled guard's $sub" || return 1
    done
    assert_file_contains "$SCRIPT_DIR/../lib/01-manifests.sh" "^    sweep/scripts/memory-index-guard.sh$" \
        "the guard must ship as a sweep skill file for that path to exist" || return 1
    [ -f "$SKILLS_DIR/sweep/scripts/memory-index-guard.sh" ] \
        || { echo "  FAIL: skills/sweep/scripts/memory-index-guard.sh missing"; return 1; }
}

# Every shipped skill reaches its helpers through its own directory or an ags
# verb. A path under ~/.claude names whichever install owns the real HOME: the
# stable cs under the ags profile, nothing at all under Codex.
test_no_skill_names_a_claude_home_path() {
    local hits
    hits=$(grep -lE '~/\.claude/|\$HOME/\.claude/(skills|commands|hooks)' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)
    assert_eq "" "$hits" \
        "no SKILL.md may name a ~/.claude path for a helper" || return 1
}

# A skill that relies on an adapter feature asks the session manager first and
# refuses cleanly, rather than half-running under an engine that lacks it.
test_skills_check_adapter_capabilities_before_use() {
    assert_file_contains "$SKILLS_DIR/rotate/SKILL.md" 'ags -engine supports rotation' \
        "rotate must check the rotation capability" || return 1
    assert_file_contains "$SKILLS_DIR/feature/SKILL.md" 'ags -engine supports spawn_brief' \
        "feature must check the spawn_brief capability" || return 1
    assert_file_contains "$SKILLS_DIR/feature/SKILL.md" 'ags -engine supports mail_delivery' \
        "feature must say where the result mail surfaces" || return 1
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" 'ags -engine supports memory_index' \
        "sweep must say which engines load the index" || return 1
    local hits
    hits=$(grep -l 'CLAUDE_SESSION_NAME' "$SKILLS_DIR"/*/SKILL.md 2>/dev/null || true)
    assert_eq "" "$hits" "skills read the neutral CS_SESSION_NAME, not the Claude alias" || return 1
}

# Forced rotation is on by default (80%), and while it is on the mod counts
# down after ANY armed handoff, a hand-run /rotate included; only
# CS_ROTATE_FORCE_CTX=off leaves the /clear to the person.
test_rotate_describes_the_default_countdown() {
    assert_file_not_contains "$SKILLS_DIR/rotate/SKILL.md" 'The keystroke is theirs unless' \
        "the pre-2026.9.18 'only with CS_ROTATE_FORCE_CTX' sentence is stale" || return 1
    assert_file_contains "$SKILLS_DIR/rotate/SKILL.md" 'CS_ROTATE_FORCE_CTX=off' \
        "the skill must name the switch that turns the countdown off" || return 1
    assert_file_contains "$SKILLS_DIR/rotate/SKILL.md" 'whether or not the rotation was forced' \
        "the countdown follows a hand-run /rotate too" || return 1
}

# Under Codex no turn starts by itself after /clear, and there is no capsule
# or countdown, so the skill's closing line has a Codex form that says to send
# a message. Claude's line stays exactly as it was.
test_rotate_names_the_codex_closing_line() {
    local skill="$SKILLS_DIR/rotate/SKILL.md"
    assert_file_contains "$skill" '\*\*Run `/clear` now, then send `go`\*\* — this conversation is ready to rotate.' \
        "the Codex form of the final line" || return 1
    assert_file_contains "$skill" 'Codex starts no turn by itself' \
        "step 10 says why the message is needed" || return 1
    assert_file_not_contains "$skill" 'only the Claude adapter declares' \
        "Codex declares rotation now" || return 1
}

# switch ends the conversation it runs in, so it runs only when the user asks:
# Claude reads disable-model-invocation in the frontmatter, Codex ignores it
# and reads its own policy beside SKILL.md.
test_switch_is_user_invoked_only() {
    local skill="$SKILLS_DIR/switch/SKILL.md" front
    front=$(awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$skill" 2>/dev/null)
    grep -qx 'name: switch' <<< "$front" \
        || { echo "  FAIL: switch/SKILL.md's frontmatter must declare name: switch"; return 1; }
    grep -qx 'disable-model-invocation: true' <<< "$front" \
        || { echo "  FAIL: switch must be user-invoked only on Claude (disable-model-invocation: true)"; return 1; }
    grep -q '^description: .*Invoke only when the user asks to switch engines\.$' <<< "$front" \
        || { echo "  FAIL: switch's description must say it is invoked only when the user asks"; return 1; }
    assert_file_contains "$SKILLS_DIR/switch/agents/openai.yaml" '^policy:$' \
        "switch's openai.yaml must nest the switch under policy" || return 1
    assert_file_contains "$SKILLS_DIR/switch/agents/openai.yaml" '^  allow_implicit_invocation: false$' \
        "Codex must not invoke switch on its own" || return 1
}

# Nothing is written before ags says the switch can happen: a handoff armed for
# a switch that cannot happen is armed for a /clear nobody asked for. Running
# background work refuses too, since the exit would cut it off.
test_switch_checks_before_writing() {
    local skill="$SKILLS_DIR/switch/SKILL.md" check_at rotate_at record_at
    check_at=$(grep -n -x -F 'ags -switch --check <target>' "$skill" | head -1 | cut -d: -f1)
    rotate_at=$(grep -n -F '`../rotate/SKILL.md`' "$skill" | head -1 | cut -d: -f1)
    record_at=$(grep -n -x -F '   ags -switch <target>' "$skill" | head -1 | cut -d: -f1)
    if [ -z "$check_at" ] || [ -z "$rotate_at" ] || [ -z "$record_at" ]; then
        echo "  FAIL: switch must run 'ags -switch --check <target>', read rotate's steps, then run 'ags -switch <target>'"
        return 1
    fi
    [ "$check_at" -lt "$rotate_at" ] && [ "$rotate_at" -lt "$record_at" ] \
        || { echo "  FAIL: the check (line $check_at) must come before rotate's steps (line $rotate_at), and the record (line $record_at) after them"; return 1; }
    assert_file_contains "$skill" 'BEFORE writing anything' \
        "the check must be placed before anything is written" || return 1
    assert_file_contains "$skill" 'and stop: no handoff,' \
        "a refused check must stop the skill with nothing written" || return 1
    assert_file_contains "$skill" '^Refuse, and write nothing, while anything this conversation started in the$' \
        "switch must refuse while this conversation's background work runs" || return 1
    assert_file_contains "$skill" 'background agents, workflows, monitors,' \
        "the refusal must name the background work an exit would cut off" || return 1
}

# rotate stays the single source of the handoff ritual: switch reads its steps
# 1-9 from the skill beside it and never restates them, and drops rotate's
# /clear ending, which would hand the handoff to the same engine.
test_switch_runs_rotates_steps_by_reference() {
    local skill="$SKILLS_DIR/switch/SKILL.md"
    assert_file_contains "$skill" '`../rotate/SKILL.md`, relative to the folder this' \
        "switch must read rotate beside its own directory" || return 1
    assert_file_contains "$skill" "Run rotate's Process steps 1-9 exactly as its file writes them" \
        "switch must run rotate's steps 1-9 as rotate writes them" || return 1
    assert_file_contains "$skill" "Do not run rotate's steps 10 and 11" \
        "rotate's /clear ending must be replaced, not run" || return 1
    assert_file_contains "$skill" 'purpose: Continue under <target>: <next step>' \
        "the handoff's purpose names the move" || return 1
    assert_file_not_contains "$skill" 'Build the ledger before you write any prose' \
        "the ledger rule stays in rotate's file alone" || return 1
    assert_file_not_contains "$skill" 'check-ignore' \
        "the staging rule stays in rotate's file alone" || return 1
}

# switch names rotate's steps by number (1-9 run, 10 and 11 replaced), so a
# renumbered rotate must fail here rather than leave switch arming nothing.
test_switch_step_numbers_match_rotate() {
    local rotate="$SKILLS_DIR/rotate/SKILL.md" skill="$SKILLS_DIR/switch/SKILL.md"
    assert_file_contains "$rotate" '^9\. Arm it, LAST' \
        "rotate's step 9 must still be the arming step switch runs last" || return 1
    assert_file_contains "$rotate" '^10\. Tell the user what the rotation now does' \
        "rotate's step 10 must still be the /clear explanation switch replaces" || return 1
    assert_file_contains "$rotate" '^11\. End your response with the instruction' \
        "rotate's step 11 must still be the final line switch replaces" || return 1
    if grep -q '^12\. ' "$rotate"; then
        echo "  FAIL: rotate gained a step 12; switch's 'steps 10 and 11' no longer covers its ending"
        return 1
    fi
    assert_file_contains "$skill" "rotate's step 9 did not land" \
        "a late 'no handoff armed' refusal must send the model back to rotate's step 9" || return 1
}

# Each engine has its own way out, and the last line is the one instruction the
# user must act on, so both lines are pinned exactly.
test_switch_names_both_final_lines() {
    local skill="$SKILLS_DIR/switch/SKILL.md"
    grep -qxF '   **Run `/exit` now** (or press `1` on the capsule above the prompt) — ags reopens this session under Codex.' "$skill" \
        || { echo "  FAIL: switch must end, under Claude, on the exact /exit line"; return 1; }
    grep -qxF '   **Quit Codex now (`/quit`)** — ags reopens this session under Claude.' "$skill" \
        || { echo "  FAIL: switch must end, under Codex, on the exact /quit line"; return 1; }
    assert_file_contains "$skill" 'CS_ROTATE_FORCE_CTX=off' \
        "the skill must name the switch that turns the mod's /exit countdown off" || return 1
    assert_file_contains "$skill" 'ags -switch cancel' \
        "the skill must say how to call a recorded switch off" || return 1
}

# Codex hands a skill no arguments, and Claude would replace the placeholder
# with the user's arguments wherever the file names it, so the skill reads the
# target from the user's message and never spells the placeholder.
test_switch_reads_its_arguments_from_the_message() {
    local skill="$SKILLS_DIR/switch/SKILL.md"
    assert_file_contains "$skill" '^Codex hands a skill no arguments' \
        "switch must say Codex passes no arguments" || return 1
    assert_file_contains "$skill" "read them from the user's message" \
        "switch must read the target and --resume from the user's message" || return 1
    assert_file_not_contains "$skill" 'ARGUMENTS' \
        "the placeholder must not appear: Claude substitutes it, Codex never does" || return 1
}

# The skill tells the user the new conversation starts by itself under either
# engine. That holds while both launches pass the handoff as their opening
# prompt; if a launch stops doing so, the claim (and this test) must change.
test_switch_says_the_new_conversation_starts_itself() {
    assert_file_contains "$SKILLS_DIR/switch/SKILL.md" 'to type, not even `go`' \
        "switch must say nothing needs typing after the relaunch" || return 1
    grep -qF 'resume "$thread_id" -C "$session_dir" ${kick:+"$kick"}' "$SCRIPT_DIR/../lib/76-codex.sh" \
        || { echo "  FAIL: the Codex launch no longer passes the handoff kick as its starting prompt"; return 1; }
    grep -qF 'handoff_arg="Continue from the pending rotation handoff: read .cs/handoffs/$handoff first."' "$SCRIPT_DIR/../lib/42-claude-state.sh" \
        || { echo "  FAIL: the Claude fresh launch no longer passes the handoff as its launch prompt"; return 1; }
}

# The four former commands are skills: each declares its name and the
# description an engine lists it by.
test_former_commands_are_skills() {
    local cmd
    for cmd in checkpoint summary sweep wrap; do
        assert_file_contains "$SKILLS_DIR/$cmd/SKILL.md" "^name: $cmd$" \
            "$cmd/SKILL.md must declare its name" || return 1
        assert_file_contains "$SKILLS_DIR/$cmd/SKILL.md" "^description: " \
            "$cmd/SKILL.md must declare a description" || return 1
    done
    [ ! -d "$SCRIPT_DIR/../commands" ] \
        || { echo "  FAIL: commands/ must be gone; every former command ships as a skill"; return 1; }
}

# Codex accepts disable-model-invocation in SKILL.md and ignores it, so a skill
# meant to run only when the user asks needs Codex's own switch beside it, and
# the installer has to ship that file to both engines.
test_explicit_only_skills_ship_a_codex_policy() {
    local manifest="$SCRIPT_DIR/../lib/01-manifests.sh" skill_md skill found=0
    for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
        awk 'NR==1&&/^---$/{f=1;next} f&&/^---$/{exit} f' "$skill_md" \
            | grep -qx 'disable-model-invocation: true' || continue
        found=1
        skill=$(basename "$(dirname "$skill_md")")
        assert_file_contains "$SKILLS_DIR/$skill/agents/openai.yaml" '^  allow_implicit_invocation: false$' \
            "$skill is explicit-only, so Codex needs policy.allow_implicit_invocation: false" || return 1
        assert_file_contains "$SKILLS_DIR/$skill/agents/openai.yaml" '^policy:$' \
            "$skill's openai.yaml must nest the switch under policy" || return 1
        assert_file_contains "$manifest" "^    $skill/agents/openai.yaml" \
            "CS_SKILL_FILES must ship $skill/agents/openai.yaml" || return 1
    done
    assert_eq 1 "$found" "finish at least is explicit-only; the frontmatter scan found none" || return 1
}

test_wrap_does_not_duplicate_memory_bars() {
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "three months" \
        "sweep.md owns the three-bar discipline" || return 1
    assert_file_not_contains "$SKILLS_DIR/wrap/SKILL.md" "three months" \
        "wrap.md must reference the bars, not restate them" || return 1
}

test_wrap_does_not_duplicate_summary_skeleton() {
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "# Session Summary:" \
        "summary.md owns the summary skeleton" || return 1
    assert_file_not_contains "$SKILLS_DIR/wrap/SKILL.md" "# Session Summary:" \
        "wrap.md must reference the skeleton, not embed a second copy" || return 1
}

test_scoring_threshold_owned_by_skill() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "35/50" \
        "the prose-hygiene skill owns the revise threshold" || return 1
    local hits
    hits=$(grep -l "35/50" "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | grep -v '/prose-hygiene/' || true)
    assert_eq "" "$hits" \
        "no other skill may restate the prose-hygiene 35/50 threshold" || return 1
}

# ============================================================================
# Correctness strays
# ============================================================================

test_summary_reads_narrative() {
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" 'memory/narrative\.<actor>\.md' \
        "summary must read the per-actor session narratives" || return 1
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "your own in full; a teammate's only from the line the resume digest named" \
        "summary reads its own narrative whole and a teammate's by the digest delta, never the whole file" || return 1
}

test_prose_critic_pinned_and_contracted() {
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "model: opus" \
        "the prose critic is a quality-judge task and must pin a capable tier" || return 1
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "final message" \
        "the critic's deliverable must be demanded in its final message" || return 1
    # The critic scores; the caller decides. A judge asked for its own verdict
    # grades to the bar it was told, so the pass criterion stays out of its
    # output contract and the comparison happens in summary.md.
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "the critic scores, it does not decide" \
        "the critic must return scores and rewrites only, no verdict line" || return 1
    if grep -q 'PASS\|REVISE' "$SKILLS_DIR/summary/SKILL.md"; then
        echo "  FAIL: summary.md still asks the critic for a PASS/REVISE verdict"; return 1
    fi
}

test_prose_hygiene_has_modes_and_technical_carveout() {
    # A cold Skill invocation must be able to tell drafting from reviewing, and the
    # absolutist rules must not flag correct technical sentences (summary.md applies EVERY rule).
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "## How to apply" \
        "the skill must surface drafting-vs-reviewing modes, not bury them in prose" || return 1
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "not false agency" \
        "the skill must carve out technical subjects from the false-agency/absolutist rules" || return 1
}

test_release_names_uninstall_source_not_bincs() {
    # run_uninstall lives in a lib/ fragment and bin/cs is assembled — the runbook must
    # name the editable source, since Step 1 and Important both forbid editing bin/cs.
    assert_file_contains "$RELEASE_MD" "lib/85-adopt-uninstall.sh" \
        "release.md must name the editable run_uninstall source, not bin/cs" || return 1
}

test_release_changelog_step_follows_approval() {
    # The changelog insertion needs the approved notes, so its step must come AFTER the
    # notes/approval step in the file — not forward-reference a later step.
    local notes_line changelog_line
    notes_line=$(grep -n 'Generate Release Notes' "$RELEASE_MD" | head -1 | cut -d: -f1)
    changelog_line=$(grep -n 'Update Changelog' "$RELEASE_MD" | head -1 | cut -d: -f1)
    if [ -z "$notes_line" ] || [ -z "$changelog_line" ]; then
        echo "  FAIL: could not find both the notes and changelog step headers"; return 1
    fi
    if [ "$changelog_line" -le "$notes_line" ]; then
        echo "  FAIL: 'Update Changelog' (line $changelog_line) must follow 'Generate Release Notes' (line $notes_line)"; return 1
    fi
}

test_prose_hygiene_records_upstream_sync() {
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "synced at upstream" \
        "the skill must record which stop-slop commit it was synced against" || return 1
}

# ============================================================================
# med+low finding invariants: summary / wrap / checkpoint / sweep guardrails
# ============================================================================

test_summary_replaces_existing_file() {
    # /summary run standalone must not stall deciding whether to overwrite a
    # pre-existing summary; the replace rule lives in summary.md, not only wrap.md.
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "already exists, replace it" \
        "summary.md step 3 must say to replace a pre-existing .cs/summary.md" || return 1
}

test_summary_bounds_git_log_to_session() {
    # 'derive from git history' is unbounded; the file list must be scoped to this
    # session via the timeline's earliest started timestamp, not the whole repo.
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "git log --since" \
        "summary.md must bound the git log to the session, not the whole repo history" || return 1
}

test_summary_prose_loop_is_bounded() {
    # The apply/re-run critic loop must terminate: one re-run cap, stop regardless of
    # the second verdict — otherwise the model loops or stalls below threshold.
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "stop regardless" \
        "summary.md must cap the critic loop so it terminates" || return 1
}

test_wrap_report_is_not_two_line() {
    # 'two-line report' contradicts item 1's 'one path per line' once Pass 1 wrote
    # more than one file; the report must be sectioned, not line-capped.
    assert_file_not_contains "$SKILLS_DIR/wrap/SKILL.md" "two-line" \
        "wrap.md must not cap the report at two lines (item 1 lists one path per line)" || return 1
}

test_checkpoint_routes_reserved_subcommands() {
    # run_checkpoint reserves list/ls/show; '/checkpoint list' must route to the
    # subcommand, not save a checkpoint labelled 'list' and report a phantom save.
    assert_file_contains "$SKILLS_DIR/checkpoint/SKILL.md" "Route reserved words to the matching subcommand" \
        "checkpoint.md must route list/ls/show to their subcommands instead of saving a label" || return 1
}

test_checkpoint_quotes_label_and_stops_on_failure() {
    # A label with a double quote, $, or backtick breaks or injects under double quotes;
    # single-quote it, and never silently retry a failed save.
    assert_file_contains "$SKILLS_DIR/checkpoint/SKILL.md" "single-quoting the label" \
        "checkpoint.md must single-quote the label, not double-quote it" || return 1
    assert_file_contains "$SKILLS_DIR/checkpoint/SKILL.md" "do not retry" \
        "checkpoint.md must stop (not retry) when ags -checkpoint fails" || return 1
}

test_sweep_supersedes_stale_entries() {
    # 'skip; do not append' with no supersede path leaves reversed/refined facts stale
    # forever; a contradicting or extending fact must update the entry in place.
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "contradicts or materially extends" \
        "sweep.md must give a supersede/update-in-place path, not only skip-or-duplicate" || return 1
}

test_sweep_states_filename_convention() {
    # The <bucket>_<short_slug>.md convention was only implied by the glob; a first
    # entry in an empty bucket needs it stated explicitly.
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "<bucket>_<short_slug>.md" \
        "sweep.md must state the memory-entry filename convention" || return 1
}

test_sweep_scopes_when_not_to_write() {
    # The exclusion section must be scoped to the strict buckets so it does not
    # suppress the looser-bar narrative appends step 4 invites.
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "strict-bucket entry" \
        "sweep.md 'When NOT to write' must scope to the strict buckets, not the narrative" || return 1
}

test_sweep_states_memory_pointer_format() {
    # 'Add a one-line pointer' with no format leaves the model to invent the MEMORY.md
    # line shape; it must match the existing [title](file.md) format.
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" '\[title\](file.md)' \
        "sweep.md must state the MEMORY.md pointer format" || return 1
}

test_sweep_resolves_actor_before_narrative_append() {
    # ags -whoami resolution must be repeated at the narrative step, not left only in the
    # framing parenthetical, so a multi-actor session appends to the right file.
    local count
    count=$(grep -c "ags -whoami" "$SKILLS_DIR/sweep/SKILL.md" || true)
    if [ "$count" -lt 2 ]; then
        echo "  FAIL: sweep.md must repeat 'ags -whoami' in the narrative step (found $count)"
        return 1
    fi
}

test_sweep_adds_check_tasks_and_keeps_the_entry() {
    # A rule-shaped entry usually carries the incident or measurement behind the rule,
    # which a check's failure message would lose, so a check that can carry the rule
    # becomes a task beside the entry, never a replacement for it.
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "Could a check carry it instead" \
        "the sweep skill must ask whether a mechanical check could carry a rule" || return 1
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "add a task to build it and keep the memory entry as written" \
        "the sweep skill must add a task for the check and keep the memory entry, never replace it" || return 1
}

# ============================================================================
# lane 1b: store-secret guardrails, prose-hygiene scoring contract, release runbook
# ============================================================================

test_store_secret_opener_softened_and_stops_on_nothing() {
    # The skill fires proactively and misfires on docs/examples; the opener must not
    # assert detection as fact, and there must be a 'nothing qualifies' stop branch so a
    # primed model does not strain to store a non-secret.
    assert_file_not_contains "$SKILLS_DIR/store-secret/SKILL.md" "You detected that the user shared" \
        "the opener must not assert detection as established fact (the skill misfires)" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "nothing was stored and stop" \
        "the skill must have a stop branch for when every candidate is a placeholder/example" || return 1
}

test_store_secret_guards_silent_overwrite() {
    # cs -secrets set replaces an existing name silently; names are inferred, so two
    # keys can collide. The skill must warn before overwriting.
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "replaces an existing value silently" \
        "the skill must state that set overwrites silently" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "before overwriting" \
        "the skill must tell the model to confirm/rename before overwriting a colliding name" || return 1
}

test_store_secret_non_session_warns_and_forbids_file() {
    # The non-cs-session branch must not dead-end at 'skip storage' leaving a live
    # credential in chat with no guidance, and must forbid the file-write fallback.
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "conversation history" \
        "the non-session branch must warn the credential is now in the chat history" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "NEVER write the value to a project file" \
        "the non-session branch must forbid writing the secret to a project file" || return 1
}

test_store_secret_confirms_only_on_success() {
    # Step 5 must gate its success message on the set command actually succeeding, not
    # report success blindly if set errored (missing backend, session mismatch).
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "Stored secret: NAME" \
        "step 5 must key confirmation off the real success string set prints" || return 1
    assert_file_contains "$SKILLS_DIR/store-secret/SKILL.md" "report the failure" \
        "step 5 must report failure rather than claim a secret was stored" || return 1
}

test_prose_hygiene_scoring_reports_either_way_and_defers_revision() {
    # The Scoring section's bare 'means revise' left who-revises/what-to-output/loop
    # unstated. The skill judges only (revising + the loop are the caller's, single-source
    # in summary.md); it must report the total whether or not it passes.
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "This skill only judges" \
        "scoring must state the skill judges only and reports the total either way" || return 1
    assert_file_contains "$SKILLS_DIR/prose-hygiene/SKILL.md" "belong to the caller" \
        "scoring must defer revising and the re-score loop to the caller (judge-only)" || return 1
}

test_release_has_branch_sync_preflight() {
    # Without a starting precondition the runbook will bump/commit/tag from a feature
    # branch or a stale main; a preflight must check branch and origin sync.
    assert_file_contains "$RELEASE_MD" "git status -sb" \
        "release.md must show a branch/ahead-behind preflight before Step 1" || return 1
    assert_file_contains "$RELEASE_MD" "up to date with origin" \
        "release.md must require being on main and up to date with origin before proceeding" || return 1
}

test_release_doc_review_has_procedure() {
    # The doc review is called 'the most important part' but was stated only as goals;
    # it must carry a concrete grep-against-source procedure and a required per-file report.
    assert_file_contains "$RELEASE_MD" "do not skim" \
        "the doc review must give a concrete verification procedure, not just goals" || return 1
    assert_file_contains "$RELEASE_MD" "issues found / fixed" \
        "the doc review must require an auditable per-file report" || return 1
}

test_release_empty_diff_expected_when_committed() {
    # The empty-diff caveat conflated the working-tree diff with release content; when
    # release work was committed earlier (the normal case) an empty /simplify diff is not
    # an anomaly. The caveat must say so and must not send the model chasing a non-anomaly.
    assert_file_contains "$RELEASE_MD" "already committed in earlier sessions" \
        "the empty-diff caveat must treat committed-earlier as the expected case" || return 1
    assert_file_not_contains "$RELEASE_MD" "zero code changes is unusual" \
        "the misleading 'zero code changes is unusual' framing must be gone" || return 1
}

test_release_handles_empty_prev_tag() {
    # If no v* tag exists (first release / failed fetch) PREV_TAG is empty and
    # git log ""..HEAD errors; the runbook must branch to a first-release path.
    assert_file_contains "$RELEASE_MD" "is empty (first release" \
        "release.md must handle an empty PREV_TAG as a first release" || return 1
}

test_release_approval_has_cancel_and_reapproval_loop() {
    # The approval gate offered only Approve/Edit with no abort and no restated loop;
    # it must add a cancel path and require re-approval after edits.
    assert_file_contains "$RELEASE_MD" "Cancel release" \
        "the approval gate must offer an abort path" || return 1
    assert_file_contains "$RELEASE_MD" "looping until you get an explicit" \
        "the approval gate must re-confirm after edits, not treat Edit as approval" || return 1
}

test_release_guards_stray_files_before_add_all() {
    # git add -A after git status had no branch for stray untracked files; the runbook
    # must tell the model to stage release files explicitly when status shows strays.
    assert_file_contains "$RELEASE_MD" "files unrelated to" \
        "release.md must handle stray files that git status reveals" || return 1
    assert_file_contains "$RELEASE_MD" "stage the release files explicitly" \
        "release.md must say to stage explicitly (not -A) when strays are present" || return 1
}

test_release_verifies_ci_workflow() {
    # 'gh release create' returning is not the finish line; the signing/upload workflow can
    # still fail. The runbook must verify the workflow and the signed assets landed.
    assert_file_contains "$RELEASE_MD" "Verify the Release Workflow Succeeded" \
        "release.md must add a step to confirm the CI release workflow succeeded" || return 1
    assert_file_contains "$RELEASE_MD" "release is not done until" \
        "release.md must gate 'done' on the .minisig and install.sh assets appearing" || return 1
}

# ============================================================================
# Runner
# ============================================================================
echo "Running test_commands.sh"
echo ""

# /wrap's last pass marks the conversation it ran in, so the rotate band stops
# offering a wrap that already finished. The command is run exactly as the file
# spells it. It writes the running conversation's own id (a teammate's wrap
# names the teammate, never the lead), and with no id to write it writes nothing
# and still succeeds, since a wrap outside Claude Code has no band to hide.
test_wrap_marks_the_wrapped_conversation() {
    local block dir
    block=$(awk '/^## Pass 4/{p=1; next} /^## /{p=0} p && /^```/{f=!f; next} p && f' "$SKILLS_DIR/wrap/SKILL.md")
    [ -n "$block" ] || { echo "  FAIL: wrap.md has no Pass 4 command block"; return 1; }
    dir="$TEST_TMPDIR/wrapped"
    mkdir -p "$dir/.cs/local"
    printf 'claude_session_id: 99999999-9999-4999-8999-999999999999\n' > "$dir/.cs/local/state"
    (cd "$dir" && CLAUDE_CODE_SESSION_ID=11111111-2222-4333-8444-555555555555 bash -c "$block") \
        || { echo "  FAIL: the Pass 4 command failed"; return 1; }
    assert_eq "11111111-2222-4333-8444-555555555555" "$(cat "$dir/.cs/local/wrapped")" \
        "the marker names the conversation the wrap ran in, not the state's lead" || return 1
    rm -f "$dir/.cs/local/wrapped"
    (cd "$dir" && env -u CLAUDE_CODE_SESSION_ID bash -c "$block") \
        || { echo "  FAIL: the Pass 4 command must succeed with no conversation id"; return 1; }
    assert_not_exists "$dir/.cs/local/wrapped" "no id, no marker" || return 1
}

run_test test_checkpoint_allowed_tools_hyphenated
run_test test_store_secret_has_frontmatter
run_test test_store_secret_backend_neutral
run_test test_no_dangling_bucket_guidance_reference
run_test test_sweep_owns_bucket_routing_table
run_test test_sweep_routes_discovered_constraints
run_test test_sweep_updates_memory_index
run_test test_wrap_family_pinned_to_opus
run_test test_wrap_references_sibling_skills
run_test test_sweep_runs_the_memory_index_guard
run_test test_no_skill_names_a_claude_home_path
run_test test_former_commands_are_skills
run_test test_explicit_only_skills_ship_a_codex_policy
run_test test_skills_check_adapter_capabilities_before_use
run_test test_rotate_describes_the_default_countdown
run_test test_rotate_names_the_codex_closing_line
run_test test_switch_is_user_invoked_only
run_test test_switch_checks_before_writing
run_test test_switch_runs_rotates_steps_by_reference
run_test test_switch_step_numbers_match_rotate
run_test test_switch_names_both_final_lines
run_test test_switch_reads_its_arguments_from_the_message
run_test test_switch_says_the_new_conversation_starts_itself
run_test test_wrap_does_not_duplicate_memory_bars
run_test test_wrap_does_not_duplicate_summary_skeleton
run_test test_scoring_threshold_owned_by_skill
run_test test_summary_reads_narrative
run_test test_prose_critic_pinned_and_contracted
run_test test_prose_hygiene_has_modes_and_technical_carveout
run_test test_release_names_uninstall_source_not_bincs
run_test test_release_changelog_step_follows_approval
run_test test_prose_hygiene_records_upstream_sync
run_test test_summary_replaces_existing_file
run_test test_summary_bounds_git_log_to_session
run_test test_summary_prose_loop_is_bounded
run_test test_wrap_report_is_not_two_line
run_test test_checkpoint_routes_reserved_subcommands
run_test test_checkpoint_quotes_label_and_stops_on_failure
run_test test_sweep_supersedes_stale_entries
run_test test_sweep_states_filename_convention
run_test test_sweep_scopes_when_not_to_write
run_test test_sweep_states_memory_pointer_format
run_test test_sweep_resolves_actor_before_narrative_append
run_test test_sweep_adds_check_tasks_and_keeps_the_entry
run_test test_store_secret_opener_softened_and_stops_on_nothing
run_test test_store_secret_guards_silent_overwrite
run_test test_store_secret_non_session_warns_and_forbids_file
run_test test_store_secret_confirms_only_on_success
run_test test_prose_hygiene_scoring_reports_either_way_and_defers_revision
test_release_has_code_review_gate() {
    assert_file_contains "$RELEASE_MD" "Code-Review the Release Range" \
        "release.md must carry a correctness review step" || return 1
    assert_file_contains "$RELEASE_MD" "Critical and Important findings are fixed" \
        "the code-review step must block on Critical/Important findings" || return 1
    assert_file_contains "$RELEASE_MD" "touches documentation alone" \
        "the code-review step must state its docs-only skip condition" || return 1
}

run_test test_release_has_branch_sync_preflight
run_test test_release_doc_review_has_procedure
run_test test_release_empty_diff_expected_when_committed
run_test test_release_handles_empty_prev_tag
run_test test_release_approval_has_cancel_and_reapproval_loop
run_test test_release_guards_stray_files_before_add_all
run_test test_release_verifies_ci_workflow
run_test test_release_has_code_review_gate

# A shared .cs/memory/ makes "the user is X" false on every other actor's
# machine, while "actor <slug> is X" stays true everywhere. The rule has to
# cover MEMORY.md pointer lines too: those load at startup, whereas the bucket
# files they point at are only read lazily, so a poisoned pointer reaches
# context even when nothing opens the entry.
test_sweep_requires_identity_facts_to_be_keyed() {
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "keyed" \
        "sweep.md must require identity facts to be keyed to an actor" || return 1
    assert_file_contains "$SKILLS_DIR/sweep/SKILL.md" "pointers load at startup" \
        "the rule must govern index pointer lines, not just entry bodies" || return 1
}

run_test test_sweep_requires_identity_facts_to_be_keyed

# The empirical remit. A reviewer reading a diff sees a rule once; a reviewer
# measuring it against the real population leaves the defect nowhere to sit.
# The corpus redactor survived 29 releases because every review after it was
# scoped to the range that release touched.
test_release_gate_mandates_an_empirical_pass() {
    assert_file_contains "$RELEASE_MD" "run it against the real population" \
        "Step 4b must require measuring a rule against real data, not reading the diff" || return 1
    assert_file_contains "$RELEASE_MD" "how often it fires" \
        "Step 4b must require reporting the firing rate" || return 1
    assert_file_contains "$RELEASE_MD" "author cannot supply that measurement" \
        "Step 4b must exclude the author from supplying their own measurement" || return 1
    assert_file_contains "$RELEASE_MD" "wrongly destroys" \
        "Step 4b must require testing both directions, not only what leaks" || return 1
}

run_test test_release_gate_mandates_an_empirical_pass

test_wrap_rotates_the_narrative_after_the_summary() {
    assert_file_contains "$SKILLS_DIR/wrap/SKILL.md" "## Pass 3 — Narrative rotation" \
        "wrap has a third pass" || return 1
    assert_file_contains "$SKILLS_DIR/wrap/SKILL.md" 'ags -narrative rotate' \
        "the pass runs the ags helper rather than describing file surgery" || return 1
    assert_file_contains "$SKILLS_DIR/wrap/SKILL.md" '3\. \*\*Narrative:\*\*' \
        "the report gains a third item" || return 1
}

test_summary_reads_live_narratives_not_archives() {
    assert_file_not_contains "$SKILLS_DIR/summary/SKILL.md" "read all of them" \
        "the read-all instruction is gone" || return 1
    assert_file_contains "$SKILLS_DIR/summary/SKILL.md" "narrative-archive" \
        "summary knows where older sections went" || return 1
}

run_test test_wrap_rotates_the_narrative_after_the_summary
run_test test_wrap_marks_the_wrapped_conversation
run_test test_summary_reads_live_narratives_not_archives

report_results
