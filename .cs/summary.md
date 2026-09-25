# Session Summary: claude-sessions

**Date:** 2026-09-25, about 09:15 to 16:30 Bucharest time
**Duration:** about seven hours across six conversations, each one started by a rotation. The session itself has run since 2026-02-07. Earlier days are recorded in `.cs/README.md`, the narrative archive, and previous versions of this file in git (the 09-24 summary is at d521ae6c).

## Objective

The day had three threads:

1. Test the fact-ledger handoff spec merged overnight: does it help a real successor, or only a quiz?
2. Fix the small defects that turned up during the work.
3. Ship everything as cs v2026.9.22.

## Environment

- The cs dev checkout at `~/.claude-sessions/claude-sessions`, on the main branch, running Claude Code 2.1.281 and 2.1.282.
- Full suites run on the `ghost` host through `remote-tests.sh`. CI's macOS lane is the only real bash 3.2 judge.
- The eval harness lives in `.cs/research/handoff-eval/` and is gitignored. Its answer keys are kept outside the scoring conversation's reach.
- A peer Claude session named `claude` sent two requests about the rotate skill.

## Key Discoveries

- **The fact ledger's +20 points do not survive real questions.** Scoring used the facts that each handoff's real successor had to look up or re-derive. On those keys, candidate A was +0.21 points against a noise threshold of 6.62. The +20.25 came from quiz keys. The field check (#679) then coded five real successor reports: wrong 1, lookups 0.4 per rotation, and no failure kind beyond that. A blind Fable coder reached the same verdict. So A stays in the skill, and the eval loop is not rerun.
- **A slow `/clear` was cs, not Claude Code.** On every SessionEnd, cs rebuilt the sessions index with about six forks per session, which took 8 to 27 s over 138 sessions. A single awk pass now does it in 0.15 s and writes the same bytes.
- **Doctor's "autosave may be broken" warning had been a false positive since 2026-07-23.** Doctor checked the launch conversation's shadow ref, and `/clear` deletes that ref. Two Codex rounds widened the fix:
  - Doctor now judges the caller's own id.
  - It warns only when settings.json does not register the hook on Write and Edit.
- **The narrative rotation never committed in this repo.** git exits 1 on a plain `add` of any path under an ignored directory, even a tracked one, although it still stages the file. So `cs -narrative rotate` wrote the rotation but never committed it. Both paths are now force-added, and only when the narrative is tracked.
- **Running a suite under `/bin/bash` is not the same as CI's macOS lane.** Tests that start a hook with `bash "$HOOK"` look `bash` up on PATH and get Homebrew's bash 5. The launch mark depended on `$EPOCHREALTIME`, which bash 3.2 lacks, so on stock macOS it wrote nothing, and its test would have failed on the release push. The Fable range review caught it. It reproduced with a PATH shim that points `bash` at `/bin/bash`. This is now recorded in memory.
- **Neither of the peer's rotate-skill requests had a failing rotation behind it.** Both are held as #679 codes instead of spec changes.

## Changes Made

**Fixes merged to main during the day:**
- **Rotate prune:** deletes only handoffs that git tracks.
- **Sessions index on SessionEnd:** rebuilt with one awk pass.
- **Scope-prompt hook:** writes a launch mark before loading its library, and its timeout went from 5 s to 10 s.
- **Pending-handoff prompt:** lists one answer per row.
- **Rotate skill:** a Next Step that needs a clean worktree now says to commit the handoff first.
- **Doctor autosave row:** the fix described above.
- **Narrative rotation:** commits under an ignored `.cs/` (81abfa0b, b6e49f4e, merged 89c39390).

**Release v2026.9.22** (f37b8e7c):
- **Review folds (3a0b8101):**
  - The launch mark falls back to one `date +%s` fork on bash 3.2.
  - Doctor's jq filter tolerates an invalid matcher on another hook entry.
  - `tests/test_lib.sh` unsets the inherited conversation ids.
- **Docs (5fac0b11):** 29 drift items across the README, hooks, session-layout and statusline docs. Examples: the rotation wake after `/clear`, `/queue` and `/cs-update` in the slash-command list, and the Fable window's 50% threshold.
- **Gates:** CI 6/6 green on the release commit, tag cut with `--target` on the full SHA, release workflow green with 12 signed assets, installed locally with `cs -update`, doctor drift OK.

## Key Files & Outputs

- `hooks/scope-prompt.sh`: the launch mark and its bash 3.2 fallback.
- `lib/60-doctor.sh`: `_doctor_check_shadow_ref`, including the registration check.
- `lib/51-narrative.sh`: the rotation commit.
- `hooks/session-end.sh`: the index rebuild.
- `lib/75-launch.sh`: `_resume_menu_row`.
- `skills/rotate/SKILL.md`: the prune rule and the clean-worktree step.
- `tests/test_doctor.sh`, `tests/test_lib.sh`, `tests/test_narrative_rotate.sh`, `tests/test_rotation.sh`: the tests behind these fixes.
- `README.md`, `docs/hooks.md`, `docs/session-layout.md`, `docs/statusline.md`, `CHANGELOG.md` (`## 2026.9.22`).
- `.cs/handoffs/2026-09-25-*.md`: five handoffs, each with its successor report.
- Machine-local and gitignored: `.cs/research/handoff-field-log.md` (the #679 coding and its KEEP verdict) and the real-key eval runs.

## Outcome

Every thread is closed:
- The fact ledger stays, on field evidence rather than the quiz number.
- #679 is closed as KEEP.
- cs v2026.9.22 is published and installed.
- main matches origin except for this wrap's session files.

## Notes for Future Reference

- **Deferred from the release review:**
  - The README objective parser now exists in three copies. `session-start` still forks `sed` once per session on every start, the same cost the SessionEnd fix removed.
  - `_resume_menu_row` duplicates `_lock_menu_row`.
  - The launch mark repeats `_now_ms`'s arithmetic.
  - The rotation kick's retry bound is a count, not a deadline.
- **Unverified:** that `$CLAUDE_CODE_SESSION_ID` is the caller's own id inside teammates and subagents.
- **Discoverability:** `/queue` has no in-product tip. Users find it through the release notes pane, the `/` menu or the README. cs-hint was the only tip surface, and it was removed.
- **Release shape** (it worked again today): no content push before the notes are approved, then push the release commit, poll CI keyed on its SHA, and tag only after every job is green.
- **Suite rule:** full suites run on ghost, never locally. The morning broke this three times. Afternoon runs were single touched suites only.
