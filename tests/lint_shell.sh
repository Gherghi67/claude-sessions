#!/usr/bin/env bash
# ABOUTME: The shell lint CI runs: shellcheck at error severity over every tracked script,
# ABOUTME: then a warning count that may only fall, held to the number in .shellcheck-warnings.

set -euo pipefail

BASELINE_FILE=".shellcheck-warnings"

_die() {  # message
    printf 'lint_shell: %s\n' "$1" >&2
    exit 2
}

command -v shellcheck > /dev/null || _die "shellcheck is not installed"
[ -f "$BASELINE_FILE" ] || _die "no $BASELINE_FILE here; run from the repo root"
baseline=$(cat "$BASELINE_FILE")
case "$baseline" in
    '' | *[!0-9]*) _die "$BASELINE_FILE must hold a whole number, found '$baseline'" ;;
esac

# Every tracked script plus the assembled binaries, which carry no .sh.
files=()
while IFS= read -r f; do
    files+=("$f")
done < <(git ls-files '*.sh'; printf '%s\n' bin/cs bin/cs-secrets bin/cs-statusline bin/cs-subagent-statusline)

if ! shellcheck -S error "${files[@]}"; then
    echo "lint_shell: shellcheck found errors (above)" >&2
    exit 1
fi

# The linter exits 1 when it has findings and 2 or more when it could not run
# (a missing file, a parse failure), so only the latter is a broken lint.
findings=$(mktemp "${TMPDIR:-/tmp}/lint_shell.XXXXXX")
trap 'rm -f "$findings"' EXIT
rc=0
shellcheck -S warning -f gcc "${files[@]}" > "$findings" || rc=$?
[ "$rc" -le 1 ] || _die "shellcheck -S warning exited $rc"
count=$(wc -l < "$findings" | tr -d ' ')

if [ "$count" -gt "$baseline" ]; then
    echo "shellcheck warnings rose from $baseline to $count. Run shellcheck -S warning on the scripts you changed and fix the new ones." >&2
    exit 1
fi
if [ "$count" -lt "$baseline" ]; then
    echo "shellcheck warnings fell from $baseline to $count. Lower $BASELINE_FILE to $count in this change so the count cannot climb back." >&2
    exit 1
fi
echo "shellcheck warnings: $count (baseline $baseline)"
