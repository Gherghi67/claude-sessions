#!/usr/bin/env bash
# ABOUTME: Carries the user's own Claude and Codex setup (~/.claude, ~/.codex) into the ags profile.
# ABOUTME: Links what the user edits and merges what lives in the profile's own files; setup.sh runs it.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash scripts/ags-carry-over.sh [--dry-run | --prune]

Carries your own Claude and Codex setup into the ags profile at
~/.local/share/agent-sessions/home. CLAUDE.md, AGENTS.md, agents, skills,
commands, workflows, themes and output styles are linked one entry at a time,
so an edit made in ~/.claude or ~/.codex reaches ags at once. Hooks, enabled
plugins, MCP servers and preferences are merged into the profile's own files.
Whatever ags installs itself is skipped, and an entry the profile already has
is the profile's: it is never replaced or removed. A hook the carry-over added
leaves the profile again once you change or remove it in ~/.claude or
~/.codex. A second run changes nothing unless ~/.claude or ~/.codex changed.

  --dry-run  print what would change; write nothing
  --prune    only remove carried links that dangle, or that a name ags now
             installs shadows (setup.sh runs this before it installs)

setup.sh runs the carry-over after every install. Pass --no-carry-over to
setup.sh, or set AGS_CARRY_OVER=0, to leave the profile as the install made it.
EOF
}

dry=0
prune_only=0
case "${1:-}" in
    '') ;;
    --dry-run) dry=1; shift ;;
    --prune) prune_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

: "${HOME:?HOME must be set}"
here=$(CDPATH='' cd -P "$(dirname "$0")" && pwd)
# The installer's own lists: what ags deploys, and what it removes on uninstall.
# shellcheck source=lib/01-manifests.sh
. "$here/../lib/01-manifests.sh"
command -v jq >/dev/null 2>&1 || { printf 'Error: the carry-over needs jq.\n' >&2; exit 1; }

# Every path comes from HOME. Inside an ags session CLAUDE_CONFIG_DIR,
# CODEX_HOME and the CS_* variables name the profile itself, so reading them
# would carry the profile into itself.
user_claude="$HOME/.claude"
user_claude_json="$HOME/.claude.json"
user_codex="$HOME/.codex"
profile="$HOME/.local/share/agent-sessions/home"
p_claude="$profile/.claude"
p_codex="$profile/.codex"

engines=$(cat "$profile/.local/bin/.cs-install-engines" 2>/dev/null || true)
if [ -z "$engines" ]; then
    # Nothing is installed yet, so there is nothing a link could shadow.
    [ "$prune_only" -eq 1 ] && exit 0
    printf 'Error: no ags profile at %s; run setup.sh first.\n' "$profile" >&2
    exit 1
fi
has_claude=0 has_codex=0
case ",$engines," in *,claude,*) [ -d "$p_claude" ] && has_claude=1 ;; esac
case ",$engines," in *,codex,*) [ -d "$p_codex" ] && has_codex=1 ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/ags-carry-over.XXXXXX")
trap 'rm -rf "$work"' EXIT

changes=0
header_printed=0
_header() {
    [ "$header_printed" -eq 0 ] || return 0
    header_printed=1
    printf '%s %s\n' "$label" "$profile"
}
# One line per change; a dry run says what it would do instead.
_did() {  # verb, past tense, what
    changes=$((changes + 1))
    _header
    if [ "$dry" -eq 1 ]; then
        printf '  would %s %s\n' "$1" "$3"
    else
        printf '  %s %s\n' "$2" "$3"
    fi
}
# Said only in a dry run: what is left alone, and why.
_left() {  # what, why
    [ "$dry" -eq 1 ] || return 0
    _header
    printf '  leave %s (%s)\n' "$1" "$2"
}
# Said in every run: something the carry-over cannot do, for the user to do.
_note() {  # text
    _header
    printf '  note: %s\n' "$1"
}

# A path under HOME, spelled from ~ for output (\176 is the tilde).
_tilde() {
    case "$1" in "$HOME"/*) printf '\176/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

_listed() {  # name, newline-separated list
    case $'\n'"$2"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
    return 1
}

# The names ags installs, from the lists run_uninstall removes them by. A
# skill or command of the user's by one of these names would answer the same
# slash command twice, and the next install would copy ags's file into the
# user's own directory through the link. "synced" is Claude Code's store of
# skills synced from claude.ai, which the profile keeps for its own login.
claude_skill_skip=$(printf '%s\n' "${CS_SKILLS[@]}" "${RETIRED_SKILLS[@]}"; \
    for f in "${CS_MOD_FILES[@]}"; do printf '%s\n' "${f%%/*}"; done; printf 'synced\n')
codex_skill_skip=$(printf '%s\n' "${CS_SKILLS[@]}")
command_skip=$(printf '%s\n' "${RETIRED_COMMANDS[@]}")

_skip_list() {  # category
    case "$1" in
        claude/skills) printf '%s' "$claude_skill_skip" ;;
        claude/commands) printf '%s' "$command_skip" ;;
        codex/skills) printf '%s' "$codex_skill_skip" ;;
    esac
}

# Backups and editor leftovers are not entries.
_is_backup() {
    case "$1" in *.pre-*|*.before-*|*.bak|*~) return 0 ;; esac
    return 1
}

# Does a user entry belong to this category? Skills are directories; the rest
# are files of the kinds Claude Code or Codex reads from that directory.
_entry_kind_ok() {  # category, path
    case "$1" in
        */skills) [ -d "$2" ] ;;
        claude/agents|claude/commands|claude/output-styles) [ -f "$2" ] && case "$2" in *.md) ;; *) false ;; esac ;;
        claude/workflows) [ -f "$2" ] && case "$2" in *.js|*.mjs|*.ts) ;; *) false ;; esac ;;
        claude/themes) [ -f "$2" ] && case "$2" in *.json) ;; *) false ;; esac ;;
        codex/agents) [ -f "$2" ] && case "$2" in *.toml) ;; *) false ;; esac ;;
        *) false ;;
    esac
}

_remove_link() {  # link, what, why
    [ "$dry" -eq 1 ] || rm -f "$1"
    _did remove removed "$2 ($3)"
}

# Drop the links a run made that no longer stand: the user removed the entry,
# or ags now installs an entry of that name. Only links into the user's own
# directory are judged; any other link is the profile's.
_prune_dir() {  # category, user_dir, profile_dir
    local category="$1" udir="$2" pdir="$3" link name target skip
    [ -d "$pdir" ] || return 0
    skip=$(_skip_list "$category")
    for link in "$pdir"/*; do
        [ -L "$link" ] || continue
        name=${link##*/}
        target=$(readlink "$link") || continue
        case "$target" in "$udir/"*) ;; *) continue ;; esac
        if [ ! -e "$link" ]; then
            _remove_link "$link" "$category/$name" "it no longer exists in $(_tilde "$udir")"
        elif [ -n "$skip" ] && _listed "$name" "$skip"; then
            _remove_link "$link" "$category/$name" "ags installs its own $name"
        fi
    done
}

_prune_file() {  # what, user_file, profile_file
    local target
    [ -L "$3" ] || return 0
    target=$(readlink "$3") || return 0
    [ "$target" = "$2" ] && [ ! -e "$3" ] || return 0
    _remove_link "$3" "$1" "it no longer exists"
}

# One symlink per user entry, never one for the directory: the profile's own
# entries, and everything ags installs, stay real files beside the links.
_link_dir() {  # category, user_dir, profile_dir
    local category="$1" udir="$2" pdir="$3" src name dest skip
    [ -d "$udir" ] || return 0
    skip=$(_skip_list "$category")
    for src in "$udir"/*; do
        [ -e "$src" ] || continue
        name=${src##*/}
        _is_backup "$name" && continue
        _entry_kind_ok "$category" "$src" || continue
        dest="$pdir/$name"
        if [ -n "$skip" ] && _listed "$name" "$skip"; then
            if [ "$name" = synced ]; then
                _left "$category/$name" "Claude Code syncs the profile's own"
            else
                _left "$category/$name" "ags installs its own"
            fi
            continue
        fi
        # A command named like a skill the profile has of its own would answer
        # the same slash command twice.
        if [ "$category" = claude/commands ] && [ -d "$p_claude/skills/${name%.md}" ] \
            && [ ! -L "$p_claude/skills/${name%.md}" ]; then
            _left "$category/$name" "the profile has a ${name%.md} skill"
            continue
        fi
        if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
            continue
        fi
        if [ -e "$dest" ] || [ -L "$dest" ]; then
            _left "$category/$name" "the profile has its own"
            continue
        fi
        if [ "$dry" -eq 0 ]; then
            mkdir -p "$pdir"
            ln -s "$src" "$dest"
        fi
        _did link linked "$category/$name"
    done
}

_link_file() {  # what, user_file, profile_file
    [ -f "$2" ] || return 0
    if [ -L "$3" ] && [ "$(readlink "$3")" = "$2" ]; then
        return 0
    fi
    if [ -e "$3" ] || [ -L "$3" ]; then
        _left "$1" "the profile has its own"
        return 0
    fi
    [ "$dry" -eq 1 ] || ln -s "$2" "$3"
    _did link linked "$1"
}

# Replace a profile file with new content, atomically and keeping its mode.
# The first change to each file copies it to <file>.pre-carry-over.
_replace() {  # dest, new_content_file, mode_for_a_new_file
    local dest="$1" tmp
    [ "$dry" -eq 0 ] || return 0
    if [ -f "$dest" ] && [ ! -e "$dest.pre-carry-over" ]; then
        cp -p "$dest" "$dest.pre-carry-over"
    fi
    tmp=$(mktemp "$dest.carry.XXXXXX")
    if [ -f "$dest" ]; then cp -p "$dest" "$tmp"; else chmod "$3" "$tmp"; fi
    cat "$2" > "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
}

# A JSON file is rewritten only when its content changes, so a rerun leaves
# every byte where it was. A profile file that is a link, or not JSON, is
# left alone with a warning.
_json_target_ok() {  # file
    if [ -L "$1" ]; then
        printf 'Warning: %s is a link; not merging into it.\n' "$1" >&2
        return 1
    fi
    if [ -e "$1" ] && ! jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
        printf 'Warning: %s is not a JSON object; not merging into it.\n' "$1" >&2
        return 1
    fi
}

_json_changed() {  # before, after
    [ "$(jq -S . "$1")" != "$(jq -S . "$2")" ]
}

_object_or_empty() {  # file -> a JSON object on stdout ({} when missing or not an object)
    if [ -f "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
        cat "$1"
    else
        printf '{}\n'
    fi
}

# ----------------------------------------------------------------- hooks ---

# Claude's settings.json and Codex's hooks.json hold hooks in one shape:
# {hooks: {<event>: [{matcher, hooks: [<handler>]}]}}. A handler is known by
# its event, its group's matcher and its command (its whole definition when it
# runs no command). own_hook, defined in front of these, names the session
# manager's own hooks, which are never carried. The handlers a run adds are
# recorded in a ledger beside the file, so a hook the user later changes or
# removes leaves the profile with it; a hook of the profile's own never does.
# A hook is named by the file it runs, never by its arguments or by an
# assignment, which can carry a token.
claude_own_hook='def own_hook: (.command // "") | tostring | contains("/.claude/hooks/cs/");'
codex_own_hook='def own_hook: (.command // "") | tostring | endswith(" -codex-hook session-start");'
hooks_jq='
def hid: if has("command") then (.command | tostring) else tojson end;
def hook_name: ([39] | implode) as $q | ([34] | implode) as $d
    | [split(" ")[] | ltrimstr($q) | rtrimstr($q) | ltrimstr($d) | rtrimstr($d)
       | select(. != "" and (startswith("-") | not) and (contains("=") | not))]
    | ((map(select(test("^[/~.$]"))) | first) // .[0] // "?") | split("/") | last // "?";
def hook_label: if has("command") then (.command | tostring | hook_name) else "\(.type // "other") hook" end;
def handler_entries: (.hooks // {}) | objects | to_entries[] | .key as $ev | .value | arrays | .[] | objects
    | (.matcher // "" | tostring) as $m | (.hooks | arrays | .[]) | objects | select(own_hook | not)
    | {event: $ev, matcher: $m, command: hid, label: hook_label};
def handlers: [handler_entries | del(.label)];
def stale($u; $ledger): ($u | handlers) as $want | [$ledger[] | select(. as $h | any($want[]; . == $h) | not)];
def is_stale($stale; $ev; $m): type == "object" and (own_hook | not)
    and (hid as $c | any($stale[]; .event == $ev and .matcher == $m and .command == $c));
def prune($stale):
    if ($stale | length) == 0 or (.hooks | type) != "object" then . else
    .hooks |= reduce keys_unsorted[] as $ev (.;
        if (.[$ev] | type) != "array" then . else
        (.[$ev] | length) as $n0
        | .[$ev] |= map(if type == "object" and (.hooks | type) == "array" then
              (.matcher // "" | tostring) as $m | (.hooks | length) as $n
              | .hooks |= map(select(is_stale($stale; $ev; $m) | not))
              | if $n > 0 and (.hooks | length) == 0 then empty else . end
            else . end)
        | if $n0 > 0 and (.[$ev] | length) == 0 then del(.[$ev]) else . end end)
    end;
def merge_hooks($u):
    if ((.hooks | type) | IN("object", "null")) | not then . else
    reduce (($u.hooks // {}) | objects | to_entries[] | select(.value | type == "array")) as $e (.;
        $e.key as $ev
        | if ((.hooks[$ev] | type) | IN("array", "null")) | not then . else
          reduce ($e.value[] | objects | select((.hooks | type) == "array")) as $g (.;
            ($g.matcher // "" | tostring) as $m
            | [.hooks[$ev][]? | objects | select((.matcher // "" | tostring) == $m)
               | .hooks | arrays | .[] | objects | hid] as $have
            | ($g | .hooks |= map(select(type == "object" and (own_hook | not)
                  and (hid as $c | any($have[]; . == $c) | not)))) as $ng
            | if ($ng.hooks | length) > 0 then .hooks[$ev] = ((.hooks[$ev] // []) + [$ng]) else . end)
          end)
    end;
def ledger($u; $before; $old):
    handlers as $a | ($before | handlers) as $b
    | [$u | handlers[] | select(. as $h | any($a[]; . == $h))
        | select(. as $h | any($old[]; . == $h) or (any($b[]; . == $h) | not))] | unique;
'

_ledger_read() {  # ledger, copy ([] when missing or not a list)
    if [ -f "$1" ] && jq -e 'type == "array"' "$1" >/dev/null 2>&1; then cp "$1" "$2"; else printf '[]\n' > "$2"; fi
}

# Written only when it changes; its own record, so no .pre-carry-over copy.
_ledger_write() {  # ledger, new content
    local tmp
    [ "$dry" -eq 0 ] || return 0
    if [ -f "$1" ]; then
        _json_changed "$1" "$2" || return 0
    else
        [ "$(jq -c . "$2")" != '[]' ] || return 0
    fi
    tmp=$(mktemp "$1.carry.XXXXXX")
    chmod 600 "$tmp"
    cat "$2" > "$tmp" && mv -f "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

# ---------------------------------------------------------------- Claude ---

# Settings the profile keeps its own: the model and theme it was set up with,
# the display mode setup.sh carries once, the status lines (the sidebar's
# bridge is handled below), the switch that would turn off ags's own hooks,
# and the login helpers (the profile has a login of its own). Hooks, plugins,
# permissions and the keyed settings are merged entry by entry instead; a
# profile value of another shape than the user's is the profile's and stays.
claude_settings_filter="$claude_own_hook$hooks_jq"'
def add_missing($from):
    reduce ($from | to_entries[]) as $e (.; if has($e.key) then . else . + {($e.key): $e.value} end);
$user[0] as $u
| ($u | del(.model, .theme, .tui, .statusLine, .subagentStatusLine, .disableAllHooks,
            .apiKeyHelper, .awsAuthRefresh, .awsCredentialExport, .gcpAuthRefresh,
            .otelHeadersHelper, .forceLoginMethod, .forceLoginOrgUUID,
            .hooks, .enabledPlugins, .extraKnownMarketplaces, .permissions,
            .modelSettings, .env)) as $prefs
| add_missing($prefs)
| reduce ("enabledPlugins", "extraKnownMarketplaces", "modelSettings", "env") as $k (.;
    if ($u[$k] | type) == "object" and ((.[$k] | type) | IN("object", "null"))
    then .[$k] = ((.[$k] // {}) | add_missing($u[$k])) else . end)
| if ($u.permissions | type) == "object" and ((.permissions | type) | IN("object", "null")) then
    .permissions = (reduce ($u.permissions | to_entries[]) as $e ((.permissions // {});
        if ($e.value | type) == "array" and ((.[$e.key] | type) | IN("array", "null")) then
            .[$e.key] = ((.[$e.key] // []) as $have | $have + [$e.value[] | select(. as $x | any($have[]; . == $x) | not)])
        elif has($e.key) then . else . + {($e.key): $e.value} end))
  else . end
| prune(stale($u; $ledger[0])) | merge_hooks($u)
'

# The Agents sidebar draws its card from the status line payload, so the user's
# status line is its bridge, which renders the line it displaced. The bridge
# takes the profile's place the same way: the profile's own line is kept in
# the profile's agents-sidebar-status/original-statusline, which the bridge
# reads when CLAUDE_CONFIG_DIR is the profile. Once wrapped, a status line the
# profile is given later (ags -statusline enable, or yes to the installer) is
# its choice and stays; delete that file to have the bridge put back.
statusline_original="$p_claude/agents-sidebar-status/original-statusline"
wrapped_statusline=''

_claude_statusline() {  # merged settings file (updated in place)
    local settings="$1" bridge current
    bridge=$(jq -r '(.statusLine | objects | .command) // ""' "$user_claude/settings.json" 2>/dev/null) || return 0
    case "$bridge" in */statusline-bridge.sh) ;; *) return 0 ;; esac
    current=$(jq -r '(.statusLine | objects | .command) // ""' "$settings")
    [ "$current" != "$bridge" ] || return 0
    if [ -e "$statusline_original" ]; then
        _left "statusLine" "it changed after the bridge wrapped it; remove $(_tilde "$statusline_original") to wrap it again"
        return 0
    fi
    jq --slurpfile user "$user_claude/settings.json" '.statusLine = $user[0].statusLine' "$settings" > "$work/statusline.json"
    mv -f "$work/statusline.json" "$settings"
    # Another bridge is not a line of the profile's own.
    case "$current" in */statusline-bridge.sh) current='' ;; esac
    wrapped_statusline="${current:-none}"
    _did "wrap" "wrapped" "the profile's status line${current:+ (${current##*/})} in the Agents sidebar bridge"
}

_claude_settings() {
    local dest="$p_claude/settings.json" user="$user_claude/settings.json" new="$work/settings.json"
    local ledger="$p_claude/.ags-carried-hooks.json"
    [ -f "$user" ] || return 0
    jq -e 'type == "object"' "$user" >/dev/null 2>&1 \
        || { printf 'Warning: %s is not a JSON object; settings not carried.\n' "$user" >&2; return 0; }
    _json_target_ok "$dest" || return 0
    _object_or_empty "$dest" > "$work/settings.before.json"
    _ledger_read "$ledger" "$work/ledger.before.json"
    # jq's own message can quote a value, so it is not shown.
    if ! jq --slurpfile user "$user" --slurpfile ledger "$work/ledger.before.json" \
            "$claude_settings_filter" "$work/settings.before.json" > "$new" 2>/dev/null \
        || ! jq --slurpfile u "$user" --slurpfile b "$work/settings.before.json" --slurpfile l "$work/ledger.before.json" \
            "$claude_own_hook$hooks_jq"'ledger($u[0]; $b[0]; $l[0])' "$new" > "$work/ledger.json" 2>/dev/null; then
        printf 'Warning: could not merge %s into %s; left unchanged.\n' "$user" "$dest" >&2
        return 0
    fi
    _claude_statusline "$new"
    _ledger_write "$ledger" "$work/ledger.json"
    _json_changed "$work/settings.before.json" "$new" || return 0
    _report_settings_delta "$work/settings.before.json" "$new"
    _replace "$dest" "$new" 644
    # The displaced line is recorded once settings.json names the bridge: as
    # the sidebar records it, the command alone with no newline, empty when
    # the profile had none.
    if [ -n "$wrapped_statusline" ] && [ "$dry" -eq 0 ]; then
        [ "$wrapped_statusline" != none ] || wrapped_statusline=''
        mkdir -p "${statusline_original%/*}"
        printf '%s' "$wrapped_statusline" > "$statusline_original"
    fi
}

# Name what a settings merge adds or takes out: keys, hooks, plugins. Never
# values.
_report_settings_delta() {  # before, after
    local line
    while IFS= read -r line; do
        case "$line" in
            '') ;;
            'remove '*) _did remove removed "${line#remove } (gone from ~/.claude)" ;;
            *) _did add added "$line" ;;
        esac
    done <<EOF
$(jq -r --slurpfile a "$2" "$claude_own_hook$hooks_jq"'
    . as $b | $a[0] as $a
    | ([$a | keys[] | select(. as $k | ($b | has($k) | not)) | select(. != "statusLine")
        | "settings \(.)"]
       + [("enabledPlugins", "extraKnownMarketplaces", "modelSettings", "env") as $k
          | ($a[$k] | objects | keys[]) as $n | select(($b[$k] // {}) | has($n) | not)
          | select($b | has($k)) | "settings \($k).\($n)"]
       + [($a.permissions | objects | keys[]) as $k | select($b | has("permissions"))
          | (($a.permissions[$k] | if type == "array" then length else 0 end)
             - ($b.permissions[$k] // [] | if type == "array" then length else 0 end)) as $n
          | if $n > 0 then "settings permissions.\($k) (\($n) entries)"
            elif ($b.permissions | has($k) | not) then "settings permissions.\($k)" else empty end]
       + ([$a | handler_entries] as $ah | [$b | handler_entries] as $bh
          | [($ah - $bh)[] | "hook \(.event): \(.label)"] + [($bh - $ah)[] | "remove hook \(.event): \(.label)"]))
    | .[]' "$1" 2>/dev/null)
EOF
}

_claude_mcp() {
    local dest="$p_claude/.claude.json" new="$work/claude.json" names name
    [ -f "$user_claude_json" ] || return 0
    names=$(jq -r '(.mcpServers // {}) | if type == "object" then keys[] else empty end' "$user_claude_json" 2>/dev/null) || return 0
    [ -n "$names" ] || return 0
    _json_target_ok "$dest" || return 0
    _object_or_empty "$dest" > "$work/claude.before.json"
    if ! jq --slurpfile user "$user_claude_json" '
        $user[0].mcpServers as $m
        | .mcpServers = (reduce ($m | to_entries[]) as $e ((.mcpServers // {});
            if has($e.key) then . else . + {($e.key): $e.value} end))' "$work/claude.before.json" > "$new" 2>/dev/null; then
        printf 'Warning: could not merge the MCP servers of %s into %s; left unchanged.\n' "$user_claude_json" "$dest" >&2
        return 0
    fi
    _json_changed "$work/claude.before.json" "$new" || return 0
    for name in $(jq -r --slurpfile b "$work/claude.before.json" \
        '.mcpServers | keys[] | select(. as $n | ($b[0].mcpServers // {}) | has($n) | not)' "$new"); do
        _did add added "Claude MCP server $name"
        # A remote server signs in per configuration directory.
        if jq -e --arg n "$name" '.mcpServers[$n] | has("url")' "$new" >/dev/null 2>&1; then
            carried_claude_mcp="$carried_claude_mcp $name"
        fi
    done
    _replace "$dest" "$new" 600
}

# Plugins come from the user's own cache, copied (a clone on APFS) into the
# profile's cache and recorded in its registry, so nothing is downloaded and
# the profile's Claude updates them on its own from then on. A plugin the
# profile already has installed is the profile's.
_copy_tree() {  # src, dest
    local tmp
    [ "$dry" -eq 0 ] || return 0
    mkdir -p "${2%/*}"
    tmp="$2.carry.$$"
    rm -rf "$tmp"
    cp -cpR "$1" "$tmp" 2>/dev/null || { rm -rf "$tmp"; cp -pR "$1" "$tmp"; }
    mv "$tmp" "$2"
}

_claude_plugins() {
    local user_reg="$user_claude/plugins/installed_plugins.json" user_mkts="$user_claude/plugins/known_marketplaces.json"
    local reg="$p_claude/plugins/installed_plugins.json" mkts="$p_claude/plugins/known_marketplaces.json"
    local ids id entry src rel dest mkt mentry loc
    [ -f "$user_claude/settings.json" ] && [ -f "$user_reg" ] || return 0
    # A plugin set to false is installed but switched off: nothing to carry.
    ids=$(jq -r '(.enabledPlugins // {}) | objects | to_entries[] | select(.value != false and .value != null) | .key' \
        "$user_claude/settings.json" 2>/dev/null) || return 0
    [ -n "$ids" ] || return 0
    _json_target_ok "$reg" || return 0
    _json_target_ok "$mkts" || return 0
    jq -e '(.plugins | type) == "object"' "$user_reg" >/dev/null 2>&1 || return 0
    _object_or_empty "$reg" > "$work/reg.before.json"
    if ! jq -e '(.plugins | type) | IN("object", "null")' "$work/reg.before.json" >/dev/null 2>&1; then
        printf 'Warning: %s holds no plugin list of the usual shape; plugins not carried.\n' "$reg" >&2
        return 0
    fi
    _object_or_empty "$mkts" > "$work/mkts.before.json"
    cp "$work/reg.before.json" "$work/reg.json"
    cp "$work/mkts.before.json" "$work/mkts.json"
    for id in $ids; do
        jq -e --arg id "$id" 'any(.plugins[$id][]?; .scope == "user")' "$work/reg.json" >/dev/null && continue
        entry=$(jq -c --arg id "$id" 'first(.plugins[$id][]? | select(.scope == "user")) // empty' "$user_reg")
        if [ -z "$entry" ]; then
            _left "plugin $id" "not installed in ~/.claude"
            continue
        fi
        src=$(printf '%s' "$entry" | jq -r '.installPath // ""')
        case "$src" in
            "$user_claude/plugins/cache/"*) rel=${src#"$user_claude/plugins/cache/"} ;;
            *) _left "plugin $id" "its files are not in ~/.claude/plugins/cache"; continue ;;
        esac
        [ -d "$src" ] || { _left "plugin $id" "its cached files are gone"; continue; }
        mkt=${id##*@}
        if ! jq -e --arg m "$mkt" 'has($m)' "$work/mkts.json" >/dev/null; then
            mentry=$(jq -c --arg m "$mkt" '.[$m] // empty' "$user_mkts" 2>/dev/null || true)
            if [ -z "$mentry" ]; then
                _left "plugin $id" "its marketplace $mkt is unknown"
                continue
            fi
            loc=$(printf '%s' "$mentry" | jq -r '.installLocation // ""')
            case "$loc" in
                "$user_claude/plugins/marketplaces/"*)
                    dest="$p_claude/plugins/marketplaces/${loc#"$user_claude/plugins/marketplaces/"}"
                    [ -e "$dest" ] || _copy_tree "$loc" "$dest"
                    mentry=$(printf '%s' "$mentry" | jq -c --arg l "$dest" '.installLocation = $l') ;;
            esac
            jq --arg m "$mkt" --argjson e "$mentry" '.[$m] = $e' "$work/mkts.json" > "$work/mkts.next" \
                && mv -f "$work/mkts.next" "$work/mkts.json"
            _did add added "plugin marketplace $mkt"
        fi
        dest="$p_claude/plugins/cache/$rel"
        [ -e "$dest" ] || _copy_tree "$src" "$dest"
        jq --arg id "$id" --argjson e "$entry" --arg p "$dest" '
            .version = (.version // 2)
            | .plugins = (.plugins // {})
            | .plugins[$id] = ((.plugins[$id] // []) + [$e | .installPath = $p])' "$work/reg.json" > "$work/reg.next" \
            && mv -f "$work/reg.next" "$work/reg.json"
        _did copy copied "plugin $id"
    done
    if _json_changed "$work/mkts.before.json" "$work/mkts.json"; then _replace "$mkts" "$work/mkts.json" 644; fi
    if _json_changed "$work/reg.before.json" "$work/reg.json"; then _replace "$reg" "$work/reg.json" 644; fi
}

# ----------------------------------------------------------------- Codex ---

# The tables of a TOML document, read line by line: a header opens a table
# unless it sits inside a multi-line string or array, and every line belongs
# to the table whose header comes before it. Modes:
#   servers  the names of the MCP servers the document defines, in any form
#   has      exit 0 when the document defines table TABLE, in any form
#   inline   exit 0 when the document defines table TABLE as one inline
#            table (TABLE = {...}), which no [TABLE.x] header may extend
#   extract  the [mcp_servers.<name>] tables (subtables included) for the
#            names in WANT, and the TABLE tables, verbatim, blank-separated
toml_awk='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# Split a dotted key into K[1..n]; quoted parts may hold dots.
function split_key(s,    i, c, q, part, n) {
    n = 0; part = ""; q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; else part = part c; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == ".") { K[++n] = trim(part); part = ""; continue }
        part = part c
    }
    K[++n] = trim(part)
    return n
}
# Count brackets outside strings and comments, and notice a multi-line string.
function scan(s,    i, j, c, q) {
    q = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "" && (substr(s, i, 3) == "\"\"\"" || substr(s, i, 3) == "\047\047\047")) {
            # A multi-line string opens here unless it also closes on this line.
            j = index(substr(s, i + 3), substr(s, i, 3))
            if (j == 0) { ml = substr(s, i, 3); return }
            i += j + 4; continue
        }
        if (q != "") { if (c == "\\" && q == "\"") { i++; continue } if (c == q) q = ""; continue }
        if (c == "\"" || c == "\047") { q = c; continue }
        if (c == "#") return
        if (c == "[") depth++
        else if (c == "]") depth--
    }
}
BEGIN {
    WANT = ENVIRON["TOML_WANT"]; TABLE = ENVIRON["TOML_TABLE"]
    n = split(WANT, w, "\n"); for (i = 1; i <= n; i++) if (w[i] != "") want[w[i]] = 1
    depth = 0; ml = ""; t1 = ""; t2 = ""; keep = 0; blanks = 0
}
{
    line = $0
    if (ml != "") { if (index(line, ml)) ml = ""; if (keep) print line; next }
    if (depth == 0 && line ~ /^[ \t]*\[/) {
        h = line; sub(/^[ \t]*\[\[?/, "", h); sub(/\]\]?[ \t]*(#.*)?$/, "", h)
        n = split_key(h); t1 = K[1]; t2 = (n >= 2 ? K[2] : "")
        if (t1 == "mcp_servers" && t2 != "" && !(t2 in seen)) { seen[t2] = 1; order[++count] = t2 }
        if (t1 == TABLE) found = 1
        keep = ((t1 == "mcp_servers" && t2 in want) || (TABLE != "" && t1 == TABLE))
        if (MODE == "extract" && keep) { if (printed) print ""; printed = 1; blanks = 0; print line }
        next
    }
    if (depth == 0 && line ~ /^[ \t]*[^ \t#=]+[ \t]*=/) {
        k = line; sub(/[ \t]*=.*$/, "", k); n = split_key(trim(k))
        # Dotted keys and inline tables define servers and tables too.
        if (t1 == "" && K[1] == "mcp_servers" && n >= 2 && !(K[2] in seen)) { seen[K[2]] = 1; order[++count] = K[2] }
        if (t1 == "mcp_servers" && t2 == "" && !(K[1] in seen)) { seen[K[1]] = 1; order[++count] = K[1] }
        if (t1 == "" && K[1] == TABLE) { found = 1; if (n == 1) inline = 1 }
    }
    scan(line)
    if (MODE == "extract" && keep) {
        if (line ~ /^[ \t]*$/) { blanks++; next }
        while (blanks > 0) { print ""; blanks-- }
        print line
    }
}
END {
    if (MODE == "servers") for (i = 1; i <= count; i++) print order[i]
    if (MODE == "has") exit(found ? 0 : 1)
    if (MODE == "inline") exit(inline ? 0 : 1)
}'

_toml() {  # mode, file, [want], [table]
    # Through the environment: awk -v refuses a value with a newline in it.
    TOML_WANT="${3:-}" TOML_TABLE="${4:-}" awk -v MODE="$1" "$toml_awk" "$2"
}

# A config.toml that Python can parse, when this machine has a Python with
# tomllib (3.11+); without one there is nothing to check against.
_toml_ok() {  # file
    local py
    for py in python3 /usr/bin/python3; do
        command -v "$py" >/dev/null 2>&1 || continue
        "$py" -c 'import tomllib' 2>/dev/null || continue
        "$py" -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1" 2>/dev/null
        return
    done
    return 0
}

_append_block() {  # file, block_file
    if [ -s "$1" ]; then printf '\n' >> "$1"; fi
    cat "$2" >> "$1"
}

_codex_config() {  # working copy of the profile's config.toml (updated in place)
    local config="$1" user="$user_codex/config.toml" have missing='' name copied
    [ -f "$user" ] || return 0
    have=$(_toml servers "$config")
    for name in $(_toml servers "$user"); do
        _listed "$name" "$have" && continue
        missing="$missing$name"$'\n'
    done
    # A [mcp_servers.x] table cannot extend mcp_servers = {...}.
    if [ -n "$missing" ] && _toml inline "$config" '' mcp_servers; then
        _note "the profile's config.toml holds mcp_servers as one inline table; copy your Codex MCP servers into it by hand"
        missing=''
    fi
    if [ -n "$missing" ]; then
        _toml extract "$user" "$missing" > "$work/mcp.toml"
        copied=$(_toml servers "$work/mcp.toml")
        for name in $missing; do
            if _listed "$name" "$copied"; then
                _did add added "Codex MCP server $name"
                if _toml extract "$user" "$name" | grep -q '^[[:space:]]*url[[:space:]]*='; then
                    carried_codex_mcp="$carried_codex_mcp $name"
                fi
            else
                _note "Codex MCP server $name is defined inline in ~/.codex/config.toml; copy it into the profile's config.toml by hand"
            fi
        done
        [ -s "$work/mcp.toml" ] && _append_block "$config" "$work/mcp.toml"
    fi
    # The sandbox's writable roots name where the Agents sidebar keeps a
    # session's task line; a profile that has the table keeps its own.
    if _toml has "$user" '' sandbox_workspace_write && ! _toml has "$config" '' sandbox_workspace_write; then
        _toml extract "$user" '' sandbox_workspace_write > "$work/sandbox.toml"
        if [ -s "$work/sandbox.toml" ]; then
            _append_block "$config" "$work/sandbox.toml"
            _did add added "Codex [sandbox_workspace_write]"
        fi
    fi
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi
}

# The trusted_hash of [hooks.state."<key>"], when the config has one.
_trusted_hash() {  # config, key
    [ -f "$1" ] || return 0
    awk -v head="[hooks.state.\"$2\"]" '
        $0 == head { inside = 1; next }
        inside && /^[ \t]*\[/ { exit }
        inside && /^[ \t]*trusted_hash[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*"/, "", v); sub(/".*$/, "", v); print v; exit }
    ' "$1"
}

# Codex keys a hook's trust by its position in hooks.json. When a carried hook
# leaves, the hooks after it in that event move up: their trust tables are
# renamed to match and the leaving hook's table goes with it. A table already
# sitting where a hook moves to belongs to no hook and goes too. Each line of
# the moves is: event, old position, new position (empty when it left).
codex_moves_jq="$codex_own_hook$hooks_jq"'
def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
stale($user[0]; $ledger[0]) as $stale
| (.hooks // {}) | objects | to_entries[] | .key as $ev | .value | arrays
| [to_entries[] | .key as $gi | .value
   | if type == "object" and (.hooks | type) == "array" then
       (.matcher // "" | tostring) as $m
       | {gi: $gi, hs: [.hooks | to_entries[] | {hi: .key, drop: (.value | is_stale($stale; $ev; $m))}]}
     else {gi: $gi, hs: []} end
   | .keep = ((.hs | length) == 0 or any(.hs[]; .drop | not))]
| [.[] | select(.keep) | .gi] as $kept
| .[] | .gi as $gi | ($kept | index($gi)) as $ngi
| [.hs[] | select(.drop | not) | .hi] as $live
| .hs[] | .hi as $hi
| [($ev | snake), "\($gi):\($hi)", (if .drop then "" else "\($ngi):\($live | index($hi))" end)]
| select(.[1] != .[2])
| join("\t")'

_codex_trust_moves() {  # config, moves
    awk -F '\t' -v file="$p_codex/hooks.json" '
        function head(ev, pos) { return "[hooks.state.\"" file ":" ev ":" pos "\"]" }
        NR == FNR {
            if ($3 == "") drop[head($1, $2)] = 1
            else { to[head($1, $2)] = head($1, $3); taken[head($1, $3)] = 1 }
            next
        }
        # Blank lines wait for the next line that survives, as in
        # _codex_trust_tables_edit.
        /^[[:space:]]*$/ { if (!skip) blanks++; next }
        /^[[:space:]]*\[/ { skip = (($0 in drop) || (($0 in taken) && !($0 in to))) }
        skip { next }
        { while (blanks > 0) { print ""; blanks-- } }
        $0 in to { print to[$0]; next }
        { print }
    ' "$2" "$1" > "$work/config.moved" && mv -f "$work/config.moved" "$1"
}

# Codex runs a hook only once config.toml trusts it, by its position in
# hooks.json and a hash of its definition (lib/01-manifests.sh). A carried hook
# is trusted in the profile exactly when ~/.codex trusts the definition the
# profile holds: the user's own review carries over, and nothing the user
# never approved runs. The new hooks.json is left in codex_hooks_new for
# _codex_config_and_hooks to write with the config.toml that trusts it.
_codex_hooks() {  # working copy of the profile's config.toml (updated in place)
    local config="$1" user="$user_codex/hooks.json" dest="$p_codex/hooks.json" new="$work/hooks.json"
    local hj pgi phi ugi uhi ev hash want pkey ukey line hooks_changed=0
    [ -f "$user" ] || return 0
    jq -e 'type == "object"' "$user" >/dev/null 2>&1 \
        || { printf 'Warning: %s is not a JSON object; Codex hooks not carried.\n' "$user" >&2; return 0; }
    _json_target_ok "$dest" || return 0
    _object_or_empty "$dest" > "$work/hooks.before.json"
    _ledger_read "$p_codex/.ags-carried-hooks.json" "$work/codex-ledger.before.json"
    if ! jq --slurpfile user "$user" --slurpfile ledger "$work/codex-ledger.before.json" "$codex_own_hook$hooks_jq"'
            $user[0] as $u | prune(stale($u; $ledger[0])) | merge_hooks($u)
            | if .hooks == {} then del(.hooks) else . end' "$work/hooks.before.json" > "$new" 2>/dev/null \
        || ! jq --slurpfile u "$user" --slurpfile b "$work/hooks.before.json" --slurpfile l "$work/codex-ledger.before.json" \
            "$codex_own_hook$hooks_jq"'ledger($u[0]; $b[0]; $l[0])' "$new" > "$work/codex-ledger.json" 2>/dev/null \
        || ! jq -r --slurpfile user "$user" --slurpfile ledger "$work/codex-ledger.before.json" \
            "$codex_moves_jq" "$work/hooks.before.json" > "$work/hooks.moves" 2>/dev/null; then
        printf 'Warning: could not merge %s into %s; left unchanged.\n' "$user" "$dest" >&2
        return 0
    fi
    codex_ledger_new="$work/codex-ledger.json"
    if _json_changed "$work/hooks.before.json" "$new"; then
        jq -r --slurpfile a "$new" "$codex_own_hook$hooks_jq"'
            [$a[0] | handler_entries] as $ah | [handler_entries] as $bh
            | (($ah - $bh)[] | "+ \(.event): \(.label)"), (($bh - $ah)[] | "- \(.event): \(.label)")' \
            "$work/hooks.before.json" > "$work/hooks.delta" 2>/dev/null || :
        while IFS= read -r line; do
            case "$line" in
                '- '*) _did remove removed "Codex hook ${line#- } (gone from ~/.codex)" ;;
                *) _did add added "Codex hook ${line#+ }" ;;
            esac
        done < "$work/hooks.delta"
        hooks_changed=1
        [ ! -s "$work/hooks.moves" ] || _codex_trust_moves "$config" "$work/hooks.moves"
        codex_hooks_new="$new"
    fi
    # Pair each carried handler in the profile with the user's handler of the
    # same event, matcher and command, and hash the profile's own definition
    # as Codex does.
    jq -r -c -S --slurpfile user "$user" "$codex_own_hook$hooks_jq"'
        def snake: gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
        [$user[0] | (.hooks // {}) | objects | to_entries[] | .key as $ev | .value | arrays | to_entries[]
         | .key as $gi | .value | objects | (.matcher // "" | tostring) as $m
         | (.hooks | arrays | to_entries[]) | select(.value | type == "object")
         | {ev: $ev, m: $m, gi: $gi, hi: .key, c: (.value | hid)}] as $uh
        | (.hooks // {}) | objects | to_entries[] | .key as $ev | .value | arrays | to_entries[]
        | .key as $pgi | .value | objects | . as $pg | (.matcher // "" | tostring) as $m
        | (.hooks | arrays | to_entries[]) | .key as $phi | .value | objects | . as $ph
        | select(own_hook | not)
        | (first($uh[] | select(.ev == $ev and .m == $m and .c == ($ph | hid))) // null) as $mu
        | select($mu != null)
        | ($ev | snake) as $e
        # Codex holds a SessionEnd hook to 3 seconds (1 when unset) and hashes
        # the timeout it will use.
        | (if $e == "session_end" then ([($ph.timeout // 1), 3] | min) else ($ph.timeout // 600) end) as $t
        | "\($pgi) \($phi) \($mu.gi) \($mu.hi) \($e)",
          ({event_name: $e,
            hooks: [{async: ($ph.async // false), command: $ph.command,
                     timeout: $t, type: ($ph.type // "command")}
                    + (if $ph.statusMessage != null then {statusMessage: $ph.statusMessage} else {} end)]}
           + (if $pg.matcher != null then {matcher: $pg.matcher} else {} end))' "$new" > "$work/trust.lines"
    while IFS=' ' read -r pgi phi ugi uhi ev && IFS= read -r hj; do
        hash=$(printf '%s' "$hj" | _sha256)
        want="sha256:$hash"
        ukey="$user_codex/hooks.json:$ev:$ugi:$uhi"
        pkey="$p_codex/hooks.json:$ev:$pgi:$phi"
        [ "$(_trusted_hash "$config" "$pkey")" != "$want" ] || continue
        if [ "$(_trusted_hash "$user_codex/config.toml" "$ukey")" != "$want" ]; then
            if [ "$dry" -eq 1 ] || [ "$hooks_changed" -eq 1 ]; then
                _note "~/.codex does not trust Codex hook $ev:$pgi:$phi as the profile holds it; Codex skips it until you trust it in an ags Codex session"
            fi
            continue
        fi
        _codex_trust_tables_edit "$config" "$p_codex/hooks.json" "" "$pkey"
        if [ -s "$config" ]; then printf '\n' >> "$config"; fi
        printf '[hooks.state."%s"]\ntrusted_hash = "%s"\n' "$pkey" "$want" >> "$config"
        _did trust trusted "Codex hook $ev:$pgi:$phi (trusted in ~/.codex)"
    done < "$work/trust.lines"
}

_codex_config_and_hooks() {
    local dest="$p_codex/config.toml" config="$work/config.toml" config_changed=0
    if [ -L "$dest" ]; then
        printf 'Warning: %s is a link; not merging into it.\n' "$dest" >&2
        return 0
    fi
    if [ -f "$dest" ]; then cp "$dest" "$config"; else : > "$config"; fi
    _codex_config "$config"
    _codex_hooks "$config"
    if ! { [ -f "$dest" ] && cmp -s "$dest" "$config"; } && { [ -f "$dest" ] || [ -s "$config" ]; }; then
        # A hook's trust sits in config.toml, so hooks.json is not written
        # without it.
        if ! _toml_ok "$config"; then
            printf 'Warning: the merged %s would not parse; it and hooks.json left unchanged.\n' "$dest" >&2
            return 0
        fi
        config_changed=1
    fi
    [ -z "$codex_ledger_new" ] || _ledger_write "$p_codex/.ags-carried-hooks.json" "$codex_ledger_new"
    [ -z "$codex_hooks_new" ] || _replace "$p_codex/hooks.json" "$codex_hooks_new" 600
    [ "$config_changed" -eq 0 ] || _replace "$dest" "$config" 600
}

# ------------------------------------------------------------------ main ---

carried_claude_mcp=''
carried_codex_mcp=''
codex_hooks_new=''
codex_ledger_new=''

if [ "$prune_only" -eq 1 ]; then
    label='Pruning carried links in'
elif [ "$dry" -eq 1 ]; then
    label='Dry run: carrying ~/.claude and ~/.codex into'
else
    label='Carrying ~/.claude and ~/.codex into'
fi
if [ "$has_claude" -eq 1 ]; then
    for category in agents commands skills workflows themes output-styles; do
        _prune_dir "claude/$category" "$user_claude/$category" "$p_claude/$category"
    done
    _prune_file CLAUDE.md "$user_claude/CLAUDE.md" "$p_claude/CLAUDE.md"
    _prune_file keybindings.json "$user_claude/keybindings.json" "$p_claude/keybindings.json"
fi
if [ "$has_codex" -eq 1 ]; then
    for category in skills agents; do
        _prune_dir "codex/$category" "$user_codex/$category" "$p_codex/$category"
    done
    _prune_file AGENTS.md "$user_codex/AGENTS.md" "$p_codex/AGENTS.md"
fi

if [ "$prune_only" -eq 0 ]; then
    if [ "$has_claude" -eq 1 ]; then
        _link_file CLAUDE.md "$user_claude/CLAUDE.md" "$p_claude/CLAUDE.md"
        _link_file keybindings.json "$user_claude/keybindings.json" "$p_claude/keybindings.json"
        for category in agents commands skills workflows themes output-styles; do
            _link_dir "claude/$category" "$user_claude/$category" "$p_claude/$category"
        done
        _claude_settings
        _claude_mcp
        _claude_plugins
    fi
    if [ "$has_codex" -eq 1 ]; then
        _link_file AGENTS.md "$user_codex/AGENTS.md" "$p_codex/AGENTS.md"
        for category in skills agents; do
            _link_dir "codex/$category" "$user_codex/$category" "$p_codex/$category"
        done
        _codex_config_and_hooks
    fi
fi

if [ "$changes" -eq 0 ]; then
    printf '  nothing to change\n'
    exit 0
fi
# A remote MCP server signs in per configuration directory, so one the user
# authorised in ~/.claude or ~/.codex asks again inside the profile.
if [ -n "$carried_claude_mcp" ]; then
    printf 'Remote Claude MCP servers sign in per profile; if one asks, log in with /mcp in an ags Claude session:%s\n' "$carried_claude_mcp"
fi
if [ -n "$carried_codex_mcp" ]; then
    printf 'Remote Codex MCP servers sign in per profile; if one asks: CODEX_HOME=%s codex mcp login <name>:%s\n' "$(_tilde "$p_codex")" "$carried_codex_mcp"
fi
[ "$dry" -eq 1 ] || [ "$prune_only" -eq 1 ] || printf 'Rerun with: bash %s\n' "$here/ags-carry-over.sh"
