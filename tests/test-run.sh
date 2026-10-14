#!/usr/bin/env bash
# The daemon loop, driven against a fake sysfs with a recording ectool. The
# temperature is changed under a running daemon and the ectool calls it makes
# are the assertion — the behaviour nobody can check by reading the curve code.
#
# Covered: the duty actually applied, climbing and falling, no duplicate call
# when nothing changed, the periodic re-assert (the EC forgets across
# suspend/resume), holding the last duty when sensors go unreadable, and the
# hand-back to the EC on SIGTERM.
#
# Usage: tests/test-run.sh              # uses ../thermal-exhaust-port.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="${TEP:-${TEST_DIR}/../thermal-exhaust-port.sh}"
[[ -f "$E" ]] || { echo "engine not found at $E" >&2; exit 1; }
unset TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS

# PID must be empty-safe: `kill "${PID:-0}"` becomes `kill 0`, which signals
# the script's OWN process group and takes the suite down with it.
PID=""
T="$(mktemp -d)"
trap '[[ -n "$PID" ]] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
mkdir -p "$T/stub" "$T/hwmon/hwmon0"
CALLS="$T/calls"; : > "$CALLS"; export CALLS
TEMP="$T/hwmon/hwmon0/temp1_input"
printf 'k10temp\n' > "$T/hwmon/hwmon0/name"

cat > "$T/stub/ectool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
exit 0
STUB
chmod +x "$T/stub/ectool"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

settemp() { printf '%s\n' "$(( $1 * 1000 ))" > "$TEMP"; }
calls()   { cat "$CALLS"; }
last()    { tail -n1 "$CALLS" 2>/dev/null; }
count()   { grep -cF "$1" "$CALLS" 2>/dev/null || true; }

# Poll rather than sleep a fixed time: a loaded runner is slower than a
# workstation, and a fixed sleep turns that into a flaky failure.
wait_for() {
    local want="$1" limit="${2:-50}" i=0
    while (( i < limit )); do
        grep -qF "$want" "$CALLS" && return 0
        sleep 0.1; i=$(( i + 1 ))
    done
    return 1
}
wait_last() {
    local want="$1" limit="${2:-50}" i=0
    while (( i < limit )); do
        [[ "$(last)" == "$want" ]] && return 0
        sleep 0.1; i=$(( i + 1 ))
    done
    return 1
}

echo "## 1. the loop applies the curve"

settemp 71
TEP_SUDO="" bash "$E" run --curve "70:40 80:100" --hyst 4 --interval 1 --reassert 3 \
    --sensors k10temp --hwmon "$T/hwmon" --ectool "$T/stub/ectool" >/dev/null 2>&1 &
PID=$!

check "71C applies the 70:40 step"          wait_for "fanduty 40"

settemp 85
check "85C climbs to the 80:100 step"       wait_for "fanduty 100"

# Falling to 79 must NOT leave the 100 step: hysteresis holds it until 80-4.
n_before="$(count 'fanduty 40')"
settemp 79
sleep 2
check "79C holds 100% (hysteresis)"         [ "$(count 'fanduty 40')" = "$n_before" ]

settemp 75
check "75C falls to the 70:40 step"         wait_last "fanduty 40"

settemp 60
check "60C hands control back to the EC"    wait_for "autofanctrl"

echo "## 2. nothing changed means nothing is re-sent, except the re-assert"

# The EC forgets a forced duty across suspend/resume, so the current state is
# re-sent every --reassert seconds even when the step has not moved. That is
# the ONLY repeat the loop should make.
settemp 85
wait_for "fanduty 100" || true
: > "$CALLS"
sleep 4
n="$(count 'fanduty 100')"
check "a steady temperature re-asserts, not spins"  [ "$n" -ge 1 ]
check "and re-asserts sparingly, not every tick"    [ "$n" -le 3 ]

echo "## 3. an unreadable sensor holds the last duty"

# The dangerous failure this prevents: treating a failed read as 0C and handing
# a hot machine back to the EC's lazy curve.
: > "$CALLS"
mv "$TEMP" "$T/parked"
sleep 3
check "no hand-back when sensors disappear"  [ "$(count autofanctrl)" = "0" ]
# Nothing is re-sent while blind either — there is no reading to justify a
# duty — so "held" means the EC keeps the last duty it was given, which is the
# absence of any new call rather than a repeat of the old one.
check "and no lower step is applied on a guess" [ "$(count 'fanduty 40')" = "0" ]
mv "$T/parked" "$TEMP"

echo "## 4. stopping hands the fans back"

: > "$CALLS"
kill -TERM "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
check "SIGTERM triggers autofanctrl"         wait_for "autofanctrl" 30
PID=""

echo "## 5. the unit's environment reaches the daemon"

# THE GAP THAT LET A REAL BUG THROUGH: the unit wrote Environment="CURVE=..."
# while the daemon read TEP_CURVE, so the service silently ran its defaults
# while `config` and `status` reported the unit's curve. Checking that the unit
# CONTAINS a line, and that `config` can read it back, proves neither that the
# daemon reads the same name.
#
# So: generate a unit, apply its Environment lines the way systemd would, start
# the daemon with no flags at all, and assert it announces the unit's curve.
# install needs a systemctl, which is not stubbed in this suite, so the unit is
# captured from --dry-run: the same renderer, without needing to write or enable
# anything.
bash "$E" install --dry-run --unit "$T/gen.service" --bin "$T/gen.sh" \
    --curve "55:25 65:55 85:100" --hyst 7 --interval 1 --sensors k10temp \
    --ectool "$T/stub/ectool" --hwmon "$T/hwmon" 2>&1 \
    | sed -n 's/^ *\(Environment=.*\)$/\1/p' > "$T/envlines"

check "the unit carries Environment lines"  [ -s "$T/envlines" ]

# Export them exactly as systemd would, then run with NO flags: whatever the
# daemon announces came from the unit alone.
: > "$CALLS"
settemp 70
(
    while IFS= read -r line; do
        line="${line#Environment=}"; line="${line%\"}"; line="${line#\"}"
        export "${line?}"
    done < "$T/envlines"
    exec env TEP_SUDO="" bash "$E" run --ectool "$T/stub/ectool" --hwmon "$T/hwmon" \
        >"$T/unitrun.log" 2>&1
) &
PID=$!
check "the daemon applies the unit's curve, not its defaults" wait_for "fanduty 55"
check "  and announces the unit's curve"    grep -qF '55:25 65:55 85:100' "$T/unitrun.log"
check "  with the unit's hysteresis"        grep -qF 'hysteresis 7C' "$T/unitrun.log"
check "  and the unit's sensor set"         grep -qF 'sensors: k10temp)' "$T/unitrun.log"
kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""

# Every key render_unit writes must be one the engine reads, or the next rename
# reintroduces the same silent split.
check "every Environment key is a TEP_ one the engine reads" bash -c '
    while IFS= read -r l; do
        k="${l#Environment=}"; k="${k#\"}"; k="${k%%=*}"
        case "$k" in TEP_CURVE|TEP_HYST|TEP_INTERVAL|TEP_REASSERT|TEP_SENSORS) ;;
            *) echo "unread key in unit: $k" >&2; exit 1 ;;
        esac
    done < "'"$T"'/envlines"'

echo "## 6. the loop refuses to start without ectool"

out="$(TEP_SUDO="" bash "$E" run --ectool "$T/stub/nope" --hwmon "$T/hwmon" \
        --sensors k10temp --unit "$T/none.service" 2>&1)" && rc=0 || rc=$?
check "a missing ectool is a startup failure" [ "${rc:-0}" != "0" ]
check "and it says which binary is missing"   grep -q 'nope' <<< "$out"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
