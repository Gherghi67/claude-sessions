# Contributing to agent-sessions

Practical guide for adding hooks, commands, and other contributions to agent-sessions.

## Development Setup

```bash
git clone https://github.com/hex/claude-sessions.git agent-sessions
cd agent-sessions
```

The `ags` command is **assembled** from ordered fragments in `lib/*.sh` into the
single `bin/cs` that ships. **Edit the `lib/` fragments, never `bin/cs` directly**,
then rebuild and commit the regenerated `bin/cs`:

```bash
./build.sh   # concatenates lib/*.sh (in numeric-prefix order) into bin/cs
```

CI rebuilds and fails if the committed `bin/cs` is out of sync with `lib/`. Each
fragment has a numeric prefix (`00`, `05`, …, `99`) that fixes its position; the
`bin/cs` blob stays byte-identical whether you edit a fragment or the assembled
file, so a build is transparent. Hooks live in `hooks/`, skills (the former
slash commands included) in `skills/`, and tests in `tests/`.

The upstream URL remains unchanged during the rebrand. `ags` and `ags-tui` are
the primary user-facing executable names; `cs` and old companion names remain
compatibility aliases. The generated shell implementation continues to build to
`bin/cs` internally; the installer exposes the public aliases. Shared workspace/storage/context
fragments and namespaced adapter fragments are described in
[Engine adapters](docs/engine-adapters.md). Keep native configuration and parsers
inside their adapter; build.sh still produces a standalone shell executable.

## Running Tests

Tests use a shared library (`tests/test_lib.sh`) that provides assertions, temporary directories, and test isolation.

```bash
# Run all tests (aggregates per-suite results and exits non-zero on any failure)
bash tests/run_all.sh

# Run a single test file
bash tests/test_hooks.sh

# Run the suites one at a time, streaming each one's output live
CS_TEST_JOBS=1 bash tests/run_all.sh

# Run the Rust TUI tests
cargo test --manifest-path tui/Cargo.toml
```

`run_all.sh` runs several suites at once by default and replays their output in
the order a serial run would have printed it, so the concurrency is invisible
unless something fails. It announces its plan first (`running 57 suites at 10
jobs`); the lane count is what explains the wall time. While it runs, each
suite prints one line to stderr as it finishes (`[12/57] test_queue.sh 4s`,
with `FAIL` appended when it failed), so a slow gate and a hung one look
different. The report ends with the ten slowest suites and their seconds.
`CS_TEST_JOBS=1` runs them one at a time and streams each suite's output as it
happens, which is what you want when bisecting a failure inside a single suite.

The lanes default to half the cores on a workstation (a runner with four cores
or fewer keeps them all) and every suite runs under `nice -n 10`, so a gate
leaves the machine usable while it runs. One gate per checkout: a second
`run_all.sh` started while one is running refuses with the holder's pid and
exits 3 (`tests/.run_all.lock`; a lock whose pid is dead is taken over).

The gate stops a suite that runs past 600 seconds, along with its child
processes, counts it as failed and names it in a `timed out after 600s` line;
the other suites still run. The slowest suite takes about 200 seconds on a loaded machine.
`CS_TEST_SUITE_TIMEOUT` sets the cap in seconds.

### Which tests to run, and when

The full gate takes minutes. Most of the time you do not want it.

| Situation | Run |
|---|---|
| Red/green loop on one file | that file's suite alone, roughly a second or two |
| About to commit | `bash tests/run_all.sh --changed` |
| About to merge, or cutting a release | `bash tests/run_all.sh` |
| About to push a shell change | `bash tests/lint_shell.sh` (the shellcheck lane CI runs; the suites never run it) |

`tests/lint_shell.sh` fails on any shellcheck error, and on a warning count that differs from
`.shellcheck-warnings`. The count is measured with the shellcheck version CI pins in
`.github/workflows/test.yml` (v0.11.0); another version can count differently. When you fix
warnings, lower that number in the same commit.

`--changed` reads the working tree against `HEAD` plus untracked files and runs
only the suites whose text names a changed path (a changed suite runs itself).
Three kinds of change have no honest subset and run the full gate: anything
under `lib/` or `bin/cs` (assembled from every fragment, invoked by most
suites), `tests/test_lib.sh`, and a source path no suite names. Session state,
docs and config (`.cs/`, `docs/`, the top-level `*.md`, `.github/`) are ignored
either way; skill and command markdown counts as source.
`CS_TEST_CHANGED` (one path per line) replaces the git-derived list.

Order the gates so the cheap ones run first. A full sweep before a quick manual
check that could send you back to the code is a sweep you pay for twice.

### Run a single suite under both bash versions

```bash
/bin/bash tests/test_foo.sh   # 3.2 on macOS: the floor, and what CI pins
bash tests/test_foo.sh        # 5.x if Homebrew is on PATH: what run_all spawns
```

`run_all.sh` launches suites with a bare `bash`, so on a dev box with Homebrew
the gate runs them under 5.x while a hand-run `/bin/bash tests/...`
uses 3.2. The two disagree — `local x` leaves `x` unset under 4.4 and later,
where `set -u` then aborts the suite, and 3.2 accepts it — so a suite can pass
alone and abort under the gate, or the reverse. Checking both takes seconds and
catches the whole class.

Every bash suite under `tests/` plus the Rust TUI tests must
pass before submitting changes; CI (`.github/workflows/test.yml`) runs them on
every push and pull request. Do not use a bare `for f in tests/*; do bash "$f";
done` loop — its exit status reflects only the last suite, so failures are
masked; `run_all.sh` reports every failing suite.

## Adding a Hook

1. **Create the hook script** in `hooks/your-hook.sh`. Copy an existing hook (e.g., `hooks/bash-logger.sh`) as a starting template.

2. **Register it**:
   - Add the filename to the `CS_HOOKS` array in `lib/01-manifests.sh`, then run `./build.sh`, which folds it into `bin/cs` and splices it into `install.sh` (deploy, flat-layout cleanup, registration stripping, uninstall and doctor all derive from it)
   - Add a `_merge_cs_hook <Event> your-hook.sh <timeout> [matcher] [async]` call in `install.sh.in` alongside the existing ones (see the block around its `_merge_cs_hook SessionStart ...` calls) to register it in `settings.json` under the appropriate event (`SessionStart`, `PreToolUse`, `PostToolUse`, etc.); it derives the deploy and `~`-relative paths from the filename

3. **Never edit `install.sh` or `bin/cs` by hand** — `./build.sh` writes both. `tests/test_install.sh` fails if the committed built files differ from the build or the array disagrees with the actual contents of `hooks/`.

4. **Document in `docs/hooks.md`** — add a section following the existing format: hook name, event type, description, and behavior.

5. **Write tests** in `tests/` — create a test file or add to an existing one. Use `test_lib.sh` for setup/teardown.

## Adding a Skill

cs ships no slash commands: a skill answers `/name` in Claude Code and is the
one format Codex reads too. The four former commands (`checkpoint`, `summary`,
`sweep`, `wrap`) are skills, and `RETIRED_COMMANDS` in `lib/01-manifests.sh`
lists the command files the installer and uninstaller delete.

1. **Create `skills/name/SKILL.md`** with the skill's frontmatter (`name`, `description`, and `allowed-tools` with the hyphen if it needs one — Claude Code ignores the `allowed_tools` underscore form) and instructions. Copy an existing skill (e.g., `skills/store-secret/`) as a template.
   - Reach a helper the skill ships through its own directory (`scripts/x.sh` relative to the folder the SKILL.md was loaded from) or an `ags` verb, never a `~/.claude/...` path: under the ags profile that path is the stable cs install, and under Codex it is no install at all. List each helper in `CS_SKILL_FILES`. `tests/test_commands.sh` fails on a `~/.claude/` path in any SKILL.md.
   - Before relying on an adapter feature (rotation, a spawned session's brief, mail delivery, the memory index at session start), check `ags -engine supports <capability>` and refuse cleanly when it fails.
   - A skill only the user may start sets `disable-model-invocation: true`. Codex accepts that key and ignores it, so ship `agents/openai.yaml` beside the SKILL.md with `allow_implicit_invocation: false` under `policy:`, and list it in `CS_SKILL_FILES` (see `skills/finish/`). `tests/test_commands.sh` fails when the pair is incomplete.

2. **Add the directory name to the `CS_SKILLS` array** in `lib/01-manifests.sh`, then run `./build.sh` — install, `run_uninstall()`, and doctor all loop over it. The installer copies the same files into each selected engine's skills directory: `~/.claude/skills/` for Claude, `$CODEX_HOME/skills/` (default `~/.codex/skills/`) for Codex. `tests/test_install.sh` fails if the array disagrees with the `skills/` directory contents.

## Code Style

- Match the style of surrounding code.
- Every code file starts with a 2-line `ABOUTME:` comment explaining what the file does:
  ```bash
  # ABOUTME: Logs every Bash tool call to .cs/local/session.log with timestamp.
  # ABOUTME: Truncates long commands at 200 chars; never blocks on errors.
  ```
- No emojis in code or documentation (unless part of a functional emoji set).
- No temporal names (`NewAPI`, `LegacyHandler`, `ImprovedParser`). Name things for what they do, not their history.
- Test output must be clean. If a test intentionally triggers errors, capture and validate them.

## Merging upstream releases

agent-sessions follows hex/claude-sessions (`origin`). Merge each upstream release with:

```bash
scripts/sync-upstream.py start        # newest v* tag on origin/main; --to <tag> for another
# resolve what it reports in the sync worktree it prints, then, there:
scripts/sync-upstream.py continue
git merge --ff-only sync/<tag>        # back in this checkout
```

Commit your work first: the merge starts from the last commit, and git only recognises a moved file once it is committed. `start` makes a worktree beside this checkout (outside any repository that encloses it) on a `sync/<tag>` branch and records a real merge with both parents. Before merging, it rewrites upstream into this fork's dialect, so the rebrand itself does not conflict:

- Renames: `cs -x` becomes `ags -x`, `$CLAUDE_SESSION_*` becomes `${CS_SESSION_*:-${CLAUDE_SESSION_*:-}}`, `cs-statusline` becomes `ags-statusline`, and so on. They apply to the lines the fork renamed and the lines upstream adds; a line the fork kept stays as upstream wrote it.
- Functions: a function the fork keeps in another `lib/` fragment gets upstream's change there.
- Files: an upstream file the fork moved (`commands/*.md` to `skills/*/SKILL.md`, `bin/cs-statusline` to `bin/ags-statusline`) merges into the moved file.
- Generated files (`bin/ags`, `bin/cs`, `hooks/cs-shared.sh`, `install.sh`) are never merged; `continue` rebuilds them.

Prose (README, `docs/`, CHANGELOG) merges plainly, since the rebrand rewrote it by hand. What is left is where both sides changed the same lines. `continue` refuses while a conflict marker remains or a function is defined in two fragments, then runs `build.sh` and `tests/run_all.sh` (`--skip-tests` skips them) and commits. Nothing is pushed. When the rebrand renames something new, add the rule to `rename()` in the script so the next merge applies it.

## Releasing

Releases are managed via the `/release` slash command. See `.claude/commands/release.md` for the full checklist, which covers version bumps, changelog, signing, and GitHub Release creation.
