#!/usr/bin/env bash
# ABOUTME: Tests for tests/lint_shell.sh, the shellcheck gate CI runs
# ABOUTME: Covers the error gate and the warning count held to .shellcheck-warnings

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/test_lib.sh
source "$SCRIPT_DIR/test_lib.sh"

LINT="$SCRIPT_DIR/lint_shell.sh"

# A throwaway repo shaped like cs: the four assembled binaries the lint names,
# and one tracked script carrying exactly one warning (SC2034, unused variable).
_lint_repo() {  # baseline
    REPO="$TEST_TMPDIR/repo"
    mkdir -p "$REPO/bin" "$REPO/tests"
    local b
    for b in ags ags-secrets ags-statusline ags-subagent-statusline; do
        printf '#!/usr/bin/env bash\ntrue\n' > "$REPO/bin/$b"
    done
    printf '#!/usr/bin/env bash\nunused=1\n' > "$REPO/one.sh"
    cp "$LINT" "$REPO/tests/lint_shell.sh"
    printf '%s\n' "$1" > "$REPO/.shellcheck-warnings"
    git -C "$REPO" init -q
    git -C "$REPO" add -A
}

_lint() {
    ( cd "$REPO" && bash tests/lint_shell.sh )
}

test_rising_warnings_fail() {
    command -v shellcheck > /dev/null || return 77
    _lint_repo 0
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "one warning over a baseline of 0 must fail" || return 1
    assert_output_contains "$out" "shellcheck warnings rose from 0 to 1" \
        "the failure must give both counts" || return 1
}

# A lower count must lower the baseline in the same change, or the next
# change could add warnings back up to the old number unnoticed.
test_falling_warnings_fail_until_the_baseline_drops() {
    command -v shellcheck > /dev/null || return 77
    _lint_repo 2
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "one warning under a baseline of 2 must fail" || return 1
    assert_output_contains "$out" "shellcheck warnings fell from 2 to 1. Lower .shellcheck-warnings to 1" \
        "the failure must say what to set the baseline to" || return 1
}

test_warnings_at_the_baseline_pass() {
    command -v shellcheck > /dev/null || return 77
    _lint_repo 1
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 0 "$rc" "a count equal to the baseline must pass: $out" || return 1
    assert_output_contains "$out" "shellcheck warnings: 1 (baseline 1)" \
        "a pass must print the count" || return 1
}

# The error gate runs before the count: an error fails even when the
# warning count matches.
test_an_error_level_finding_fails() {
    command -v shellcheck > /dev/null || return 77
    _lint_repo 1
    printf '#!/usr/bin/env bash\nif true; then\n' > "$REPO/broken.sh"
    git -C "$REPO" add broken.sh
    local out rc=0
    out=$(_lint 2>&1) || rc=$?
    assert_eq 1 "$rc" "a script that does not parse must fail" || return 1
    assert_output_contains "$out" "lint_shell: shellcheck found errors (above)" \
        "the failure must come from the error gate" || return 1
}

# A number past bash's integer range makes both comparisons error out and
# fall through to the pass line, so it is refused like any other bad value.
test_a_baseline_that_is_not_a_number_is_an_error() {
    command -v shellcheck > /dev/null || return 77
    local bad out rc
    for bad in "about 110" "99999999999999999999"; do
        _lint_repo "$bad"
        rc=0
        out=$(_lint 2>&1) || rc=$?
        assert_eq 2 "$rc" "baseline '$bad' must not be compared" || return 1
        assert_output_contains "$out" ".shellcheck-warnings must hold a whole number of at most 9 digits, found '$bad'" \
            "the error must quote the bad baseline" || return 1
        rm -rf "$REPO"
    done
}

run_test test_rising_warnings_fail
run_test test_falling_warnings_fail_until_the_baseline_drops
run_test test_warnings_at_the_baseline_pass
run_test test_an_error_level_finding_fails
run_test test_a_baseline_that_is_not_a_number_is_an_error

report_results
