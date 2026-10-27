#!/usr/bin/env bash
# The daemon loop, driven against a fake sysfs with a recording ectool. The
# temperature is changed under a running daemon and the ectool calls it makes
# are the assertion — the behaviour nobody can check by reading the curve code.
#
# Covered: the duty actually applied, climbing and falling, no duplicate call
# when nothing changed, the periodic re-assert (the EC forgets across
# suspend/resume), a lost chip logged, holding the last duty for a moment when
# sensors go unreadable and then handing back to the EC, refused curves, and
# the hand-back on SIGTERM.
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
# A daemon that ignores TERM (the regression section 4 catches) must not
# outlive the suite, hence the KILL. The TERM trap lets run-all's timeout stop
# this script and still run the cleanup.
stop_daemon() {
    [[ -n "$PID" ]] || return 0
    local i=0
    kill "$PID" 2>/dev/null
    while kill -0 "$PID" 2>/dev/null && (( i < 30 )); do sleep 0.1; i=$(( i + 1 )); done
    kill -KILL "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
    PID=""
}
trap 'stop_daemon; rm -rf "$T"' EXIT
trap 'exit 143' TERM INT
T="$(cd "$T" && pwd)"
mkdir -p "$T/stub" "$T/hwmon/hwmon0"
CALLS="$T/calls"; : > "$CALLS"; export CALLS
TEMP="$T/hwmon/hwmon0/temp1_input"
printf 'k10temp\n' > "$T/hwmon/hwmon0/name"
# A second watched chip, always cooler: losing it must be said, not followed
# silently.
mkdir -p "$T/hwmon/hwmon1"; printf 'amdgpu\n' > "$T/hwmon/hwmon1/name"
GPU="$T/hwmon/hwmon1/temp1_input"; printf '30000\n' > "$GPU"
LOG="$T/run.log"

# While $FAILFLAG exists the stub refuses, the way a busy or wedged EC does.
FAILFLAG="$T/ectool-fails"; export FAILFLAG
cat > "$T/stub/ectool" <<'STUB'
#!/usr/bin/env bash
if [[ -e "$FAILFLAG" ]]; then printf 'FAILED %s\n' "$*" >> "$CALLS"; exit 1; fi
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
wait_log() {
    local want="$1" limit="${2:-50}" i=0
    while (( i < limit )); do
        grep -qF -- "$want" "$LOG" 2>/dev/null && return 0
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

# run_for SECS LOG CMD... — a command that must END on its own (a refusal),
# bounded: a regression that starts the loop instead fails the check rather
# than hanging the suite. 124 when it had to be killed.
run_for() {
    local secs="$1" log="$2" p i=0; shift 2
    "$@" >"$log" 2>&1 &
    p=$!
    while kill -0 "$p" 2>/dev/null && (( i < secs * 10 )); do sleep 0.1; i=$(( i + 1 )); done
    if kill -0 "$p" 2>/dev/null; then kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
    wait "$p"
}

echo "## 1. the loop applies the curve"

settemp 71
TEP_SUDO="" bash "$E" run --curve "70:40 80:100" --hyst 4 --interval 1 --reassert 3 \
    --sensors "k10temp amdgpu" --hwmon "$T/hwmon" --ectool "$T/stub/ectool" >"$LOG" 2>&1 &
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
#
# The step change is waited for BEFORE the log is cleared: before, the log was
# cleared first, so the step change itself (auto -> 100%) landed afterwards and
# satisfied the check with the re-assert deleted.
settemp 85
check "85C is back on the 80:100 step"              wait_last "fanduty 100" 60
: > "$CALLS"
check "a steady temperature re-asserts (--reassert 3)" wait_for "fanduty 100" 70
: > "$CALLS"
sleep 4
n="$(count 'fanduty 100')"
check "and re-asserts sparingly, not every tick"    [ "$n" -le 2 ]
check "  and sends nothing else"                    [ "$(grep -cvF 'fanduty 100' "$CALLS")" = "0" ]

echo "## 3. a lost sensor: said out loud, held for a moment, then the EC"

# Losing one watched chip leaves the curve on the others, which may be the
# cooler ones — so it is logged, not followed silently.
: > "$CALLS"
mv "$GPU" "$T/parked-gpu"
check "a watched chip going away is logged"   wait_log "watched sensor 'amdgpu' is gone"
check "  and the curve carries on on the rest" [ "$(count autofanctrl)" = "0" ]

# The dangerous failure: treating a failed read as 0C and handing a hot machine
# back to the EC's lazy curve on the strength of a driver rebinding. So the
# first failed read holds the duty...
mv "$TEMP" "$T/parked"
check "the first failed read is reported"     wait_log "no readable sensor among"
check "  and holds the duty: no hand-back yet" [ "$(count autofanctrl)" = "0" ]
check "  and no lower step on a guess"        [ "$(count 'fanduty 40')" = "0" ]
# ...but not forever: blind, a held duty may be a low one on a machine that is
# heating up. After 3 failed reads the EC, which reads its own sensors, gets
# the fans back — loudly.
check "after 3 failed reads the fans go back to the EC" wait_for "autofanctrl" 60
check "  said as an error"                    grep -q '\[error\] no readable sensor.*handing the fans back' "$LOG"
check "  and never a lower duty"              [ "$(count 'fanduty 40')" = "0" ]
mv "$T/parked" "$TEMP"; mv "$T/parked-gpu" "$GPU"
check "the curve resumes when a sensor answers" wait_last "fanduty 100" 60
check "  and the chip's return is logged"     wait_log "watched sensor 'amdgpu' is back"

echo "## 4. stopping hands the fans back"

: > "$CALLS"
kill -TERM "$PID" 2>/dev/null
# Bounded: a TERM handler that only cleans up does not end bash, and a bare
# `wait` here would then hang the suite instead of failing it.
i=0; while kill -0 "$PID" 2>/dev/null && (( i < 50 )); do sleep 0.1; i=$(( i + 1 )); done
check "SIGTERM ends the daemon (within 5 s)" bash -c '! kill -0 "$1" 2>/dev/null' _ "$PID"
check "  and hands the fans back"            wait_for "autofanctrl" 30
stop_daemon

echo "## 4b. a refused ectool call is retried every tick"

# --reassert 60, so nothing but the retry can send the duty again inside the
# window: a loop that marked a refused step as applied would sit on the old
# duty until the next re-assert, a minute later.
settemp 71
: > "$CALLS"
TEP_SUDO="" bash "$E" run --curve "70:40 80:100" --hyst 4 --interval 1 --reassert 60 \
    --sensors k10temp --hwmon "$T/hwmon" --ectool "$T/stub/ectool" >"$T/retry.log" 2>&1 &
PID=$!
check "the retry daemon is on the 70:40 step" wait_for "fanduty 40"
: > "$FAILFLAG"
settemp 85
check "a refused step change is attempted"   wait_for "FAILED fanduty 100"
wait_n() { local i=0; while (( i < 50 )); do (( $(count "$1") >= $2 )) && return 0; sleep 0.1; i=$(( i + 1 )); done; return 1; }
check "  and retried on the next tick"       wait_n "FAILED fanduty 100" 2
check "  each refusal logged"                grep -q 'ectool refused 85C -> 100%' "$T/retry.log"
rm -f "$FAILFLAG"
check "it lands as soon as ectool answers"   wait_last "fanduty 100" 30
stop_daemon

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
    # No --ectool and no --hwmon either: before, the unit carried neither, so
    # the service looked for /usr/bin/ectool, exited "not found" and restarted
    # every 5 s, never running the curve (Kamino item 184).
    exec env TEP_SUDO="" bash "$E" run >"$T/unitrun.log" 2>&1
) &
PID=$!
check "the daemon applies the unit's curve, not its defaults" wait_for "fanduty 55"
check "  and announces the unit's curve"    grep -qF '55:25 65:55 85:100' "$T/unitrun.log"
check "  with the unit's hysteresis"        grep -qF 'hysteresis 7C' "$T/unitrun.log"
check "  and the unit's sensor set"         grep -qF 'sensors: k10temp)' "$T/unitrun.log"
stop_daemon

# Every key render_unit writes must be one the engine reads, or the next rename
# reintroduces the same silent split.
check "every Environment key is a TEP_ one the engine reads" bash -c '
    while IFS= read -r l; do
        k="${l#Environment=}"; k="${k#\"}"; k="${k%%=*}"
        case "$k" in TEP_CURVE|TEP_HYST|TEP_INTERVAL|TEP_REASSERT|TEP_SENSORS|TEP_ALLOW_STOP|TEP_ECTOOL|TEP_HWMON) ;;
            *) echo "unread key in unit: $k" >&2; exit 1 ;;
        esac
    done < "'"$T"'/envlines"'
# And the other way round: every knob the daemon needs from install's flags is
# in the unit. A path given to install that the service never sees is the
# same silent split.
for k in TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS TEP_ALLOW_STOP TEP_ECTOOL TEP_HWMON; do
    check "the unit carries ${k}" grep -q "^Environment=\"\{0,1\}${k}=" "$T/envlines"
done
check "  TEP_ECTOOL is the path install was given" grep -qxF "Environment=\"TEP_ECTOOL=$T/stub/ectool\"" "$T/envlines"
check "  TEP_HWMON is the root install was given"  grep -qxF "Environment=\"TEP_HWMON=$T/hwmon\"" "$T/envlines"

echo "## 6. the loop refuses to start without ectool"

out="$(TEP_SUDO="" bash "$E" run --ectool "$T/stub/nope" --hwmon "$T/hwmon" \
        --sensors k10temp --unit "$T/none.service" 2>&1)" && rc=0 || rc=$?
check "a missing ectool is a startup failure" [ "${rc:-0}" != "0" ]
check "and it says which binary is missing"   grep -q 'nope' <<< "$out"

echo "## 7. a curve that cools less when hot never runs"

# The daemon is the last line: whatever wrote its environment (a hand-edited
# unit, a drop-in), it refuses such a curve — and hands the fans back to the
# EC on the way out, so a restart does not leave the previous duty pinned.
settemp 70
: > "$CALLS"
run_for 5 "$T/refuse.log" env TEP_SUDO="" bash "$E" run --curve "60:0 90:100" --interval 1 \
    --sensors k10temp --hwmon "$T/hwmon" --ectool "$T/stub/ectool" && rc=0 || rc=$?
check "a leading 0% curve is refused by run"   [ "$rc" = "1" ]
check "  saying the fans would stop"           grep -q 'STOPS the fans' "$T/refuse.log"
check "  no 0% is ever sent"                   [ "$(count 'fanduty 0')" = "0" ]
check "  and the fans are handed back"         [ "$(count autofanctrl)" -ge 1 ]

: > "$CALLS"
run_for 5 "$T/refuse.log" env TEP_SUDO="" bash "$E" run --curve "72:60 80:20" --interval 1 \
    --sensors k10temp --hwmon "$T/hwmon" --ectool "$T/stub/ectool" && rc=0 || rc=$?
check "a falling curve is refused by run"      [ "$rc" = "1" ]
check "  and nothing but the hand-back is sent" [ "$(calls)" = "autofanctrl" ]

: > "$CALLS"
TEP_SUDO="" TEP_ALLOW_STOP=1 bash "$E" run --curve "60:0 90:100" --interval 1 --sensors k10temp \
    --hwmon "$T/hwmon" --ectool "$T/stub/ectool" >/dev/null 2>&1 &
PID=$!
check "TEP_ALLOW_STOP=1 (the unit's form) lets it run" wait_for "fanduty 0"
stop_daemon

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
