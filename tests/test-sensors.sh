#!/usr/bin/env bash
# Sensor resolution against a fake sysfs hwmon tree — no real hardware, so this
# runs on a CI runner with no EC and no cros_ec.
#
# What it is really protecting: hwmon indices are NOT stable across reboots. A
# driver loading in a different order renumbers them, so resolution has to be by
# name. Hardcoding hwmon6 reads the wrong chip after a kernel update, and a fan
# curve driven by the wrong chip is worse than no fan curve.
#
# Usage: tests/test-sensors.sh          # uses ../thermal-exhaust-port.sh
#        TEP=/path/to/engine.sh tests/test-sensors.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="${TEP:-${TEST_DIR}/../thermal-exhaust-port.sh}"
[[ -f "$E" ]] || { echo "engine not found at $E" >&2; exit 1; }
unset TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS TEP_UNIT TEP_BIN

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/hwmon"

FAILS=0
check() { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }

# chip <index> <name> <millidegrees...>
chip() {
    local d="$H/hwmon$1" n="$2" i=1; shift 2
    mkdir -p "$d"; printf '%s\n' "$n" > "$d/name"
    for v in "$@"; do printf '%s\n' "$v" > "$d/temp${i}_input"; i=$(( i + 1 )); done
}

Q() { local c="$1"; shift; bash "$E" "$c" --hwmon "$H" --unit "$T/none.service" "$@"; }
# `check "desc" ! Q ...` would try to run `!` as a command, so negation gets a
# helper of its own.
nq() { ! Q "$@" >/dev/null 2>&1; }
nq_root() { local r="$1"; shift; ! bash "$E" "$@" --hwmon "$r" --unit "$T/none.service" >/dev/null 2>&1; }

echo "## 1. the hottest WATCHED sensor wins"

# The decoy is the hottest chip on the box and must be ignored: a curve that
# followed every sensor would run the fans off a NIC or a battery gauge.
chip 0 decoy   95000
chip 1 k10temp 71000
chip 2 amdgpu  62000 65000

check "hottest of the watched set, not of the box" \
    [ "$(Q once --sensors "k10temp amdgpu" 2>/dev/null | cut -f1)" = "71C" ]
check "the hottest input WITHIN a chip is used" \
    [ "$(Q once --sensors "amdgpu" 2>/dev/null | cut -f1)" = "65C" ]
check "an unwatched chip is ignored even when hottest" \
    [ "$(Q once --sensors "amdgpu" 2>/dev/null | cut -f1)" != "95C" ]

echo "## 2. resolution follows the NAME, not the index"

# Swap the names between hwmon0 and hwmon1 — exactly what a reboot can do — and
# the answer must follow k10temp to its new index.
printf 'k10temp\n' > "$H/hwmon0/name"
printf 'decoy\n'   > "$H/hwmon1/name"
check "renumbered chips still resolve by name" \
    [ "$(Q once --sensors "k10temp amdgpu" 2>/dev/null | cut -f1)" = "95C" ]
printf 'decoy\n'   > "$H/hwmon0/name"
printf 'k10temp\n' > "$H/hwmon1/name"

echo "## 3. unreadable sensors are not a cold machine"

# The dangerous failure: a missing sensor read as 0C would drop the curve to
# "auto (EC)" and hand a hot machine back to the lazy stock curve. It has to be
# an error instead.
check "no matching sensor is an error, not 0C"      nq once --sensors "nosuch"
check "the error names what it looked for"          grep -q 'nosuch' <<< "$(Q once --sensors nosuch 2>&1 >/dev/null)"
check "an empty hwmon tree is an error"             nq_root "$T/empty" once

# A chip whose name is readable but which exposes no temperature at all (a
# power supply, a USB-C port) must not count as a reading.
chip 3 nothermal
check "a chip with no temp input yields no reading" nq once --sensors "nothermal"
check "a garbage temp value is skipped" \
    [ "$(printf 'garbage\n' > "$H/hwmon1/temp1_input"; Q once --sensors "k10temp amdgpu" 2>/dev/null | cut -f1)" = "65C" ]
printf '71000\n' > "$H/hwmon1/temp1_input"

echo "## 4. sensors lists everything, flagging what is watched"

out="$(Q sensors --sensors "k10temp amdgpu" 2>/dev/null)"
check "every chip is listed, watched or not"  [ "$(wc -l <<< "$out")" -eq 4 ]
check "a watched chip is flagged 1"           grep -qxF "$(printf 'k10temp\t71\t1')" <<< "$out"
check "an unwatched chip is flagged 0"        grep -qxF "$(printf 'decoy\t95\t0')" <<< "$out"
check "a chip with no temp reads as -"        grep -qxF "$(printf 'nothermal\t-\t0')" <<< "$out"
# The front-end builds its picker from this, so the temperature column has to
# be the chip's hottest input, not its first.
check "the listed temperature is the chip's hottest input" grep -qxF "$(printf 'amdgpu\t65\t1')" <<< "$out"

echo "## 5. once reports a cold start, and says so"

# Hysteresis means a running service can hold a higher step than a cold start
# would pick. 'once' has to be labelled or it reads as the live duty.
check "once is labelled cold-start" \
    [ "$(Q once --sensors k10temp --curve "70:40 80:100" 2>/dev/null | cut -f3)" = "cold-start" ]
check "once applies the curve to the reading" \
    [ "$(Q once --sensors k10temp --curve "70:40 80:100" 2>/dev/null | cut -f2)" = "40%" ]
check "a reading below the first point hands back to the EC" \
    [ "$(Q once --sensors k10temp --curve "90:40" 2>/dev/null | cut -f2)" = "auto (EC)" ]

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
