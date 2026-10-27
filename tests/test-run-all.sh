#!/usr/bin/env bash
# The runner itself: a test file that hangs must FAIL the run, in bounded
# time, and the others must still run. Without that, a daemon that stopped
# exiting on TERM (test-run.sh section 4) stalled CI instead of failing it.
#
# The runner finds its test files beside itself, so it is copied into a temp
# directory next to a hanging and a passing file.
#
# Usage: tests/test-run-all.sh          # uses ./run-all.sh
#        RUNALL=/path/to/run-all.sh tests/test-run-all.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="${RUNALL:-${TEST_DIR}/run-all.sh}"
[[ -f "$R" ]] || { echo "runner not found at $R" >&2; exit 1; }

T="$(mktemp -d)"; P=""
trap '[[ -n "$P" ]] && kill -KILL "$P" 2>/dev/null; rm -rf "$T"' EXIT
cp "$R" "$T/run-all.sh"
printf '#!/usr/bin/env bash\nexec sleep 60\n' > "$T/test-a-hang.sh"
printf '#!/usr/bin/env bash\necho "   ok   - fine"\n' > "$T/test-b-pass.sh"
printf '#!/usr/bin/env bash\necho "   FAIL - broken"; exit 1\n' > "$T/test-c-fail.sh"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

echo "## 1. a hanging test file fails the run, in bounded time"

TEP_TEST_TIMEOUT=2 bash "$T/run-all.sh" > "$T/out" 2>&1 &
P=$!
i=0; while kill -0 "$P" 2>/dev/null && (( i < 200 )); do sleep 0.1; i=$(( i + 1 )); done
if kill -0 "$P" 2>/dev/null; then rc=124; kill -KILL "$P" 2>/dev/null; wait "$P" 2>/dev/null
else wait "$P"; rc=$?; fi
P=""
check "the run ends on its own (not after our 20 s cap)" [ "$rc" != "124" ]
check "  and fails"                                      [ "$rc" = "1" ]
check "  naming the file that timed out"                 grep -q 'FAIL  test-a-hang.sh  (timed out after 2s)' "$T/out"
check "  the next files still run"                       grep -q 'PASS  test-b-pass.sh' "$T/out"
check "  a plain failure is still reported with its checks" grep -q 'FAIL - broken' "$T/out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
