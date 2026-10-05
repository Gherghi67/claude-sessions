#!/usr/bin/env bash
# ABOUTME: Checks the lib/*.sh fragments build.sh joins into bin/ags.
# ABOUTME: A function defined in two fragments is silently overridden by the later one.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"
REPO="$SCRIPT_DIR/.."

# Print "name: fragment fragment" for every function defined in more than one
# of the given fragments. Only top-level definitions count; build.sh joins the
# fragments in order, so of two the later wins without a word. Merging an
# upstream release (scripts/sync-upstream.py) is where one slips in.
duplicate_functions() {
    awk '/^[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)[[:space:]]*\{/ {
             name = $0
             sub(/[[:space:]]*\(\).*/, "", name)
             count[name]++
             where[name] = where[name] " " FILENAME
         }
         END { for (name in count) if (count[name] > 1) print name ":" where[name] }' "$@" | sort
}

test_every_lib_function_is_defined_once() {
    local duplicates
    duplicates=$(cd "$REPO" && duplicate_functions lib/*.sh)
    [ -z "$duplicates" ] || {
        echo "  FAIL: defined in more than one fragment (the later silently wins):"
        echo "$duplicates"
        return 1
    }
}

test_a_function_defined_twice_is_reported_with_both_fragments() {
    mkdir -p "$TEST_TMPDIR/lib"
    printf '_alloc_color() {\n    echo red\n}\n' > "$TEST_TMPDIR/lib/40-state.sh"
    printf '# _alloc_color() { in a comment does not count\n_alloc_color() {\n    echo blue\n}\n' \
        > "$TEST_TMPDIR/lib/42-claude-state.sh"
    printf '_other() { :; }\n' > "$TEST_TMPDIR/lib/50-other.sh"
    assert_eq "_alloc_color: lib/40-state.sh lib/42-claude-state.sh" \
        "$(cd "$TEST_TMPDIR" && duplicate_functions lib/*.sh)"
}

run_test test_every_lib_function_is_defined_once
run_test test_a_function_defined_twice_is_reported_with_both_fragments
report_results
