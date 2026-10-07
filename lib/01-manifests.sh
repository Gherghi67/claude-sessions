# ABOUTME: The deploy manifests (hooks, commands, skills, mods, and what past versions
# ABOUTME: left behind), the settings-strip filter and the Option-key bindings; build.sh
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
    prose-lint.sh             # retired with the `ags -lint` verb it called; MUST stay listed, because a deployed copy calling the removed verb reads error()'s exit 1 as "violations found" and blocks every turn-end
    memory-index-guard.sh     # moved into the sweep skill (sweep/scripts/), so the guard travels with the skill to every engine
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
# reached through $EDITOR, not through any hook event.
CS_HOOK_LIBS=(
    cs-resolve.sh
    cs-shared.sh
    cs-iterm-tab.py
    prompt-rewriter.sh
    prompt-rewriter-model.sh
    prompt-rewriter-vendor.sh
)

# Slash commands earlier versions deployed to ~/.claude/commands/. cs ships
# none now: they became skills of the same name, the one format every engine
# reads. install.sh and run_uninstall delete these files; a command left
# beside its skill would answer the same /name twice.
RETIRED_COMMANDS=(
    summary.md
    checkpoint.md
    sweep.md
    wrap.md
)

# Skills cs ships; each deploys as <skills dir>/<name>/SKILL.md, for Claude
# under ~/.claude/skills and for Codex under $CODEX_HOME/skills (default
# ~/.codex/skills). Both engines get the same files.
CS_SKILLS=(
    store-secret
    prose-hygiene
    rotate
    switch
    finish
    feature
    write-as-me
    checkpoint
    summary
    sweep
    wrap
)

# Skills retired or renamed in past versions but possibly still installed from
# older cs versions. install.sh and run_uninstall both delete these directories.
# When retiring or renaming a skill in a release, add its OLD name here: a skill
# directory left behind keeps answering its slash command forever, and nothing
# else ever removes it.
#
# Only the Claude skills directory is swept. Every name below retired before
# cs deployed skills to Codex, so in a Codex skills directory it can only be
# the user's own skill. A skill retired after shipping to Codex must also be
# removed from there.
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
# Files under scripts/ are executables; agents/openai.yaml is Codex's
# per-skill settings, which Claude ignores.
CS_SKILL_FILES=(
    write-as-me/scripts/build-corpus.sh
    finish/scripts/finish.sh
    finish/agents/openai.yaml   # Codex ignores disable-model-invocation; this is its switch
    switch/agents/openai.yaml   # the same switch for the switch skill: run only when the user asks
    sweep/scripts/memory-index-guard.sh
    sweep/scripts/cs-shared.sh  # build.sh's copy of hooks/cs-shared.sh, which the guard sources
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

# The SessionStart hook ags registers for Codex: Codex runs the command through
# a shell, so a path outside the plain-word alphabet is single-quoted.
_codex_hook_command() {  # ags_path
    case "$1" in
        *[!A-Za-z0-9_./+-]*)
            printf "'%s' -codex-hook session-start" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s -codex-hook session-start' "$1" ;;
    esac
}

# Codex skips a hook, silently, until config.toml trusts it: a table
# [hooks.state."<hooks.json path>:session_start:<group>:<handler>"] holding the
# sha256 of the handler group's definition, as compact sorted-key JSON with
# Codex's defaults filled in. ags writes that hash in the same step that
# registers its hook, so the hook runs without a review prompt.
_codex_hook_trust_hash() {  # command
    local json
    json=$(jq -ncS --arg c "$1" \
        '{event_name: "session_start", hooks: [{async: false, command: $c, timeout: 600, type: "command"}]}' \
        | tr -d '\n') || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$json" | sha256sum | cut -c1-64
    else
        printf '%s' "$json" | shasum -a 256 | cut -c1-64
    fi
}

# A config.toml rewrite: drop the trust table for each listed key, then rename
# trust tables for SessionStart groups past a removed one down by one index
# (shift_from, empty for none), keeping every other line as it was.
_codex_trust_tables_edit() {  # config, hooks_file, shift_from, keys...
    local config="$1" file="$2" shift_from="$3" tmp
    shift 3
    [ -f "$config" ] || return 0
    tmp=$(mktemp "$config.ags.XXXXXX") || return 1
    awk -v prefix="[hooks.state.\"$file:session_start:" -v shift_from="$shift_from" -v drops="$(printf '%s\n' "$@")" '
        BEGIN {
            n = split(drops, list, "\n")
            for (i = 1; i <= n; i++) if (list[i] != "") drop["[hooks.state.\"" list[i] "\"]"] = 1
        }
        # Blank lines wait for the next line that survives, so a dropped table
        # takes its separating blank with it and trailing blanks never pile up.
        /^[[:space:]]*$/ { if (!skip) blanks++; next }
        $0 in drop { skip = 1; next }
        skip && /^[[:space:]]*\[/ { skip = 0 }
        skip { next }
        { while (blanks > 0) { print ""; blanks-- } }
        shift_from != "" && index($0, prefix) == 1 {
            rest = substr($0, length(prefix) + 1)
            split(rest, parts, ":")
            if (parts[1] ~ /^[0-9]+$/ && parts[1] + 0 > shift_from + 0) {
                print prefix (parts[1] - 1) substr(rest, length(parts[1]) + 1)
                next
            }
        }
        { print }
    ' "$config" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$config" || { rm -f "$tmp"; return 1; }
}

# Index of ags's own SessionStart group in a hooks.json document, or nothing.
_codex_hook_group_index() {  # hooks.json content
    printf '%s' "$1" | jq -r '
        [(.hooks.SessionStart // [])
         | to_entries[]
         | select(any(.value.hooks[]?; (.command // "") | endswith(" -codex-hook session-start")))
         | .key] | first // empty'
}

# Register ags's SessionStart hook in <codex_dir>/hooks.json and trust it in
# <codex_dir>/config.toml. A reinstall replaces the group in place and a first
# install appends it, so the user's own groups keep their indices, and with
# them their trust. A hooks.json that is not valid JSON is left alone.
_codex_hooks_register() {  # codex_dir, command
    local dir="$1" cmd="$2" file="$1/hooks.json" config="$1/config.toml"
    local doc index tmp hash key
    case "$file" in *'"'*|*\\*) return 1 ;; esac
    if [ -f "$file" ]; then
        doc=$(cat "$file") || return 1
        printf '%s' "$doc" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    else
        doc='{}'
    fi
    index=$(_codex_hook_group_index "$doc")
    doc=$(printf '%s' "$doc" | jq --arg c "$cmd" --arg i "$index" '
        {hooks: [{type: "command", command: $c}]} as $ours
        | .hooks = (.hooks // {})
        | .hooks.SessionStart = (.hooks.SessionStart // [])
        | if $i == "" then .hooks.SessionStart += [$ours]
          else .hooks.SessionStart[($i | tonumber)] = $ours end') || return 1
    [ -n "$index" ] || index=$(printf '%s' "$doc" | jq '.hooks.SessionStart | length - 1')
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "$file.ags.XXXXXX") || return 1
    printf '%s\n' "$doc" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    hash=$(_codex_hook_trust_hash "$cmd") || return 1
    key="$file:session_start:$index:0"
    _codex_trust_tables_edit "$config" "$file" "" "$key" || return 1
    [ -f "$config" ] || { : > "$config" && chmod 600 "$config"; } || return 1
    if [ -s "$config" ]; then printf '\n' >> "$config" || return 1; fi
    printf '[hooks.state."%s"]\ntrusted_hash = "sha256:%s"\n' "$key" "$hash" >> "$config"
}

# Remove ags's SessionStart group and its trust table. Groups after it move up
# one index, so their trust tables are renamed to match. A hooks.json left with
# nothing in it is removed.
_codex_hooks_unregister() {  # codex_dir
    local dir="$1" file="$1/hooks.json" config="$1/config.toml" doc index tmp
    [ -f "$file" ] || return 0
    doc=$(cat "$file") || return 1
    index=$(_codex_hook_group_index "$doc" 2>/dev/null) || return 1
    [ -n "$index" ] || return 0
    doc=$(printf '%s' "$doc" | jq --argjson i "$index" '
        .hooks.SessionStart |= (to_entries | map(select(.key != $i)) | map(.value))
        | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
        | if .hooks == {} then del(.hooks) else . end') || return 1
    if [ "$doc" = '{}' ]; then
        rm -f "$file" || return 1
    else
        tmp=$(mktemp "$file.ags.XXXXXX") || return 1
        printf '%s\n' "$doc" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
    fi
    _codex_trust_tables_edit "$config" "$file" "$index" "$file:session_start:$index:0"
}

# Option+1 and Option+2: the two Claude Code keybindings ags offers to add,
# each a "command:<name>" action, which submits /<name>. install.sh asks once
# per machine and binds them, ags -uninstall takes back only the keys that
# still hold these values, and ags -doctor reports them.
CS_OPTION_KEYS='{"alt+1":"command:rotate","alt+2":"command:wrap"}'

# Claude Code reads its keybindings from its config dir. Inside an encrypted
# session that dir is the session's .cs/claude-config, which no other session
# reads; it links the shell's keybindings.json instead, so ags's keys belong in
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
# it has been asked on a terminal.
_cs_option_keys_answer_file() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cs/option-keys"
}

# Whether a keybindings file has the shape ags reads and merges into: one JSON
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
# one line per ags key: "bound<TAB>key" when every binding of it, in any
# context, holds ags's value; "free<TAB>key" when nothing binds it; and
# "conflict<TAB>key<TAB>action" when something else does. An action that is
# not a string (a null that unbinds the key) prints as JSON.
_cs_option_keys_status() {
    jq -r --argjson cs "$CS_OPTION_KEYS" '
        [.bindings[] | (.bindings // {}) | to_entries[]] as $all
        | $cs | to_entries[] | . as $c
        | [$all[] | select(.key == $c.key) | .value] as $vals
        | if ($vals | length) == 0 then "free\t\($c.key)"
          elif all($vals[]; . == $c.value) then "bound\t\($c.key)"
          else "conflict\t\($c.key)\t\([$vals[] | select(. != $c.value)][0]
                | if type == "string" then . else tojson end)"
          end'
}
