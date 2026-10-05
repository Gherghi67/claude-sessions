#!/usr/bin/env bash
# ABOUTME: Tests shared binding storage for independent Claude and Codex conversations.
# ABOUTME: Covers missing, damaged, and failed writes without launching either runtime.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_lib.sh"
source "$SCRIPT_DIR/../lib/40-state.sh"
source "$SCRIPT_DIR/../lib/41-bindings.sh"

binding_session() {
    printf '%s/binding session\n' "$TEST_TMPDIR"
}

test_missing_bindings_are_empty() {
    local session_dir
    session_dir=$(binding_session)
    assert_eq "" "$(cs_binding_read "$session_dir" claude)" "missing Claude binding" || return 1
    assert_eq "" "$(cs_binding_read "$session_dir" codex)" "missing Codex binding" || return 1
    assert_not_exists "$session_dir/.cs" "read must not create storage" || return 1
}

test_bindings_keep_storage_and_each_other() {
    local session_dir state codex_file
    session_dir=$(binding_session)
    state="$session_dir/.cs/local/state"
    codex_file="$session_dir/.cs/local/codex-thread-id"
    mkdir -p "$(dirname "$state")"
    printf 'engine: claude\nclaude_session_color: blue\nclaude_session_id: "old-id"\n' > "$state"
    printf 'codex-id\n' > "$codex_file"
    assert_eq old-id "$(cs_binding_read "$session_dir" claude)" "read existing Claude state" || return 1
    assert_eq codex-id "$(cs_binding_read "$session_dir" codex)" "read existing Codex file" || return 1

    cs_binding_write "$session_dir" claude claude-new || return 1
    assert_eq claude-new "$(cs_binding_read "$session_dir" claude)" "Claude replacement" || return 1
    assert_file_contains "$state" '^engine: claude$' "preserve engine preference" || return 1
    assert_file_contains "$state" '^claude_session_color: blue$' "preserve Claude color" || return 1
    assert_eq 1 "$(grep -c '^claude_session_id:' "$state")" "one Claude binding key" || return 1
    assert_eq codex-id "$(cat "$codex_file")" "Claude write preserves Codex binding" || return 1

    cs_binding_write "$session_dir" codex codex-new || return 1
    assert_eq codex-new "$(cs_binding_read "$session_dir" codex)" "Codex replacement" || return 1
    assert_eq claude-new "$(cs_binding_read "$session_dir" claude)" "Codex write preserves Claude binding" || return 1
    assert_eq codex-new "$(cat "$codex_file")" "Codex dedicated file format" || return 1
}

test_storage_validation_is_not_native_id_validation() {
    local session_dir
    session_dir=$(binding_session)
    cs_binding_write "$session_dir" claude opaque-claude-id || return 1
    cs_binding_write "$session_dir" codex opaque-codex-id || return 1
    assert_eq opaque-claude-id "$(cs_binding_read "$session_dir" claude)" "Claude ID shape belongs to adapter" || return 1
    assert_eq opaque-codex-id "$(cs_binding_read "$session_dir" codex)" "Codex ID shape belongs to adapter" || return 1
}

test_unsafe_values_do_not_replace_bindings() {
    local session_dir engine value
    session_dir=$(binding_session)
    for engine in claude codex; do
        cs_binding_write "$session_dir" "$engine" original || return 1
        for value in '' $'first\nsecond' $'first\rsecond'; do
            if cs_binding_write "$session_dir" "$engine" "$value"; then
                echo "  FAIL: $engine accepted an unsafe binding value"
                return 1
            fi
            assert_eq original "$(cs_binding_read "$session_dir" "$engine")" "failed write preserves $engine binding" || return 1
        done
    done
    if cs_binding_write "$session_dir" claude 'quoted"id'; then
        echo '  FAIL: Claude accepted a value its state reader cannot round-trip'
        return 1
    fi
    if cs_binding_write "$session_dir" claude ' leading'; then
        echo '  FAIL: Claude accepted leading whitespace its state reader strips'
        return 1
    fi
    if cs_binding_write "$session_dir" unknown valid; then
        echo '  FAIL: unknown engine accepted'
        return 1
    fi
    if cs_binding_read "$session_dir" unknown >/dev/null; then
        echo '  FAIL: unknown engine read accepted'
        return 1
    fi
}

test_codex_present_but_invalid_storage_fails() {
    local session_dir path
    session_dir=$(binding_session)
    path="$session_dir/.cs/local/codex-thread-id"
    mkdir -p "$(dirname "$path")"
    : > "$path"
    if cs_binding_read "$session_dir" codex >/dev/null; then
        echo '  FAIL: empty Codex binding looked absent'
        return 1
    fi
    printf 'first\nsecond\n' > "$path"
    if cs_binding_read "$session_dir" codex >/dev/null; then
        echo '  FAIL: multiline Codex binding accepted'
        return 1
    fi
    rm "$path"
    mkdir "$path"
    if cs_binding_read "$session_dir" codex >/dev/null; then
        echo '  FAIL: directory Codex binding looked absent'
        return 1
    fi
    rmdir "$path"
    ln -s missing-target "$path"
    if cs_binding_read "$session_dir" codex >/dev/null; then
        echo '  FAIL: dangling Codex binding looked absent'
        return 1
    fi
}

test_unreadable_codex_binding_fails() {
    local session_dir path
    session_dir=$(binding_session)
    path="$session_dir/.cs/local/codex-thread-id"
    mkdir -p "$(dirname "$path")"
    printf 'known-id\n' > "$path"
    chmod 000 "$path"
    if [ -r "$path" ]; then
        chmod 600 "$path"
        return 77
    fi
    if cs_binding_read "$session_dir" codex >/dev/null; then
        chmod 600 "$path"
        echo '  FAIL: unreadable Codex binding looked absent'
        return 1
    fi
    chmod 600 "$path"
}

test_failed_rename_preserves_previous_binding_and_cleans_temp() {
    local session_dir local_dir file
    session_dir=$(binding_session)
    local_dir="$session_dir/.cs/local"
    cs_binding_write "$session_dir" codex original || return 1
    file="$local_dir/codex-thread-id"
    (
        mv() { return 1; }
        if cs_binding_write "$session_dir" codex replacement; then
            echo '  FAIL: failed rename succeeded'
            exit 1
        fi
    ) || return 1
    assert_eq original "$(cat "$file")" "failed write leaves old binding" || return 1
    if compgen -G "$local_dir/.binding.*" >/dev/null; then
        echo '  FAIL: failed write left temporary binding'
        return 1
    fi
}

echo 'Binding storage tests'
run_test test_missing_bindings_are_empty
run_test test_bindings_keep_storage_and_each_other
run_test test_storage_validation_is_not_native_id_validation
run_test test_unsafe_values_do_not_replace_bindings
run_test test_codex_present_but_invalid_storage_fails
run_test test_unreadable_codex_binding_fails
run_test test_failed_rename_preserves_previous_binding_and_cleans_temp
report_results
