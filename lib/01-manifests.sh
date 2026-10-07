# ABOUTME: The deploy manifests (hooks, commands, skills, mods, and what past versions
# ABOUTME: left behind), the settings-strip filter and the rotate/wrap key bindings; build.sh
# ABOUTME: folds this into bin/cs and splices it into install.sh, so both read one list.

# Files a past version deployed into the hooks directory and this one does not:
# retired hooks, and any support file that went with them. Removed on install
# and on uninstall, wherever an older cs left them.
# install.sh and run_uninstall both clean these up.
# When retiring a hook in a release, add its filename here.
RETIRED_HOOKS=(
    narrative-precompact.sh   # retired: PreCompact cannot inject context (no hookSpecificOutput/additionalContext); Stop reminder covers capture
    discovery-commits.sh      # renamed to autosave-commits.sh (general all-file crash recovery, not discoveries-specific)
    discoveries-reminder.sh   # retired: session narrative moved to .cs/memory/narrative.md (native lazy-load, no size budget)
    discoveries-archiver.sh   # retired in v2026.4.7 (archive flow replaced by size-budget compaction)
    aboutme-prereader.sh      # retired: source-file ABOUTME-header nudge experiment
    gotcha-prewriter.sh       # retired: brief pre-write gotcha-surfacing experiment; approach was rethought
    aboutme-validator.sh      # retired: never-shipped PostToolUse-on-Write experiment from a feature branch that registered the hook in settings.json without the file ever landing in source
    command-tracker.sh        # retired: CLI command capture; @-included payload did not influence model behaviour at a rate justifying its context cost
    cs-logo.png               # retired: the icon source for the finished-turn notification, which the iTerm2 sidebar owns now (not a hook; a file the hooks directory carried)
    files-scan.sh             # retired: workspace file indexer for .cs/files.md (assumption that the agent can't introspect file sizes has expired)
    files-context.sh          # retired: PreToolUse:Read context injector that surfaced files.md token estimates
    changes-tracker.sh        # retired: PostToolUse change log re-narrating git history into .cs/changes.md; git log/diff/status is authoritative
    artifact-tracker.sh       # retired: PreToolUse:Write redirect was inert (updatedInput path rewrite is not honored by the harness); tracking removed entirely
    prose-lint.sh             # retired with the `cs -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
)

# Hook scripts cs ships; deployed to ~/.claude/hooks/cs/ and registered in
# settings.json.
CS_HOOKS=(
    session-start.sh
    autosave-commits.sh
    narrative-reminder.sh
    session-end.sh
    subagent-context.sh
    tool-failure-logger.sh
    session-auto-approve.sh
    bash-logger.sh
    scope-prompt.sh
)

# Files under hooks/ that the hooks source, or that cs points other tools at,
# rather than files Claude Code invokes as hooks. Deployed and removed alongside
# the hooks, never registered against an event. The prompt-rewriter scripts are
# reached through $EDITOR, not through any hook event; memory-index-guard.sh is
# run by the /sweep command.
CS_HOOK_LIBS=(
    cs-resolve.sh
    cs-shared.sh
    cs-iterm-tab.py
    memory-index-guard.sh
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
)

# Slash commands cs ships; deployed to ~/.claude/commands/.
CS_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as ~/.claude/skills/<name>/SKILL.md.
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    finish
    feature
    write-as-me
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and run_uninstall both delete these directories.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
#
# Do not add a doctor row for a leftover directory; it cannot report one. The
# only cs that could still hold it is one older than the retirement, and that cs
# has no entry here to check against; the upgrade that gives it the entry is the
# same install that deletes the directory. So the row would warn about a state
# it can never observe.
RETIRED_SKILLS=(
    voice   # renamed to write-as-me; Claude Code 2.1.227 ships a built-in /voice (Toggle voice mode)
    merge   # replaced by finish: integrate and report, never remove
    cs-hint # a mod (deployed under skills/ like every mod): the hint line under the prompt, retired
    cs-rotate # a mod: renamed to cs, cs's in-session mod (the rotate band, forced rotation, the wrap key)
)

# Support files skills ship beyond SKILL.md, as skills/<skill>/<path> entries.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
    finish/scripts/finish.sh
)

# Mods cs ships: Claude Code function-hooks plugins, deployed file by file as
# ~/.claude/skills/<mod>/<path> (the mod's bun tests stay in the checkout).
CS_MOD_FILES=(
    cs/.claude-plugin/plugin.json
    cs/hooks/hooks.json
    cs/hooks/register.tsx
    cs-update/.claude-plugin/plugin.json
    cs-update/hooks/hooks.json
    cs-update/hooks/register.tsx
)

# Remove a hook registration from any event in a settings JSON string,
# matching either path spelling; drops wrappers that empty out. Prints the
# updated JSON.
_strip_hook_registration() {
    local settings="$1" p="$2" t="$3"
    echo "$settings" | jq --arg p "$p" --arg t "$t" '
        if .hooks then
            .hooks |= with_entries(
                .value |= (
                    map(.hooks |= map(select(.command != $p and .command != $t)))
                    | map(select(.hooks | length > 0))
                )
            )
        else . end
    '
}

# Ctrl+X R and Ctrl+X W: the two Claude Code keybindings cs offers to add,
# each a "command:<name>" action, which submits /<name>. install.sh asks once
# per machine and binds them, cs -uninstall takes back only the keys that
# still hold these values, and cs -doctor reports them.
CS_ROTATE_WRAP_KEYS='{"ctrl+x r":"command:rotate","ctrl+x w":"command:wrap"}'

# Option+1 and Option+2 on the same two commands, as cs 2026.10.6 bound them.
# iTerm2 selects panes with Option+number, so there they never reach Claude
# Code. Wherever they still hold these values, an install that binds the
# chords takes them back, and so does cs -uninstall.
# shellcheck disable=SC2034  # read by install.sh's _bind_rotate_wrap_keys, cs -uninstall and cs -doctor
CS_RETIRED_OPTION_KEYS='{"alt+1":"command:rotate","alt+2":"command:wrap"}'

# The jq definitions shared by the filters below. keynorm follows Claude
# Code's key parser (2.1.291) as far as the keys cs compares need: case
# ignored, control is ctrl, opt and option are alt, command, super and win
# are cmd, esc, return and del are escape, enter and delete, modifiers in
# any order, and a chord's keys split on any run of spaces. It keeps meta
# apart from alt and leaves space and arrow glyphs as typed, which no cs key
# uses. cs's own keys are already in that form. ours: whether a to_entries pair from a context block is one of
# the bindings in $cs, key and value both.
_CS_KEYBINDING_DEFS='
    def keynorm:
        ["alt", "cmd", "ctrl", "meta", "shift"] as $mods
        | [splits("\\s+") | select(length > 0) | ascii_downcase | split("+")
            | map({"control": "ctrl", "opt": "alt", "option": "alt", "command": "cmd",
                   "super": "cmd", "win": "cmd", "esc": "escape", "return": "enter",
                   "del": "delete"}[.] // .)
            | ([.[] | select(. as $p | any($mods[]; . == $p))] | unique)
              + [.[] | select(. as $p | any($mods[]; . == $p) | not)]
            | join("+")]
        | join(" ");
    def ours: . as $e | ($e.key | keynorm) as $k | $cs | has($k) and .[$k] == $e.value;
'

# Claude Code reads its keybindings from its config dir. Inside an encrypted
# session that dir is the session's .cs/claude-config, which no other session
# reads; it links the shell's keybindings.json instead, so cs's keys belong in
# the shell's config dir, which launch records in
# CLAUDE_SECURESTORAGE_CONFIG_DIR (empty for ~/.claude).
_cs_keybindings_file() {
    local dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    case "$dir" in
        */.cs/claude-config) dir="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-$HOME/.claude}" ;;
    esac
    printf '%s\n' "$dir/keybindings.json"
}

# This machine's answer to the installer's question, yes or no; absent until
# it has been asked on a terminal. The file keeps the name it had when the
# keys were Option+1 / Option+2, so a machine that said yes then gets the
# chords on its next install.
_cs_rotate_wrap_keys_answer_file() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cs/option-keys"
}

# Whether a keybindings file has the shape cs reads and merges into: one JSON
# object whose "bindings" is an array of context blocks, each an object whose
# own "bindings", when present, is an object. Slurped, so a file holding two
# documents is refused rather than read as two; -e turns invalid JSON, an
# empty file and a false answer alike into a non-zero exit.
_cs_keybindings_shape_ok() {  # file
    jq -se 'length == 1 and (.[0] | type == "object" and (.bindings | type == "array")
        and all(.bindings[]; type == "object" and ((.bindings // {}) | type == "object")))' \
        "$1" > /dev/null 2>&1
}

# Reads a keybindings document that passed the shape check on stdin and prints
# one line per cs key: "bound<TAB>key" when every binding of it, in any
# context, holds cs's value; "free<TAB>key" when nothing binds it; and
# "conflict<TAB>key<TAB>action" when something else does. A chord also
# conflicts when its first key is bound on its own to an action, which
# Claude Code would stop reaching once it waits for the chord's second key:
# "conflict<TAB>key<TAB>action<TAB>prefix". Keys compare as keynorm spells
# them. An action that is not a non-empty string (a null that unbinds the
# key, an empty "") prints as JSON, so no field is ever empty; a null on the
# prefix is no conflict, as it binds nothing.
_cs_rotate_wrap_keys_status() {
    jq -r --argjson cs "$CS_ROTATE_WRAP_KEYS" "$_CS_KEYBINDING_DEFS"'
        def show: if type == "string" and length > 0 then . else tojson end;
        [.bindings[] | (.bindings // {}) | to_entries[] | .key |= keynorm] as $all
        | $cs | to_entries[] | . as $c
        | [$all[] | select(.key == $c.key) | .value] as $vals
        | ($c.key | split(" ") | if length > 1 then .[0] else null end) as $prefix
        | [$all[] | select(.key == $prefix and .value != null) | .value] as $pvals
        | if any($vals[]; . != $c.value) then
            "conflict\t\($c.key)\t\([$vals[] | select(. != $c.value)][0] | show)"
          elif ($pvals | length) > 0 then "conflict\t\($c.key)\t\($pvals[0] | show)\t\($prefix)"
          elif ($vals | length) == 0 then "free\t\($c.key)"
          else "bound\t\($c.key)"
          end'
}

# Prints, comma-separated, the keys of a keybindings document on stdin that
# hold one of the bindings in the JSON object $1, spelled as the file spells
# them; empty when none does.
_cs_keybindings_held() {  # bindings-json
    jq -r --argjson cs "$1" "$_CS_KEYBINDING_DEFS"'
        [.bindings[] | (.bindings // {}) | to_entries[] | select(ours) | .key] | unique | join(", ")'
}

# Prints a keybindings document on stdin, compact, without the bindings in the
# JSON object $1 (key and value both; a key bound to anything else stays). A
# Global block left empty goes; another context keeps its block.
_cs_keybindings_strip() {  # bindings-json
    jq -c --argjson cs "$1" "$_CS_KEYBINDING_DEFS"'
        .bindings |= map(
            if any((.bindings // {}) | to_entries[]; ours) then
                .bindings |= with_entries(select(ours | not))
                | select(.bindings != {} or .context != "Global")
            else . end)'
}
