# ABOUTME: Codex hook entry points. The installer registers `cs -codex-hook session-start`
# ABOUTME: in $CODEX_HOME/hooks.json; it rebinds after /clear and carries an armed rotation.

# What a fresh Codex conversation is told when it continues a rotation, both
# after /clear (this hook) and after `r` at launch (the launch context). The
# Claude wording lives in hooks/session-start.sh, which cannot source cs.
# Codex starts no turn on its own after /clear, so the context arrives with the
# user's first message and says how to read it. printf, not a here-document:
# bash 3.2 writes a here-document to a temp file.
_rotation_preamble_codex() {  # handoff_basename, actor_slug
    printf '%s\n' \
        '--- Conversation Rotation ---' \
        "This fresh conversation continues rotated work. Read .cs/handoffs/$1 FIRST — it is the previous conversation's handoff; the prior conversation is not loaded, and the handoff plus your own .cs/memory/narrative.$2.md carry the context." \
        '' \
        'The message that arrives with this context starts the work. A bare nudge — "go", "continue", "ok" — means begin: execute the handoff'"'"'s next step and report what you did, without re-summarising the handoff or asking which part to start with. A message carrying its own content takes precedence over the handoff; answer that instead. Ask first only where you normally would: the handoff is missing, unreadable, or genuinely ambiguous, or its next step is destructive or irreversible.' \
        '' \
        "Once that next step is done, append a \`## Successor report\` section to the end of .cs/handoffs/$1: each thing you had to look up again, re-derive, or found wrong in the handoff, with how you found out, or \`none\`. Append only; never rewrite what the previous conversation wrote."
}

# A /clear with nothing armed: a clean break, said so the conversation does not
# act on history it no longer has.
_fresh_notice_codex() {  # actor_slug
    printf '%s\n' \
        '--- Fresh Conversation ---' \
        'The user explicitly started a fresh conversation in this cs session with /clear; the prior conversation is not loaded. Treat this as a clean break, not a continuation.' \
        '' \
        'For prior context, read as needed:' \
        "- .cs/memory/narrative.$1.md — your findings and decisions from earlier work (append only here)" \
        '- .cs/README.md — session objective'
}

cmd_codex_hook() {  # event
    case "${1:-}" in
        session-start) _codex_hook_session_start ;;
        *)
            printf 'Usage: cs -codex-hook session-start\n' >&2
            return 2
            ;;
    esac
}

# Codex fires SessionStart on the first turn of a thread, before the model
# call: source `resume` for every cs launch (cs creates the thread, then
# resumes it), `clear` for the first message after /clear, with the new
# thread's id. Only `clear` changes anything here; the launch path owns every
# other binding and its own rotation (`r`). The hook must never fail a turn,
# so every path returns 0 and anything it cannot do it skips.
_codex_hook_session_start() {
    local input session_id source session_dir meta actor handoff context="" sysmsg=""
    input=$(cat) || input=""
    session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
    source=$(printf '%s' "$input" | jq -r '.source // ""' 2>/dev/null) || source=""
    # Only a conversation cs launched carries a session; a plain codex run
    # anywhere else passes through untouched.
    [ "${CS_RUN_ENGINE:-}" = codex ] && [ -n "${CS_SESSION_DIR:-}" ] || return 0
    session_dir="$CS_SESSION_DIR"
    meta="$session_dir/.cs"
    [ -d "$meta/local" ] || return 0
    _codex_thread_id_valid "$session_id" || return 0
    # The rotate skill and the launch prompt read which conversations this
    # checkout ran from this line; hooks/session-start.sh writes it for Claude.
    { printf '%s - Session started (source: %s, ID: %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${source:-unknown}" "$session_id" >> "$meta/local/session.log"; } 2>/dev/null || true
    [ "$source" = clear ] || return 0
    # The launched conversation alone may rebind: the slot is one per checkout.
    cs_run_lease_owned "$meta" || return 0
    handoff=$(_rotation_armed_handoff "$session_dir")
    cs_run_with_lease "$meta" _codex_hook_rebind "$session_dir" "$session_id" "$handoff" || return 0
    actor=$(cs_actor_slug "$session_dir" 2>/dev/null) || actor=unknown
    if [ -n "$handoff" ]; then
        _handoff_set_status "$session_dir/.cs/handoffs/$handoff" consumed "$session_id" || true
        rm -f "$meta/local/pending-handoff" 2>/dev/null || true
        context=$(_rotation_preamble_codex "$handoff" "$actor")
        sysmsg="Rotation loaded from $handoff; this conversation continues from it."
    else
        context=$(_fresh_notice_codex "$actor")
    fi
    jq -n --arg context "$context" --arg sysmsg "$sysmsg" '
        {hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $context}}
        + (if $sysmsg == "" then {} else {systemMessage: $sysmsg} end)' 2>/dev/null || true
    return 0
}

# Under the run lease: point the session at the thread /clear opened, so the
# next `cs <name>` resumes it, and record the lineage the way a launch does.
_codex_hook_rebind() {  # session_dir, thread_id, handoff
    local session_dir="$1" thread_id="$2" handoff="$3" previous reason=rebind
    previous=$(cs_binding_read "$session_dir" codex) || return 1
    [ "$previous" != "$thread_id" ] || return 0
    cs_binding_write "$session_dir" codex "$thread_id" || return 1
    _cs_set_local_state_unlocked "$session_dir/.cs/local/state" engine codex || return 1
    [ -z "$handoff" ] || reason=handoff
    { printf '%s - Rebound codex thread: %s -> %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${previous:-none}" "$thread_id" >> "$session_dir/.cs/local/session.log"; } 2>/dev/null || true
    if [ -n "$previous" ]; then
        _timeline_rotated "$session_dir" "$previous" "$thread_id" "$reason" "$handoff" codex || true
    fi
    _timeline_started "$session_dir" codex "$thread_id" clear || true
}
