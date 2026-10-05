# ABOUTME: Builds the engine-neutral identity and file inventory for session context.
# ABOUTME: Supplies data to adapter renderers without reading workspace prose as policy.

# Invoke a renderer with one shared context. Bash's dynamically scoped locals
# keep these read-only-by-contract fields private to this call, without eval,
# exported state, or a jq prerequisite. Renderers own instruction wording and transport; the builder
# only describes the session and its files. Paths are workspace-relative.
#
# An empty actor resolves through the existing shared actor interface.
# A template renderer may pass <actor> to retain a generic actor placeholder.
# Callback arguments follow the four contract arguments unchanged. Its exit
# status is returned to the caller, so failed rendering cannot look successful.
# CS_CONTEXT_* locals are consumed by the named callback in adapter fragments.
# shellcheck disable=SC2034
cs_session_context() {  # session_name, session_dir, actor, renderer, [renderer args...]
    local CS_CONTEXT_NAME="$1" CS_CONTEXT_DIR="$2" CS_CONTEXT_ACTOR="$3"
    local renderer="$4"
    shift 4
    declare -F -- "$renderer" >/dev/null || return 1
    if [ -z "$CS_CONTEXT_ACTOR" ]; then
        CS_CONTEXT_ACTOR=$(cs_actor_slug "$CS_CONTEXT_DIR") || return $?
    fi
    local CS_CONTEXT_META=".cs"
    local CS_CONTEXT_OBJECTIVE="$CS_CONTEXT_META/README.md"
    local CS_CONTEXT_SUMMARY="$CS_CONTEXT_META/summary.md"
    local CS_CONTEXT_MEMORY="$CS_CONTEXT_META/memory"
    local CS_CONTEXT_NARRATIVE="$CS_CONTEXT_MEMORY/narrative.$CS_CONTEXT_ACTOR.md"
    local CS_CONTEXT_ARCHIVE="$CS_CONTEXT_META/narrative-archive/$CS_CONTEXT_ACTOR"
    local CS_CONTEXT_CHECKPOINTS="$CS_CONTEXT_META/checkpoints"
    local CS_CONTEXT_HANDOFFS="$CS_CONTEXT_META/handoffs"
    "$renderer" "$@"
}
