#!/usr/bin/env bash
# Run every tests/test-*.sh against the engine (or $TEP) and exit non-zero if
# any of them fails. No network, no hardware, no privilege: the suites work
# against a fake sysfs hwmon tree, recording ectool/systemctl stubs and
# TEP_SUDO="".
#
# Each file is bounded by TEP_TEST_TIMEOUT seconds (default 300; the slowest
# takes well under a minute). A daemon that stops exiting on TERM, or any other
# hang, then fails the run instead of stalling CI until the job limit.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMIT="${TEP_TEST_TIMEOUT:-300}"
LOGS="$(mktemp -d)"; trap 'rm -rf "$LOGS"' EXIT
failed=()
for t in "$TEST_DIR"/test-*.sh; do
    name=$(basename "$t")
    out="$LOGS/$name.log"
    bash "$t" > "$out" 2>&1 &
    pid=$!
    ticks=0
    while kill -0 "$pid" 2>/dev/null && (( ticks < LIMIT * 10 )); do sleep 0.1; ticks=$(( ticks + 1 )); done
    if kill -0 "$pid" 2>/dev/null; then
        # TERM first, so the suite's own trap can stop the daemon it started.
        kill -TERM "$pid" 2>/dev/null
        ticks=0
        while kill -0 "$pid" 2>/dev/null && (( ticks < 50 )); do sleep 0.1; ticks=$(( ticks + 1 )); done
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "FAIL  ${name}  (timed out after ${LIMIT}s)"; grep -E '^ *FAIL' "$out" | sed 's/^/        /'
        failed+=("$name")
    elif wait "$pid"; then
        echo "PASS  ${name}"
    else
        echo "FAIL  ${name}"; grep -E '^ *FAIL' "$out" | sed 's/^/        /'
        failed+=("$name")
    fi
done
echo
if (( ${#failed[@]} )); then echo "${#failed[@]} test file(s) failed: ${failed[*]}"; exit 1; fi
echo "all test files passed"
