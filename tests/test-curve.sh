#!/usr/bin/env bash
# Curve parsing, validation and the hysteresis walk — all through `simulate`,
# which touches no hardware, so this runs anywhere.
#
# Usage: tests/test-curve.sh            # uses ../thermal-exhaust-port.sh
#        TEP=/path/to/engine.sh tests/test-curve.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="${TEP:-${TEST_DIR}/../thermal-exhaust-port.sh}"
[[ -f "$E" ]] || { echo "engine not found at $E" >&2; exit 1; }

# A stray TEP_* in the caller's environment would override the flags under
# test and quietly invalidate every assertion here.
unset TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS TEP_UNIT TEP_BIN

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# No unit anywhere: these assertions are about the given curve, not an
# installed one.
# The command comes first, so Q takes it as $1 and appends the flags after it.
Q() { local c="$1"; shift; bash "$E" "$c" --unit "$T/none.service" "$@"; }

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
fails()  { ! Q "$@" >/dev/null 2>&1; }
silent() { Q "$@" >/dev/null 2>&1; }

echo "## 1. the walk up and back down"

out="$(Q simulate --curve "72:35 78:60 84:85 88:100" 71 72 79 85 89 84 79 73 67 2>/dev/null)"
want=$'71\tauto (EC)\n72\t35%\n79\t60%\n85\t85%\n89\t100%\n84\t100%\n79\t60%\n73\t35%\n67\tauto (EC)'
check "rising then falling matches the expected steps" [ "$out" = "$want" ]

# The point of hysteresis: 84 on the way down holds 100% (84 >= 88-4), and the
# step is only left once the temperature clears it by HYST.
check "a step is held until HYST below it" \
    [ "$(Q simulate --curve "72:35 78:60 84:85 88:100" 89 84 2>/dev/null | tail -1)" = "$(printf '84\t100%%')" ]
check "and is left one degree further down" \
    [ "$(Q simulate --curve "72:35 78:60 84:85 88:100" 89 83 2>/dev/null | tail -1)" = "$(printf '83\t85%%')" ]

# A single reading that jumps several steps must land on the right one, not
# creep up one step per tick.
check "one reading can climb several steps at once" \
    [ "$(Q simulate --curve "72:35 78:60 84:85 88:100" 95 2>/dev/null)" = "$(printf '95\t100%%')" ]

check "hyst 0 steps down as soon as the threshold is crossed" \
    [ "$(Q simulate --curve "70:40 80:100" --hyst 0 85 79 2>/dev/null | tail -1)" = "$(printf '79\t40%%')" ]

check "below the first point the EC gets control back" \
    [ "$(Q simulate --curve "70:40" 60 2>/dev/null)" = "$(printf '60\tauto (EC)')" ]
check "a single-point curve is a valid curve" \
    [ "$(Q simulate --curve "70:40" 75 2>/dev/null)" = "$(printf '75\t40%%')" ]

# Sub-zero readings are not hypothetical: a sensor that has not initialised can
# report a negative value, and it must not be treated as a parse error.
check "a negative temperature is read, not rejected" \
    [ "$(Q simulate --curve "70:40" -- -5 2>/dev/null)" = "$(printf -- '-5\tauto (EC)')" ]

echo "## 2. the curve is validated before anything uses it"

check "a non-ascending curve is rejected"      fails simulate --curve "80:50 70:40" 75
check "equal temperatures are rejected"        fails simulate --curve "70:40 70:50" 75
check "a duty above 100 is rejected"           fails simulate --curve "70:140" 75
check "a malformed point is rejected"          fails simulate --curve "70-40" 75
check "a point missing its duty is rejected"   fails simulate --curve "70:" 75
check "an empty curve is rejected"             fails simulate --curve "" 75
check "a non-numeric temperature is rejected"  fails simulate --curve "70:40" abc
check "simulate with no temperatures is rejected" fails simulate --curve "70:40"

# The message has to name the offending point: "bad curve" alone leaves you
# bisecting a twelve-point curve by hand.
err="$(Q simulate --curve "70:40 65:50" 75 2>&1 >/dev/null)"
check "the rejection names the offending point" grep -q '65:50' <<< "$err"

echo "## 3. flags and commands"

check "a bad --hyst is rejected"      fails simulate --curve "70:40" --hyst x 75
check "a bad --interval is rejected"  fails simulate --curve "70:40" --interval x 75
check "--interval 0 is rejected"      fails simulate --curve "70:40" --interval 0 75
check "an unknown flag is rejected"   fails simulate --curve "70:40" --nope 75
check "an unknown command is rejected" fails frobnicate
check "--help exits 0"                silent --help
check "version prints the name"       grep -q 'thermal-exhaust-port' <<< "$(Q version 2>/dev/null)"

# simulate is the "what if" command: it must answer about the curve it was
# given, never about an installed unit. Checked explicitly because the opposite
# choice was made for status/once/curve, and the two are easy to confuse.
printf '[Service]\nEnvironment="TEP_CURVE=10:99"\n' > "$T/u.service"
check "simulate ignores the installed unit" \
    [ "$(bash "$E" simulate --unit "$T/u.service" --curve "70:40" 75 2>/dev/null)" = "$(printf '75\t40%%')" ]
check "curve reads the installed unit" \
    [ "$(bash "$E" curve --unit "$T/u.service" 2>/dev/null)" = "$(printf '10\t99')" ]

echo "## 4. a fan never cools less as it gets hotter"

# Before: "72:60 80:20" was accepted and gave 20% at 85C, and a curve starting
# at 0% passed without a word. Same rules as carbonite (its Kamino item 112).
check "a falling duty is refused"               fails simulate --curve "72:60 80:20" 85
err="$(Q simulate --curve "72:60 80:20" 85 2>&1 >/dev/null)"
check "  naming the point and the rule"         grep -q "'80:20' is 20% after 60%" <<< "$err"
check "a falling duty anywhere is refused"      fails simulate --curve "60:30 70:50 80:45 90:100" 85
check "a hot 0% step is refused"                fails simulate --curve "60:40 90:0" 95
check "a flat duty is fine"                     silent simulate --curve "60:50 70:50" 75

# 0% can then only be the coolest steps. It still stops fans that the EC's own
# control keeps turning below the first point, so simulate says so.
out="$(Q simulate --curve "60:0 90:100" 70 95 2>"$T/err")"
check "a leading 0% step is simulated"          [ "$out" = "$(printf '70\t0%%\n95\t100%%')" ]
check "  with a warning naming where it stops"  grep -q '0% from 60C until 90C' "$T/err"
check "  and that it is refused without --allow-stop" grep -q 'allow-stop' "$T/err"
Q simulate --curve "70:0" 75 >/dev/null 2>"$T/err"
check "an all-0% curve warns 'from 70C up'"     grep -q '0% from 70C up' "$T/err"
Q simulate --curve "60:0 90:100" --allow-stop 70 >/dev/null 2>"$T/err"
check "--allow-stop silences the warning"       [ ! -s "$T/err" ]
Q simulate --curve "72:35 78:60 84:85 88:100" 70 >/dev/null 2>"$T/err"
check "a curve with no 0% warns nothing"        [ ! -s "$T/err" ]

echo "## 5. numbers are decimal, whatever their leading zeros"

# Bash arithmetic reads a leading zero as octal. Before: 072 was a step at 58C,
# 090 was refused with a misleading "must ascend", and --hyst 08 passed the
# check and then broke every step-down comparison — the fan never came down.
check "072:35 is a step at 72C, not 58C" \
    [ "$(Q simulate --curve "072:35" 60 72 2>/dev/null)" = "$(printf '60\tauto (EC)\n72\t35%%')" ]
check "08 and 090 are valid temperatures" \
    [ "$(Q simulate --curve "08:10 090:100" 9 90 2>/dev/null)" = "$(printf '9\t10%%\n90\t100%%')" ]
check "a zero-padded duty is decimal" \
    [ "$(Q simulate --curve "70:080" 75 2>/dev/null)" = "$(printf '75\t80%%')" ]
check "--hyst 08 steps down 8 below the step" \
    [ "$(Q simulate --curve "70:40 80:100" --hyst 08 85 72 71 2>/dev/null)" = "$(printf '85\t100%%\n72\t100%%\n71\t40%%')" ]
check "a zero-padded simulate temperature is decimal" \
    [ "$(Q simulate --curve "70:40" 071 2>/dev/null)" = "$(printf '71\t40%%')" ]
check "--interval 09 is accepted"      silent simulate --curve "70:40" --interval 09 75

echo "## 6. --interval has a ceiling"

check "--interval 60 is accepted"      silent simulate --curve "70:40" --interval 60 75
check "--interval 61 is refused"       fails simulate --curve "70:40" --interval 61 75
err="$(Q simulate --curve "70:40" --interval 600 75 2>&1 >/dev/null)"
check "  and the refusal states the ceiling" grep -q 'at most 60 seconds' <<< "$err"
check "a 20-digit number is refused, not overflowed" fails simulate --curve "70:40" --hyst 99999999999999999999 75

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
