#!/usr/bin/env bash
# install / set-curve / uninstall / config against temporary paths, with a
# recording systemctl and ectool. Nothing privileged is touched: TEP_SUDO=""
# drops the sudo prefix, and --unit/--bin point into a temp dir.
#
# What it is really protecting: the unit IS the configuration. An install that
# silently rewrote it would reset a curve somebody chose on purpose, and a
# set-curve that re-rendered the file would drop their other edits.
#
# Usage: tests/test-unit.sh             # uses ../thermal-exhaust-port.sh
#        TEP=/path/to/engine.sh tests/test-unit.sh
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E="${TEP:-${TEST_DIR}/../thermal-exhaust-port.sh}"
[[ -f "$E" ]] || { echo "engine not found at $E" >&2; exit 1; }
unset TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
UNIT="$T/tep.service"; BIN="$T/bin/tep.sh"; mkdir -p "$T/bin" "$T/stub"
CALLS="$T/calls"; : > "$CALLS"
ACTIVE="$T/active"
STATES="$T/states"; mkdir -p "$STATES"
UDIRS="$T/units"; mkdir -p "$UDIRS"
export CALLS ACTIVE STATES

# A fake hwmon so status and once have something to read.
H="$T/hwmon"; mkdir -p "$H/hwmon0"
printf 'k10temp\n' > "$H/hwmon0/name"; printf '71000\n' > "$H/hwmon0/temp1_input"

# Recording stubs. systemctl reports whatever state $ACTIVE says, so the
# "restart only when already running" branch can be exercised both ways.
# is-active/is-enabled answer from marker files in $STATES, so a test can put
# an arbitrary unit into any state the conflict scan cares about. Our own
# service keeps using $ACTIVE.
cat > "$T/stub/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$CALLS"
unit=""
for a in "$@"; do case "$a" in --*) ;; *.service) unit="$a"; break ;; esac; done
case "${1:-}" in
    is-active)
        if [[ -n "$unit" && -f "$STATES/$unit.active" ]]; then
            [[ "${2:-}" == --quiet ]] && exit 0; echo active; exit 0
        fi
        if [[ -n "$unit" && -f "$STATES/$unit.failed" ]]; then
            [[ "${2:-}" == --quiet ]] && exit 1; echo failed; exit 3
        fi
        # Our own service: $ACTIVE is the switch the tests flip.
        if [[ -f "$ACTIVE" && ( -z "$unit" || "$unit" == tep.service ) ]]; then
            [[ "${2:-}" == --quiet ]] && exit 0; echo active; exit 0
        fi
        [[ "${2:-}" == --quiet ]] && exit 1
        echo inactive; exit 3 ;;
    is-enabled)
        if [[ -n "$unit" && -f "$STATES/$unit.enabled" ]]; then
            [[ "${2:-}" == --quiet ]] && exit 0; echo enabled; exit 0
        fi
        [[ "${2:-}" == --quiet ]] && exit 1
        echo disabled; exit 1 ;;
    show)
        # FragmentPath: the scan prefers what systemd loaded over the grep hit.
        [[ -n "$unit" && -f "$STATES/$unit.frag" ]] && cat "$STATES/$unit.frag"
        exit 0 ;;
esac
exit 0
STUB
cat > "$T/stub/ectool" <<'STUB'
#!/usr/bin/env bash
printf 'ectool %s\n' "$*" >> "$CALLS"
[[ "${1:-}" == pwmgetfanrpm ]] && echo "Fan 0 RPM: 1234"
exit 0
STUB
chmod +x "$T/stub/systemctl" "$T/stub/ectool"

# TEP_SUDO="" is the whole reason this suite can run unprivileged.
Q() {
    local c="$1"; shift
    TEP_SUDO="" TEP_SYSTEMCTL="$T/stub/systemctl" bash "$E" "$c" \
        --unit "$UNIT" --bin "$BIN" --hwmon "$H" --ectool "$T/stub/ectool" \
        --unit-dirs "$UDIRS" "$@"
}

FAILS=0
check()  { local d="$1"; shift; if "$@"; then echo "   ok   - $d"; else echo "   FAIL - $d"; FAILS=$((FAILS + 1)); fi; }
nq()     { ! Q "$@" >/dev/null 2>&1; }
run()    { Q "$@" >/dev/null 2>&1; }
cfg()    { Q config 2>/dev/null | sed -n "s/^$1=//p"; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }
called() { grep -qF "$1" "$CALLS"; }
missing(){ ! grep -qF "$1" "$CALLS"; }
inunit() { grep -qF "$1" "$UNIT"; }
notunit(){ ! grep -qF "$1" "$UNIT"; }

echo "## 1. a dry run writes nothing"

run install --dry-run --curve "70:40"
check "no unit after a dry run"            absent "$UNIT"
check "no installed copy"                  absent "$BIN"
check "and no systemctl was called"        missing "systemctl daemon-reload"

echo "## 2. install writes the unit and enables the service"

: > "$CALLS"
run install --curve "70:40 80:100" --hyst 5 --sensors "k10temp"
check "the unit exists"                    exists "$UNIT"
check "the engine was copied to --bin"     exists "$BIN"
check "the installed copy is this engine"  cmp -s "$E" "$BIN"
check "daemon-reload was called"           called "systemctl daemon-reload"
check "the service was enabled"            called "systemctl enable"
check "ExecStart points at --bin"          inunit "ExecStart=${BIN} run"
check "the curve landed in the unit"       inunit 'Environment="TEP_CURVE=70:40 80:100"'
check "hyst landed in the unit"            inunit 'Environment=TEP_HYST=5'
# A value containing a space must be quoted or systemd reads only the first word.
check "a space-bearing value is quoted"    inunit 'Environment="TEP_SENSORS=k10temp"'
check "ExecStopPost hands the fans back"   inunit "ExecStopPost=$T/stub/ectool autofanctrl"
# The daemon reads these from its environment; without them the service looked
# for /usr/bin/ectool whatever install was told (Kamino item 184).
check "the --ectool path is in the unit"   inunit "Environment=\"TEP_ECTOOL=$T/stub/ectool\""
check "the --hwmon root is in the unit"    inunit "Environment=\"TEP_HWMON=$H\""
check "config reads them back from the unit" bash -c '
    out="$(TEP_SUDO="" TEP_SYSTEMCTL="$2/stub/systemctl" bash "$1" config --unit "$3" --unit-dirs "$2/units" 2>/dev/null)"
    grep -qxF "ectool=$2/stub/ectool" <<<"$out" && grep -qxF "hwmon=$4" <<<"$out"' _ "$E" "$T" "$UNIT" "$H"
check "a relative --ectool is refused by install" nq install --force --ectool stub/ectool
check "a --ectool with a space is refused"        nq install --force --ectool "/opt/fw tools/ectool"
check "a --hwmon with a % is refused"             nq install --force --hwmon "/sys/%n"
check "  and the unit is untouched"               inunit "Environment=\"TEP_ECTOOL=$T/stub/ectool\""
# --unit sets the file path; the unit NAME systemctl is told to enable and
# restart has to be that same file, not one derived from the script's name.
check "systemctl is told the unit file's own name" called "systemctl enable tep.service"

echo "## 3. config reports the unit, not the defaults"

check "config_source names the unit"       [ "$(cfg config_source)" = "$UNIT" ]
check "config reports the unit's curve"    [ "$(cfg curve)" = "70:40 80:100" ]
check "config reports the unit's hyst"     [ "$(cfg hyst)" = "5" ]
check "unit_exists is 1"                   [ "$(cfg unit_exists)" = "1" ]
check "bin_exists is 1"                    [ "$(cfg bin_exists)" = "1" ]
check "steps counts the unit's points"     [ "$(cfg steps)" = "2" ]
check "an explicit --curve overrides the unit" \
    [ "$(Q config --curve "60:20" 2>/dev/null | sed -n 's/^curve=//p')" = "60:20" ]
check "and config_source admits the override" \
    grep -q 'overrides' <<< "$(Q config --curve "60:20" 2>/dev/null)"

# A unit's values never went through flag parsing, so they are validated and
# read as decimal too: a hand-edited TEP_HYST=08 would otherwise break every
# step-down comparison the daemon makes.
cp "$UNIT" "$T/unit.bak"
printf 'Environment=TEP_HYST=08\n' >> "$UNIT"
check "a unit's zero-padded hyst is read as decimal" [ "$(cfg hyst)" = "8" ]
printf 'Environment=TEP_INTERVAL=600\n' >> "$UNIT"
check "a unit's out-of-range interval is refused"   nq config
cp "$T/unit.bak" "$UNIT"

echo "## 4. an existing unit is somebody's tuning"

# A line nothing in render_unit produces: if it survives, the file was edited
# rather than regenerated.
printf 'Environment=MARKER=keepme\n' >> "$UNIT"
run install --curve "99:10"
check "install keeps an existing unit"     inunit 'TEP_CURVE=70:40 80:100'
check "the hand-added line survives"       inunit 'MARKER=keepme'
check "but the engine copy is refreshed"   cmp -s "$E" "$BIN"
run install --force --curve "99:10"
check "--force rewrites the curve"         inunit 'Environment="TEP_CURVE=99:10"'
check "--force drops hand-added lines"     notunit 'MARKER=keepme'
before="$(cat "$UNIT")"
check "install refuses a falling-duty curve" nq install --force --curve "72:60 80:20"
check "install refuses a leading-0% curve"   nq install --force --curve "60:0 90:100"
check "  and the unit is untouched"        [ "$(cat "$UNIT")" = "$before" ]
run install --force --curve "60:0 90:100" --allow-stop
check "install --allow-stop writes the permission" inunit 'Environment=TEP_ALLOW_STOP=1'
run install --force --curve "99:10"
check "a plain install writes TEP_ALLOW_STOP=0"    inunit 'Environment=TEP_ALLOW_STOP=0'

echo "## 5. set-curve edits in place"

printf 'Environment=MARKER=keepme\n' >> "$UNIT"
: > "$CALLS"
run set-curve "60:30 70:60 80:100"
check "the curve is replaced"              inunit 'Environment="TEP_CURVE=60:30 70:60 80:100"'
check "exactly one CURVE line remains"     [ "$(grep -cF 'TEP_CURVE=' "$UNIT")" = "1" ]
check "other edits are preserved"          inunit 'MARKER=keepme'
check "daemon-reload follows a set-curve"  called "systemctl daemon-reload"
check "an inactive service is not restarted" missing "systemctl restart"

: > "$CALLS"; : > "$ACTIVE"      # now pretend the service is running
run set-curve "65:35"
check "a running service IS restarted"     called "systemctl restart"
rm -f "$ACTIVE"

# A rejected curve must leave the unit exactly as it was: validated before the
# file is touched, not after.
before="$(cat "$UNIT")"
check "a bad curve is refused"             nq set-curve "80:50 70:40"
check "and the unit is untouched"          [ "$(cat "$UNIT")" = "$before" ]
check "set-curve with no points is refused" nq set-curve

# A fan must never cool less as it gets hotter (Kamino item 183).
check "a falling-duty curve is refused"    nq set-curve "72:60 80:20"
check "  and the unit is untouched"        [ "$(cat "$UNIT")" = "$before" ]
check "a leading-0% curve is refused"      nq set-curve "60:0 90:100"
check "  and the unit is untouched"        [ "$(cat "$UNIT")" = "$before" ]
run set-curve "60:0 90:100" --allow-stop
check "--allow-stop lets it through"       inunit 'Environment="TEP_CURVE=60:0 90:100"'
check "  and records the permission in the unit" inunit 'Environment=TEP_ALLOW_STOP=1'
check "  config reports it"                [ "$(cfg allow_stop)" = "1" ]
run set-curve "60:30 90:100"
check "the next curve does not inherit it" inunit 'Environment=TEP_ALLOW_STOP=0'
check "  exactly one ALLOW_STOP line"      [ "$(grep -cF 'TEP_ALLOW_STOP=' "$UNIT")" = "1" ]

# A unit without the key (hand-written, or from before it existed): the line
# belongs in [Service]. Appended at the end of the file it lands under
# [Install], where systemd ignores it.
printf '[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n' > "$UNIT"
run set-curve "60:0 90:100" --allow-stop
svc_end="$(grep -n '^\[Install\]' "$UNIT" | cut -d: -f1)"
check "missing keys are added under [Service], not [Install]" bash -c '
    for k in TEP_CURVE TEP_ALLOW_STOP; do
        n="$(grep -n "$k=" "$1" | cut -d: -f1)"; [[ -n "$n" ]] && (( n < $2 )) || exit 1
    done' _ "$UNIT" "$svc_end"
# A unit whose curve stops the fans without the permission (a hand edit): the
# reports say the service will refuse it.
printf '[Service]\nEnvironment="TEP_CURVE=60:0 90:100"\n' > "$UNIT"
check "config warns about a unit's 0% curve" grep -q 'refuse it without --allow-stop' <<< "$(Q config 2>&1 >/dev/null)"
printf '%s\n' "$before" > "$UNIT"

echo "## 6. uninstall"

run uninstall --dry-run
check "a dry run removes nothing"          exists "$UNIT"
# Without a terminal, a destructive command must refuse rather than assume yes.
check "uninstall without --yes refuses (no tty)" nq uninstall
check "the unit survived the refusal"      exists "$UNIT"

: > "$CALLS"
run uninstall --yes
check "the unit is gone"                   absent "$UNIT"
check "the installed copy is gone"         absent "$BIN"
check "the service was disabled"           called "systemctl disable"
# The one thing that must happen whatever else failed: fans back to the EC.
check "the fans were handed back"          called "ectool autofanctrl"

echo "## 6b. a unit from before the TEP_ prefix is called out"

run uninstall --yes
printf '[Service]\nEnvironment="CURVE=11:22"\nExecStart=/bin/true\n' > "$UNIT"
out="$(Q status 2>&1)"
check "a bare CURVE= unit is flagged"      grep -q 'reads TEP_CURVE' <<< "$out"
check "  and it says how to fix it"        grep -q 'install --force' <<< "$out"
# Crucially it must NOT report the stale curve as if it were running.
check "  the stale curve is not reported as live" bash -c '! grep -q "11:22" <<<"$out"' 2>/dev/null \
    || [ -z "$(Q status 2>/dev/null | grep '11:22' || true)" ]
check "  config falls back to the defaults" [ "$(cfg curve)" = "72:35 78:60 84:85 88:100" ]
rm -f "$UNIT"

echo "## 7. the conflict scan"

# Two fan daemons both writing the EC's one duty register fight silently, and
# this firmware cannot be read back to detect it — so a warning before the
# second one is installed is all there is.
check "a clean host reports no conflict"   [ -z "$(Q conflicts 2>/dev/null)" ]
check "  and conflicts=0 in config"        [ "$(cfg conflicts)" = "0" ]

# A unit file that mentions ectool but is neither running nor enabled is just a
# file on disk, and must not be reported.
cat > "$UDIRS/rival.service" <<RIVAL
[Service]
ExecStart=/usr/local/bin/rival.sh
ExecStopPost=/usr/bin/ectool autofanctrl
RIVAL
check "an inert unit file is not a conflict" [ -z "$(Q conflicts 2>/dev/null)" ]

# Enabled-but-stopped is the case that matters: it is not fighting now, it will
# be after the next boot. The service this engine replaced sat in exactly that
# state.
: > "$STATES/rival.service.enabled"
out="$(Q conflicts 2>/dev/null)"
check "an enabled-but-stopped unit IS a conflict" grep -q '^rival.service' <<< "$out"
check "  and the state says it starts at boot"    grep -q 'enabled at boot' <<< "$out"
check "  and config counts it"                    [ "$(cfg conflicts)" = "1" ]

: > "$STATES/rival.service.active"
out="$(Q conflicts 2>/dev/null)"
check "an active unit is a conflict"              grep -q '^rival.service' <<< "$out"
check "  reported as active"                      grep -qF "$(printf 'rival.service\tactive')" <<< "$out"

# The reported path is the one systemd loaded, not whichever copy grep found.
printf '/etc/systemd/system/rival.service\n' > "$STATES/rival.service.frag"
check "the path comes from systemd, not the grep hit" \
    grep -qF '/etc/systemd/system/rival.service' <<< "$(Q conflicts 2>/dev/null)"
rm -f "$STATES/rival.service.frag"

# A unit that does not mention the EC tool at all is none of our business.
cat > "$UDIRS/unrelated.service" <<'OTHER'
[Service]
ExecStart=/usr/bin/true
OTHER
: > "$STATES/unrelated.service.active"
check "an unrelated active unit is ignored" \
    [ -z "$(Q conflicts 2>/dev/null | grep 'unrelated' || true)" ]

# install must warn rather than refuse: the decision is the operator's, and a
# heuristic has no business blocking one.
rm -f "$UNIT"
out="$(Q install --curve "70:40" 2>&1)"
check "install warns about the conflict"   grep -q 'rival.service' <<< "$out"
check "  names the EC tool"                grep -q 'ectool' <<< "$out"
check "  and still installs"               exists "$UNIT"

out="$(Q status 2>/dev/null)"
check "status reports the conflict"        grep -q 'conflict:' <<< "$out"
check "  and names the unit"               grep -q 'rival.service' <<< "$out"

# Our own service must never be reported as its own rival.
printf '[Service]\nExecStopPost=/usr/bin/ectool autofanctrl\n' > "$UDIRS/tep.service"
: > "$STATES/tep.service.enabled"
check "the engine's own service is not a conflict" \
    [ -z "$(Q conflicts 2>/dev/null | grep '^tep.service' || true)" ]
rm -f "$UDIRS/tep.service" "$STATES/tep.service.enabled" "$UDIRS/rival.service" \
      "$UDIRS/unrelated.service" "$STATES"/*.active "$STATES"/*.enabled "$STATES"/*.failed 2>/dev/null
Q uninstall --yes >/dev/null 2>&1

echo "## 8. with nothing installed"

check "config falls back to its defaults"  [ "$(cfg curve)" = "72:35 78:60 84:85 88:100" ]
check "config_source says defaults"        [ "$(cfg config_source)" = "defaults" ]
check "unit_exists is 0"                   [ "$(cfg unit_exists)" = "0" ]
check "the curve is still parsed"          [ "$(cfg steps)" = "4" ]
check "set-curve needs an installed unit"  nq set-curve "70:40"
check "status runs with no service"        run status
# is-active prints "inactive" AND exits non-zero, which an `|| echo` fallback
# turns into two lines on one field.
check "  and reports the state on one line" \
    [ "$(Q status 2>/dev/null | grep -c '^service :')" = "1" ]
check "  naming the state it was given"     grep -q '^service : inactive$' <<< "$(Q status 2>/dev/null)"

echo
if (( FAILS )); then echo "${FAILS} check(s) failed"; exit 1; fi
echo "all checks passed"
