#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# thermal-exhaust-port.sh — a stepped fan curve for machines whose fans are
# behind an embedded controller rather than hwmon PWM (gum-free, flag-driven
# CLI engine).
#
# The case it was built for: a Framework Desktop (Ryzen AI Max 300) on Bazzite.
# That board exposes no `pwm*` nodes at all — `cros_ec` offers read-only RPM and
# temperatures, and `fan1_target` is not writable — so every hwmon-based fan
# tool (fan-control, fancontrol, coolercontrol) has nothing to drive. Fan
# control goes through the EC, via `ectool`. The stock EC curve is lazy: it lets
# the SoC drift into the 80s before it does much.
#
# So this is not a veneer over ectool. ectool sets one duty cycle and forgets;
# the curve, the hysteresis, the sensor resolution and the daemon are here.
#
#   run        the loop: read the hottest watched sensor, pick a duty, apply it
#   status     what the installed service is actually doing
#   simulate   walk a curve over temperatures, touching no hardware
#   install    write the systemd unit and enable it
#
# Prompt-free by default: commands and flags only, so it drops into a systemd
# unit, a provisioning script or a TUI alike. `uninstall` is the one exception,
# and only because it removes files — an unattended run passes --yes to say so
# out loud. The interactive experience lives in a separate front-end
# (scomp-link) that drives this engine with flags — the holonet-sync pattern.
#
# WHERE THE CONFIGURATION LIVES, and why it is not ~/.config:
# the daemon runs as root under systemd, so a per-user XDG config would be read
# by this CLI and ignored by the service — two sources of truth that disagree
# exactly when it matters. The systemd unit's Environment= lines ARE the
# config; `config` reads them back and `set-curve` rewrites them, so the
# front-end never has to parse the unit itself.
#
# Requirements: bash >= 4, ectool (from the host's firmware tooling), systemd.
# Installs nothing itself — a missing ectool is reported, never installed,
# because there is nobody here to ask. Run --help for the command list.
# -----------------------------------------------------------------------------

# Arrays and nameref handling are load-bearing; macOS bash 3.2 would fail later
# and far less obviously. (This engine is Linux-only anyway — systemd and
# ectool — but the check belongs with the others for a clear message.)
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    echo "[error] bash 4+ required (you have ${BASH_VERSION})." >&2
    exit 1
fi

# NOTE: -e is deliberately absent. `(( s-- ))` evaluating to 0 returns
# non-zero, and errexit would kill the daemon loop mid-step.
set -uo pipefail
shopt -s nullglob

SCRIPT_NAME="thermal-exhaust-port"
VERSION="1.0.0"

# ---- gum-free status output (stderr; stdout stays clean for data) -----------
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A systemd journal has its own clock, so a timestamp there is noise; a mail
# spool or a redirected log file has none. Colour only for a real terminal.
if [[ -t 2 ]]; then
    C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
    _pfx() { printf ''; }
elif [[ -n "${JOURNAL_STREAM:-}" || -n "${INVOCATION_ID:-}" ]]; then
    C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""
    _pfx() { printf ''; }
else
    C_G=""; C_Y=""; C_R=""; C_C=""; C_N=""
    _pfx() { printf '%s ' "$(_ts)"; }
fi

VERBOSE=0
info()       { printf '%s%s[info]%s  %s\n'  "$(_pfx)" "$C_C" "$C_N" "$*" >&2; }
success()    { printf '%s%s[ok]%s    %s\n'  "$(_pfx)" "$C_G" "$C_N" "$*" >&2; }
warn()       { printf '%s%s[warn]%s  %s\n'  "$(_pfx)" "$C_Y" "$C_N" "$*" >&2; }
error()      { printf '%s%s[error]%s %s\n'  "$(_pfx)" "$C_R" "$C_N" "$*" >&2; }
error_exit() { error "$*"; exit 1; }
dbg()        { if (( VERBOSE )); then printf '%s[debug] %s\n' "$(_pfx)" "$*" >&2; fi; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

# "degC:duty%" points, ascending. Below the first point the EC gets control back.
CURVE="${TEP_CURVE:-72:35 78:60 84:85 88:100}"
HYST="${TEP_HYST:-4}"             # degC to fall below a step before dropping to it
INTERVAL="${TEP_INTERVAL:-3}"     # seconds between temperature checks
# The cap on --interval: a loaded SoC climbs tens of degrees in a few seconds,
# and a loop that looks less often than once a minute is not controlling it.
MAX_INTERVAL=60
REASSERT="${TEP_REASSERT:-60}"    # seconds; re-send the current state to the EC
# Failed reads in a row before the daemon stops holding the last duty and hands
# the fans back to the EC: long enough to ride out a driver rebinding, short
# enough that a blind loop does not hold a low duty on a machine heating up.
BLIND_READS=3
SENSORS="${TEP_SENSORS:-k10temp amdgpu}"  # hwmon names to watch, hottest wins
# A step at 0% stops the fans while the machine is hotter than where the EC's
# own control keeps them turning; refused unless this says it is meant.
ALLOW_STOP="${TEP_ALLOW_STOP:-0}"

ECTOOL="${TEP_ECTOOL:-/usr/bin/ectool}"
HWMON_ROOT="${TEP_HWMON:-/sys/class/hwmon}"
BIN="${TEP_BIN:-/usr/local/bin/${SCRIPT_NAME}.sh}"
UNIT="${TEP_UNIT:-/etc/systemd/system/${SCRIPT_NAME}.service}"
# Always the unit file's own name. Derived rather than fixed from SCRIPT_NAME,
# because --unit changes the path: with a hardcoded name, pointing --unit
# somewhere else wrote one file and then ran systemctl against a different unit
# entirely — enabling, restarting and reporting on the wrong service.
SERVICE="${UNIT##*/}"
SYSTEMCTL="${TEP_SYSTEMCTL:-systemctl}"
# Where unit files are looked for, by the conflict scan. Overridable so the scan
# can be tested against a temp directory instead of the host's real units.
UNIT_DIRS="${TEP_UNIT_DIRS:-/etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system}"

FORCE=0
DRY_RUN=0
ASSUME_YES=0

# Which knobs were given explicitly (flag or TEP_* variable)? An explicit value
# always wins over what the installed unit says; see load_unit_config.
declare -A FROM_ENV=()
for _k in TEP_CURVE TEP_HYST TEP_INTERVAL TEP_REASSERT TEP_SENSORS TEP_ALLOW_STOP TEP_ECTOOL TEP_HWMON; do
    [[ -n "${!_k+set}" ]] && FROM_ENV["${_k#TEP_}"]=1
done
unset _k

# Root writes the unit and talks to the EC directly; anyone else goes through
# sudo. Overridable so the install path can be tested without privilege.
if [[ -n "${TEP_SUDO+set}" ]]; then
    SUDO="$TEP_SUDO"
elif [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

usage() {
    cat >&2 <<EOF
${SCRIPT_NAME} ${VERSION} — a stepped fan curve for EC-controlled fans (no hwmon PWM)

USAGE
  ${SCRIPT_NAME}.sh <command> [args] [flags]

COMMANDS
  run                      the daemon loop; what the systemd unit calls
  status                   service state, resolved config, temperature, fan RPM (stdout)
  once                     the hottest watched sensor and the duty the curve picks (stdout)
  simulate T...            walk the curve over temperatures, change nothing (stdout)
  curve                    print the resolved curve as TSV: degC<TAB>duty (stdout)
  sensors                  print every hwmon sensor as TSV: name<TAB>degC<TAB>watched(0|1) (stdout)
  fans                     print fan RPM as TSV: index<TAB>rpm (stdout)
  install                  write the systemd unit and enable it (keeps an existing unit)
  uninstall                remove the unit and the installed copy, hand the fans back
  set-curve POINTS         rewrite the installed unit's curve and restart the service
  conflicts                other services that drive ectool, as TSV: unit<TAB>state<TAB>unit-file (stdout)
  config                   print the resolved config as key=value (stdout)
  version                  print version

FLAGS
  --curve POINTS           "degC:duty%" points, ascending (default: ${CURVE})
  --hyst N                 degC to fall below a step before dropping to it (default: ${HYST})
  --interval N             seconds between temperature checks, 1-${MAX_INTERVAL} (default: ${INTERVAL})
  --reassert N             seconds; re-send the current state to the EC (default: ${REASSERT})
  --sensors "NAME..."      hwmon names to watch, hottest wins (default: ${SENSORS})
  --allow-stop             let a curve start with 0% steps (fans stopped); without
                           it run, install and set-curve refuse such a curve
  --ectool PATH            ectool binary (default: ${ECTOOL})
  --hwmon DIR              sysfs hwmon root (default: ${HWMON_ROOT})
  --unit-dirs "DIR..."     where the conflict scan looks for unit files
  --bin PATH               where install puts this script (default: ${BIN})
  --unit PATH              systemd unit path (default: ${UNIT})
  --force                  install: overwrite an existing unit instead of keeping it
  --dry-run                install, uninstall, set-curve: report, write nothing
  -y, --yes                uninstall: do not ask (required when there is no terminal)
  -v, --verbose            debug logging
  -h, --help

THE CURVE
  Each "degC:duty%" point is a step. The duty applied is the highest step whose
  temperature the hottest watched sensor has reached. Below the first point the
  EC's own control is handed back (ectool autofanctrl).

  A fan must never cool less as it gets hotter, so duties may not fall from one
  step to the next ("72:60 80:20" is refused), and 0% — fans stopped — can only
  be the coolest steps. Even there it stops fans the EC would keep turning, so
  run, install and set-curve refuse it without --allow-stop; simulate warns.

  Hysteresis is one-sided: a step is entered at its temperature but only left
  once the temperature falls HYST degrees below it, so a machine hovering on a
  threshold does not oscillate. 'once' reports the duty for a COLD START and can
  legitimately differ from a running service, which is holding a higher step on
  the way down; 'status' prints the service's own journal lines for the real
  answer.

CONFIGURATION
  The systemd unit's Environment= lines are the configuration. The daemon runs
  as root under systemd, so a per-user config in ~/.config would be read by this
  CLI and ignored by the service. 'status', 'once' and 'config' read the unit;
  'set-curve' rewrites it. An explicit flag or TEP_* variable overrides it.
  'simulate' deliberately ignores the unit — it is the "what if" command.

  Drop-ins count, as systemd applies them (<unit>.d/*.conf and <dir>/<unit>.d/
  in each unit directory; last assignment wins). 'set-curve' refuses when a
  drop-in sets TEP_CURVE or TEP_ALLOW_STOP, and names it: that is the file to
  edit. EnvironmentFile= is not read.

  Nothing is installed for you: ectool comes from the host's firmware tooling
  (on Bazzite it is already there), and a missing one is reported.

TWO DAEMONS, ONE REGISTER
  The EC has a single fan-duty register and no record of who wrote it, and this
  firmware answers pwmgetduty with INVALID_COMMAND — so a duty set by something
  else cannot be read back, detected or attributed. Last write wins.

  What mitigates it: --reassert re-sends the current step every N seconds, so a
  foreign write is overridden back within that window. Lower it if something on
  the machine is known to fight.

  What warns about it: 'conflicts' (and install, and status) list services whose
  unit file mentions the EC tool — active ones AND enabled-but-stopped ones,
  since the latter fight after the next boot. A heuristic: a daemon that calls
  ectool only from inside a script names it nowhere in its unit, so it will not
  appear.

Exit status: 0 on success, 1 otherwise. Logs go to stderr, data to stdout.
EOF
}

# -----------------------------------------------------------------------------
# Curve
# -----------------------------------------------------------------------------

# Numbers are read as decimal, always. Bash arithmetic takes a leading zero as
# octal: "072:35" became a step at 58C, "090" a misleading "must ascend", and
# --hyst 08 passed the regex and then broke every step-down comparison, so the
# fan never stepped down. Six digits is far past any real value and keeps a
# typo from overflowing the arithmetic.
_dec() { printf '%d' "$(( 10#$1 ))"; }

CT=() CD=()
parse_curve() {
    local pt t d last=-1 lastd=0
    CT=(); CD=()
    for pt in $CURVE; do
        [[ "$pt" =~ ^([0-9]{1,6}):([0-9]{1,6})$ ]] \
            || error_exit "bad curve point '${pt}' — want degC:duty%, e.g. 72:35"
        t="$(_dec "${BASH_REMATCH[1]}")"; d="$(_dec "${BASH_REMATCH[2]}")"
        (( d <= 100 )) \
            || error_exit "duty out of range in '${pt}' — 0-100"
        (( t > last )) \
            || error_exit "curve must ascend by temperature: '${pt}' follows ${last}C"
        # The fan must never cool less as it gets hotter. Non-falling duties also
        # confine 0% to the leading steps; _check_stop deals with those.
        (( d >= lastd )) \
            || error_exit "duty must not fall as it gets hotter: '${pt}' is ${d}% after ${lastd}%"
        last="$t"; lastd="$d"
        CT+=("$t")
        CD+=("$d")
    done
    (( ${#CT[@]} )) || error_exit "empty curve"
}

# _check_stop refuse|warn — a curve whose first steps are 0% stops the fans
# from the first point up, where below it the EC's own control keeps them
# turning: hotter, and cooled less. Refused for anything that applies a curve
# unless --allow-stop (TEP_ALLOW_STOP=1) says the fans may stop; reports warn.
_check_stop() {
    local i from to="" where
    (( ${#CD[@]} )) && (( CD[0] == 0 )) || return 0
    from="${CT[0]}"
    for (( i = 1; i < ${#CD[@]}; i++ )); do
        (( CD[i] == 0 )) || { to="${CT[i]}"; break; }
    done
    where="from ${from}C ${to:+until ${to}C}${to:-up}"
    (( ALLOW_STOP )) && { dbg "0% ${where} allowed by --allow-stop"; return 0; }
    if [[ "$1" == refuse ]]; then
        error_exit "the curve forces 0% ${where}, which STOPS the fans there — below ${from}C the EC's own control keeps them turning. Raise those steps, or pass --allow-stop if the fans may stop."
    fi
    warn "this curve forces 0% ${where}, which stops the fans there; run, install and set-curve refuse it without --allow-stop"
}

# decide TEMP CURRENT_STEP — echoes the new step. -1 means "let the EC decide".
#
# Climb first, then fall: a single reading that jumps several steps lands on the
# right one, and the fall is gated on HYST so a hovering temperature does not
# flap between two steps.
decide() {
    local t="$1" s="$2"
    while (( s + 1 < ${#CT[@]} )) && (( t >= CT[s+1] )); do (( s++ )); done
    while (( s >= 0 )) && (( t < CT[s] - HYST )); do (( s-- )); done
    printf '%s\n' "$s"
}

label() { if (( $1 < 0 )); then printf 'auto (EC)'; else printf '%s%%' "${CD[$1]}"; fi; }

# -----------------------------------------------------------------------------
# Sensors
# -----------------------------------------------------------------------------

# hwmon indices are not stable across reboots — a driver loading in a different
# order renumbers them — so sensors are resolved by name on every read. A
# hardcoded hwmon6 silently starts reading the wrong chip after a kernel update.
#
# _scan sets HOT to the hottest watched sensor in whole degrees, or "" (and
# returns 1) when none could be read; FOUND to the watched names that gave a
# reading, so the daemon can say when a chip drops out. "" is not 0: a failed
# read must never look like a cold machine, because the curve would hand the
# fans back to the EC on the strength of it.
HOT="" FOUND=""
_scan() {
    local hi="" want d f v got
    FOUND=""
    for want in $SENSORS; do
        for d in "$HWMON_ROOT"/hwmon*; do
            [[ -r "$d/name" ]] || continue
            [[ "$(<"$d/name")" == "$want" ]] || continue
            got=0
            for f in "$d"/temp*_input; do
                [[ -r "$f" ]] || continue
                v="$(<"$f")" || continue
                [[ "$v" =~ ^(-?)([0-9]{1,9})$ ]] || continue
                v="${BASH_REMATCH[1]}$(_dec "${BASH_REMATCH[2]}")"
                got=1
                if [[ -z "$hi" ]] || (( v > hi )); then hi="$v"; fi
            done
            (( got )) && FOUND+="${FOUND:+ }${want}"
            break
        done
    done
    HOT=""
    [[ -n "$hi" ]] || return 1
    HOT="$(( hi / 1000 ))"
}

hottest() { _scan || return 1; printf '%s\n' "$HOT"; }

# -----------------------------------------------------------------------------
# EC
# -----------------------------------------------------------------------------

_ec() {
    if [[ -n "$SUDO" ]]; then $SUDO "$ECTOOL" "$@"; else "$ECTOOL" "$@"; fi
}

# Read-only EC queries, non-interactively. A plain `sudo` here authenticates:
# that cost `status` eight seconds for a fan reading on a host with no cached
# credential, and in a context with no way to answer it would simply hang. A
# report is not worth a password prompt — if the credential is not already
# there, say so and move on. Writes (install, uninstall, the daemon's own
# apply) still use _ec, where a prompt is the right behaviour.
_ec_ro() {
    if [[ -n "$SUDO" ]]; then $SUDO -n "$ECTOOL" "$@" 2>/dev/null; else "$ECTOOL" "$@"; fi
}

apply() {
    if (( $1 < 0 )); then
        _ec autofanctrl >/dev/null
    else
        _ec fanduty "${CD[$1]}" >/dev/null
    fi
}

# -----------------------------------------------------------------------------
# Unit as configuration
# -----------------------------------------------------------------------------

# The files systemd reads for this unit, in the order it applies them: the
# unit itself, then its drop-ins — <unit>.d/ beside it, and <dir>/<name>.d/ in
# each unit directory. A drop-in name in an earlier directory masks the same
# name in a later one (/etc over /run over /usr/lib), and drop-ins apply sorted
# by file name across all directories. `systemctl edit` writes one of these,
# and before, status, config and set-curve never looked: they reported a curve
# a drop-in had replaced, and set-curve rewrote a line that no longer counted.
_unit_files() {
    [[ -r "$UNIT" ]] || return 0
    printf '%s\n' "$UNIT"
    local d f b
    local -a dirs=("${UNIT}.d")
    local -A by_name=()
    for d in $UNIT_DIRS; do dirs+=("${d}/${SERVICE}.d"); done
    for d in "${dirs[@]}"; do
        for f in "$d"/*.conf; do
            [[ -r "$f" ]] || continue
            b="${f##*/}"
            [[ -n "${by_name[$b]+set}" ]] || by_name[$b]="$f"
        done
    done
    (( ${#by_name[@]} )) || return 0
    while IFS= read -r b; do
        printf '%s\n' "${by_name[$b]}"
    done < <(printf '%s\n' "${!by_name[@]}" | LC_ALL=C sort)
}

# _env_assignments VALUE — the assignments in one Environment= value, one per
# line, split and unquoted as systemd does: words on whitespace, "..." and
# '...' quote, a backslash takes the next character literally. One line can
# carry several (Environment="A=1" "B=2").
_env_assignments() {
    local s="$1" w="" q="" c i have=0
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        if [[ "$c" == '\' ]] && (( i + 1 < ${#s} )); then
            i=$(( i + 1 )); w+="${s:i:1}"; have=1
        elif [[ -n "$q" ]]; then
            if [[ "$c" == "$q" ]]; then q=""; else w+="$c"; fi
        elif [[ "$c" == '"' || "$c" == "'" ]]; then
            q="$c"; have=1
        elif [[ "$c" == [[:space:]] ]]; then
            (( have )) && printf '%s\n' "$w"
            w=""; have=0
        else
            w+="$c"; have=1
        fi
    done
    (( have )) && printf '%s\n' "$w"
    return 0
}

# _unit_env_scan KEY [FILE] — what the service's environment ends up with for
# KEY, across the unit and its drop-ins (or FILE alone): the last assignment
# wins and an empty "Environment=" clears everything before it, both as in
# systemd; only [Service] counts. Sets UE_VAL, and UE_SRC to the file that
# decided it ("" if nothing did). Returns 1 when KEY ends up unset or empty.
#
# Parsed here rather than by eval-ing `systemctl show -p Environment`, whose
# output is shell-quoted: eval on a root-owned file that people hand-edit is a
# code-injection path for no benefit. Not read: EnvironmentFile=.
UE_VAL="" UE_SRC=""
_unit_env_scan() {
    local key="$1" f line sect val a
    UE_VAL=""; UE_SRC=""
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        sect=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            if [[ "$line" == \[*\] ]]; then sect="$line"; continue; fi
            [[ "$sect" == "[Service]" ]] || continue
            [[ "$line" =~ ^Environment[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
            val="${BASH_REMATCH[1]}"
            if [[ -z "$val" ]]; then UE_VAL=""; UE_SRC="$f"; continue; fi
            while IFS= read -r a; do
                [[ "$a" == "${key}="* ]] || continue
                UE_VAL="${a#"${key}="}"; UE_SRC="$f"
            done < <(_env_assignments "$val")
        done < "$f"
    done < <(if [[ -n "${2:-}" ]]; then printf '%s\n' "$2"; else _unit_files; fi)
    [[ -n "$UE_VAL" ]]
}

# Echoes the value KEY ends up with (see _unit_env_scan).
unit_env() { _unit_env_scan "$1" || return 1; printf '%s\n' "$UE_VAL"; }

# Another process forcing a duty is invisible after the fact: the EC has one
# duty register, no record of who wrote it, and this firmware answers
# pwmgetduty with INVALID_COMMAND, so there is nothing to read back and compare.
# What CAN be spotted is a second service set up to do the same job. This looks
# at the unit files of active services for a mention of the EC tool.
#
# It is a heuristic and says so: a daemon that only calls ectool from inside a
# script it launches names it nowhere in its unit, and will not show up here.
# Worth having anyway — the predecessor this engine replaced was caught by its
# own ExecStopPost line.
_conflicting_units() {
    local ectool_base="${ECTOOL##*/}" d frag unit state u real
    local -a dirs=() seen_units=()

    # One grep over the unit directories, not a `systemctl show` per unit: this
    # host has ~150 active-or-enabled services, and a dbus round trip each made
    # `status` take the better part of a minute. Reading the files also finds
    # units systemd has not loaded.
    for d in $UNIT_DIRS; do
        [[ -d "$d" ]] && dirs+=("$d")
    done
    (( ${#dirs[@]} )) || return 0

    while IFS= read -r frag; do
        unit="${frag##*/}"
        [[ -n "$unit" && "$unit" != "$SERVICE" ]] || continue
        # /lib/systemd/system is usually a symlink to /usr/lib, and a unit can
        # be overridden in /etc, so the same name turns up more than once.
        for u in ${seen_units[@]+"${seen_units[@]}"}; do [[ "$u" == "$unit" ]] && continue 2; done
        seen_units+=("$unit")

        # A unit file that is neither running nor enabled is just a file. Only
        # the two states that actually reach the EC are worth a warning.
        state="$("$SYSTEMCTL" is-active "$unit" 2>/dev/null)" || true
        if [[ "$state" != active ]]; then
            "$SYSTEMCTL" is-enabled --quiet "$unit" 2>/dev/null || continue
            state="${state:-inactive}, enabled at boot"
        fi

        # Report the file systemd actually loaded, not the grep hit: a unit can
        # be overridden in /etc, and the match may even be an unrelated stray
        # copy of the same name. Only matches get this far, so it is a few calls
        # rather than one per unit on the host.
        real="$("$SYSTEMCTL" show -p FragmentPath --value "$unit" 2>/dev/null)" || true
        [[ -n "$real" ]] && frag="$real"

        printf '%s\t%s\t%s\n' "$unit" "$state" "$frag"
    done < <(grep -rlF --include='*.service' -- "$ectool_base" "${dirs[@]}" 2>/dev/null | sort -u)
    return 0
}

CONFIG_SRC="defaults"
# Adopt the installed unit's values for anything not given explicitly, so the
# "what is my machine doing" commands answer about the running service instead
# of about this script's defaults.
load_unit_config() {
    local key var val seen=0 overridden=0 src
    local -a dropins=()
    if [[ -r "$UNIT" ]]; then
        # TEP_-prefixed, matching what the daemon reads from its environment.
        # These MUST be the same names render_unit writes: a unit setting a key
        # the daemon ignores makes `status` report a curve that is not running.
        # KEY:VARIABLE, since TEP_HWMON lands in HWMON_ROOT.
        for key in CURVE HYST INTERVAL REASSERT SENSORS ALLOW_STOP ECTOOL HWMON:HWMON_ROOT; do
            var="${key#*:}"; key="${key%%:*}"
            _unit_env_scan "TEP_${key}" || true
            val="$UE_VAL"
            # An explicit value wins; it is an override only where it differs
            # from what the unit says.
            if [[ -n "${FROM_ENV[$key]:-}" ]]; then
                [[ -n "$val" && "$val" != "${!var}" ]] && overridden=1
                continue
            fi
            [[ -n "$val" ]] || continue
            printf -v "$var" '%s' "$val"
            seen=1
            if [[ "$UE_SRC" != "$UNIT" ]]; then
                for src in ${dropins[@]+"${dropins[@]}"}; do [[ "$src" == "$UE_SRC" ]] && continue 2; done
                dropins+=("$UE_SRC")
            fi
        done
        # A unit from before the prefix sets CURVE=, which the daemon does not
        # read: it would run defaults while this reported the unit's curve.
        if (( ! seen )) && unit_env CURVE >/dev/null 2>&1; then
            warn "${UNIT} sets CURVE= but the service reads TEP_CURVE= — it is running defaults. Re-run: install --force"
        fi
        (( seen )) && CONFIG_SRC="$UNIT"
        for src in ${dropins[@]+"${dropins[@]}"}; do CONFIG_SRC+=" + ${src}"; done
        (( overridden )) && CONFIG_SRC="${CONFIG_SRC} + overrides"
        validate_numbers
    fi
    # Always, even with no unit to read: every caller of this function then
    # works from a parsed curve, so 'curve' and 'config' do not silently report
    # zero steps on a machine where nothing is installed yet.
    parse_curve
    _check_stop warn
    return 0
}

# The paths go into Environment= and ExecStopPost= verbatim. systemd expands
# '%' specifiers and '$' variables there and splits ExecStopPost on whitespace,
# and the service's working directory is /, so a relative path would point
# somewhere else: such a path is refused rather than written into a unit that
# runs something other than what was asked.
_check_unit_paths() {
    local n v
    for n in ECTOOL HWMON_ROOT BIN; do
        v="${!n}"
        [[ "$v" == /* ]] || error_exit "${n,,} must be an absolute path for the unit (got '${v}')"
        [[ "$v" =~ [[:space:]\"\'\\%\$] ]] \
            && error_exit "${n,,} '${v}' has a character systemd would reinterpret in a unit (space, quote, backslash, % or \$)"
    done
    return 0
}

render_unit() {
    cat <<EOF
[Unit]
Description=${SCRIPT_NAME} — stepped fan curve for EC-controlled fans
Documentation=https://github.com/malahmen/${SCRIPT_NAME}
After=multi-user.target

[Service]
Type=simple
Environment="TEP_CURVE=${CURVE}"
Environment=TEP_HYST=${HYST}
Environment=TEP_INTERVAL=${INTERVAL}
Environment=TEP_REASSERT=${REASSERT}
Environment="TEP_SENSORS=${SENSORS}"
Environment=TEP_ALLOW_STOP=${ALLOW_STOP}
Environment="TEP_ECTOOL=${ECTOOL}"
Environment="TEP_HWMON=${HWMON_ROOT}"
ExecStart=${BIN} run
# Belt and braces with the daemon's own trap: stopping the service must never
# leave the fans pinned at whatever duty was last set.
ExecStopPost=${ECTOOL} autofanctrl
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# Write STDIN to PATH as root, atomically, with MODE.
_install_as_root() {
    local mode="$1" dest="$2" tmp
    tmp="$(mktemp)" || return 1
    cat > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -n "$SUDO" ]]; then
        $SUDO install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    else
        install -m "$mode" "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_run() {
    [[ -x "$ECTOOL" ]] || error_exit "${ECTOOL} not found — install the host's EC tooling (ectool)."

    # The fans must go back to the EC however this process ends, including a
    # systemd stop, a crash in the loop, or a curve refused just below — a
    # restart with a bad curve must not leave a previous duty pinned.
    #
    # Two traps, not one: a TERM handler that only cleans up does NOT end the
    # process — bash runs it and then resumes the loop — so `systemctl stop`
    # would hand the fans back and then sit there until systemd gave up and
    # sent SIGKILL. The signal traps exit; the EXIT trap does the cleanup, once,
    # whichever way the loop ends.
    trap '_ec autofanctrl >/dev/null 2>&1 || true' EXIT
    trap 'exit 0' INT TERM

    parse_curve
    _check_stop refuse

    info "curve: ${CURVE} (hysteresis ${HYST}C, every ${INTERVAL}s, sensors: ${SENSORS})"

    local step=-1 applied=-2 last=0 temp now blind=0 had="$SENSORS" first=1 n
    while :; do
        if _scan; then temp="$HOT"; else temp=""; fi

        # A watched chip that stops answering is said out loud: the curve then
        # follows the others, which may be the cooler ones.
        if [[ "$FOUND" != "$had" ]]; then
            for n in $had; do
                [[ " $FOUND " == *" $n "* ]] && continue
                if (( first )); then warn "watched sensor '${n}' not found under ${HWMON_ROOT} — the curve follows: ${FOUND:-nothing}"
                else warn "watched sensor '${n}' is gone — the curve follows: ${FOUND:-nothing}"; fi
            done
            for n in $FOUND; do
                [[ " $had " == *" $n "* ]] || info "watched sensor '${n}' is back"
            done
            had="$FOUND"
        fi
        first=0

        if [[ -z "$temp" ]]; then
            # Not treated as cold. For a moment — a driver rebinding — the
            # current duty is held; past BLIND_READS the fans go back to the
            # EC, whose own control reads its own sensors, rather than holding
            # a possibly low duty on a machine nobody is watching.
            blind=$(( blind + 1 ))
            if (( blind < BLIND_READS )); then
                (( blind == 1 )) && warn "no readable sensor among: ${SENSORS} — holding $(label "$step"); the EC gets the fans back after ${BLIND_READS} failed reads"
                sleep "$INTERVAL"
                continue
            fi
            (( blind == BLIND_READS )) && error "no readable sensor among: ${SENSORS} for ${BLIND_READS} reads in a row — handing the fans back to the EC until one answers"
            step=-1; temp="no sensor: "
        else
            (( blind >= BLIND_READS )) && info "a watched sensor answers again (${temp}C) — the curve resumes"
            blind=0
            step="$(decide "$temp" "$step")"
            temp="${temp}C"
        fi
        now="$SECONDS"

        if (( step != applied )); then
            if apply "$step"; then
                applied="$step"; last="$now"
                printf '%s%s -> %s\n' "$(_pfx)" "$temp" "$(label "$step")" >&2
            else
                warn "ectool refused ${temp} -> $(label "$step"); retrying next tick"
            fi
        elif (( now - last >= REASSERT )); then
            # The EC forgets a forced duty across suspend/resume, so the
            # current state is re-sent periodically even when nothing changed.
            apply "$step" || warn "ectool refused a re-assert of $(label "$step")"
            last="$now"
        fi
        sleep "$INTERVAL"
    done
}

cmd_once() {
    load_unit_config
    local t
    t="$(hottest)" || error_exit "no readable sensor among: ${SENSORS} (see '${SCRIPT_NAME}.sh sensors')"
    printf '%sC\t%s\tcold-start\n' "$t" "$(label "$(decide "$t" -1)")"
}

cmd_simulate() {
    (( $# )) || error_exit "simulate needs temperatures, e.g. simulate 68 75 85"
    parse_curve
    _check_stop warn
    local s=-1 t
    for t in "$@"; do
        [[ "$t" =~ ^(-?)([0-9]{1,6})$ ]] || error_exit "not a temperature: ${t}"
        t="${BASH_REMATCH[1]}$(_dec "${BASH_REMATCH[2]}")"
        s="$(decide "$t" "$s")"
        printf '%s\t%s\n' "$t" "$(label "$s")"
    done
}

cmd_curve() {
    load_unit_config
    local i
    for i in "${!CT[@]}"; do printf '%s\t%s\n' "${CT[$i]}" "${CD[$i]}"; done
}

# Every sensor the host has, not just the watched ones: this is what a front-end
# builds its picker from, so it has to show what is available to choose.
cmd_sensors() {
    load_unit_config
    local d name f v hi watched want
    for d in "$HWMON_ROOT"/hwmon*; do
        [[ -r "$d/name" ]] || continue
        name="$(<"$d/name")"
        hi=""
        for f in "$d"/temp*_input; do
            [[ -r "$f" ]] || continue
            v="$(<"$f")" || continue
            [[ "$v" =~ ^(-?)([0-9]{1,9})$ ]] || continue
            v="${BASH_REMATCH[1]}$(_dec "${BASH_REMATCH[2]}")"
            if [[ -z "$hi" ]] || (( v > hi )); then hi="$v"; fi
        done
        watched=0
        for want in $SENSORS; do [[ "$want" == "$name" ]] && { watched=1; break; }; done
        printf '%s\t%s\t%s\n' "$name" "$([[ -n "$hi" ]] && echo $(( hi / 1000 )) || echo '-')" "$watched"
    done
}

cmd_fans() {
    local line i=0
    # ectool prints one "Fan N RPM: x" line per fan; reduced to TSV so a caller
    # does not have to parse ectool's wording.
    while IFS= read -r line; do
        [[ "$line" =~ ([0-9]+)[[:space:]]*$ ]] || continue
        printf '%s\t%s\n' "$i" "${BASH_REMATCH[1]}"
        i=$(( i + 1 ))
    done < <(_ec_ro pwmgetfanrpm all)
    (( i )) || { warn "could not read fan RPM (needs root: ${SUDO:-sudo} ${ECTOOL} pwmgetfanrpm all)"; return 1; }
}

cmd_conflicts() { _conflicting_units; }

cmd_config() {
    load_unit_config
    printf 'unit=%s\n'          "$UNIT"
    printf 'unit_exists=%d\n'   "$([[ -f "$UNIT" ]] && echo 1 || echo 0)"
    printf 'bin=%s\n'           "$BIN"
    printf 'bin_exists=%d\n'    "$([[ -f "$BIN" ]] && echo 1 || echo 0)"
    printf 'config_source=%s\n' "$CONFIG_SRC"
    printf 'service=%s\n'       "$SERVICE"
    printf 'active=%s\n'        "$("$SYSTEMCTL" is-active "$SERVICE" 2>/dev/null || true)"
    printf 'enabled=%s\n'       "$("$SYSTEMCTL" is-enabled "$SERVICE" 2>/dev/null || true)"
    printf 'curve=%s\n'         "$CURVE"
    printf 'hyst=%s\n'          "$HYST"
    printf 'interval=%s\n'      "$INTERVAL"
    printf 'reassert=%s\n'      "$REASSERT"
    printf 'sensors=%s\n'       "$SENSORS"
    printf 'allow_stop=%s\n'    "$ALLOW_STOP"
    printf 'ectool=%s\n'        "$ECTOOL"
    printf 'ectool_exists=%d\n' "$([[ -x "$ECTOOL" ]] && echo 1 || echo 0)"
    printf 'hwmon=%s\n'         "$HWMON_ROOT"
    printf 'steps=%d\n'         "${#CT[@]}"
    printf 'conflicts=%d\n'     "$(_conflicting_units | grep -c . || true)"
}

cmd_status() {
    load_unit_config
    local t rpm state
    # `systemctl is-active` PRINTS "inactive" and exits non-zero, so an `|| echo`
    # fallback here appends a second line rather than replacing the first.
    state="$("$SYSTEMCTL" is-active "$SERVICE" 2>/dev/null)" || true
    [[ -n "$state" ]] || state="unknown"
    printf 'service : %s\n' "$state"
    printf 'config  : %s\n' "$CONFIG_SRC"
    printf 'curve   : %s   (hysteresis %sC)\n' "$CURVE" "$HYST"
    if t="$(hottest)"; then
        printf 'temp    : %sC   (hottest of: %s)\n' "$t" "$SENSORS"
    else
        printf 'temp    : unreadable   (looked for: %s)\n' "$SENSORS"
    fi
    if rpm="$(cmd_fans 2>/dev/null)"; then
        while IFS=$'\t' read -r i r; do printf 'fan %s   : %s RPM\n' "$i" "$r"; done <<<"$rpm"
    else
        printf 'fan     : unreadable   (needs root: %s %s pwmgetfanrpm all)\n' "${SUDO:-sudo}" "$ECTOOL"
    fi
    local clash
    clash="$(_conflicting_units)"
    if [[ -n "$clash" ]]; then
        printf 'conflict: another service also drives %s:\n' "${ECTOOL##*/}"
        while IFS=$'\t' read -r u st _; do printf '          %s  [%s]\n' "$u" "$st"; done <<< "$clash"
    fi
    # The journal is the only honest answer about what duty is applied right
    # now: 'once' reports a cold start, and hysteresis means the service can
    # legitimately be holding a higher step.
    if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then
        printf '\nlast steps (the service, hysteresis included):\n'
        journalctl -u "$SERVICE" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
    fi
    return 0
}

cmd_install() {
    parse_curve
    _check_stop refuse
    _check_unit_paths
    [[ -x "$ECTOOL" ]] || warn "${ECTOOL} not found — install the host's EC tooling before starting the service."

    # Two fan daemons both writing the EC's single duty register fight, and the
    # loser is whichever wrote first — with nothing in any log to say so.
    local clash
    clash="$(_conflicting_units)"
    if [[ -n "$clash" ]]; then
        warn "another active service also drives ${ECTOOL##*/} — both would write the EC's one duty register:"
        while IFS=$'\t' read -r u st f; do warn "  ${u}  [${st}]  (${f})"; done <<< "$clash"
        warn "stop it first: ${SUDO:-sudo} systemctl disable --now <unit>"
    fi

    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    if (( DRY_RUN )); then
        info "would install ${self} -> ${BIN}"
        if [[ -e "$UNIT" ]] && (( ! FORCE )); then
            info "would keep the existing ${UNIT}"
        else
            info "would write ${UNIT}:"
            render_unit | sed 's/^/    /' >&2
        fi
        info "would: ${SYSTEMCTL} daemon-reload; ${SYSTEMCTL} enable --now ${SERVICE}"
        return 0
    fi

    if [[ "$self" != "$BIN" ]]; then
        _install_as_root 755 "$BIN" < "$self" || error_exit "could not install ${BIN}"
        success "installed ${BIN}"
    else
        dbg "already running from ${BIN}; not copying onto itself"
    fi

    # An existing unit is somebody's tuning. Replacing it on every install would
    # silently reset a curve that was deliberately chosen, so it is kept unless
    # --force says otherwise.
    if [[ -e "$UNIT" ]] && (( ! FORCE )); then
        info "kept the existing ${UNIT} (--force to reset it to the given values)"
    else
        render_unit | _install_as_root 644 "$UNIT" || error_exit "could not write ${UNIT}"
        success "wrote ${UNIT}"
    fi

    $SUDO "$SYSTEMCTL" daemon-reload || error_exit "daemon-reload failed"
    $SUDO "$SYSTEMCTL" enable "$SERVICE" >/dev/null 2>&1 || error_exit "enabling ${SERVICE} failed"
    $SUDO "$SYSTEMCTL" restart "$SERVICE" || error_exit "starting ${SERVICE} failed"
    success "${SERVICE} is $("$SYSTEMCTL" is-active "$SERVICE" 2>/dev/null || echo '?')"
}

cmd_uninstall() {
    if (( DRY_RUN )); then
        info "would: ${SYSTEMCTL} disable --now ${SERVICE}; rm ${UNIT} ${BIN}; ${ECTOOL} autofanctrl"
        return 0
    fi
    if (( ! ASSUME_YES )); then
        [[ -t 0 ]] || error_exit "uninstall removes files — pass --yes when there is no terminal."
        local a
        read -r -p "Remove ${UNIT} and ${BIN}, and hand the fans back to the EC? [y/N] " a
        [[ "$a" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }
    fi

    $SUDO "$SYSTEMCTL" disable --now "$SERVICE" >/dev/null 2>&1 || true
    $SUDO rm -f "$UNIT" "$BIN" || error_exit "could not remove ${UNIT} / ${BIN}"
    $SUDO "$SYSTEMCTL" daemon-reload || true
    # Last, and unconditionally: whatever else failed, the fans must not be left
    # pinned by a service that is now gone.
    _ec autofanctrl >/dev/null 2>&1 && success "fans handed back to the EC" \
        || warn "could not reach ${ECTOOL} — check the fans with 'ectool autofanctrl'"
    success "removed ${UNIT} and ${BIN}"
}

# _set_env_line KEY LINE — copy a unit from stdin to stdout with KEY's
# Environment= line replaced by LINE (the first one; later duplicates are
# dropped). With none, LINE goes right after the [Service] header — appending
# it at the end of the file would put it under [Install], where systemd
# ignores it.
_set_env_line() {
    local key="$1" new="$2" line has_key=0 done_once=0
    local -a buf=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        buf+=("$line")
        [[ "$line" == "Environment=\"${key}="* || "$line" == "Environment=${key}="* ]] && has_key=1
    done
    for line in ${buf[@]+"${buf[@]}"}; do
        if [[ "$line" == "Environment=\"${key}="* || "$line" == "Environment=${key}="* ]]; then
            (( done_once )) || printf '%s\n' "$new"
            done_once=1
            continue
        fi
        printf '%s\n' "$line"
        if (( ! has_key && ! done_once )) && [[ "$line" == "[Service]" ]]; then
            printf '%s\n' "$new"; done_once=1
        fi
    done
    (( done_once )) || printf '%s\n' "$new"
}

cmd_set_curve() {
    (( $# )) || error_exit "set-curve needs points, e.g. set-curve '70:40 80:100'"
    [[ -f "$UNIT" ]] || error_exit "no unit at ${UNIT} — run 'install' first."

    # Validate against the NEW curve before touching the unit: a rejected curve
    # must leave the running service exactly as it was.
    CURVE="$*"
    parse_curve
    _check_stop refuse

    # A drop-in applies after the unit. Rewriting the unit's line under one
    # that sets (or clears) the same key changes nothing the service runs while
    # reporting success — so that is refused, naming the file to edit instead.
    local k
    for k in TEP_CURVE TEP_ALLOW_STOP; do
        _unit_env_scan "$k" || true
        [[ -z "$UE_SRC" || "$UE_SRC" == "$UNIT" ]] && continue
        error_exit "${k} is decided by the drop-in ${UE_SRC}, which systemd applies after ${UNIT}: rewriting the unit would not change what the service runs. Change it in that drop-in (or remove it there, then re-run set-curve)."
    done

    if (( DRY_RUN )); then
        info "would set CURVE=${CURVE} in ${UNIT} and restart ${SERVICE}"
        return 0
    fi

    # Rewrite in place rather than re-render: the unit may carry edits (a
    # different interval, an added dependency) that a full rewrite would drop.
    # TEP_ALLOW_STOP travels with the curve: a unit that allowed a stop for its
    # old curve must not silently allow one for the next.
    local out
    out="$(_set_env_line TEP_CURVE "Environment=\"TEP_CURVE=${CURVE}\"" < "$UNIT" \
        | _set_env_line TEP_ALLOW_STOP "Environment=TEP_ALLOW_STOP=${ALLOW_STOP}")"
    # Read the result back before writing it: a line set-curve cannot rewrite
    # (several assignments on one line, say) would otherwise keep winning.
    local check var
    check="$(mktemp)" || error_exit "mktemp failed"
    printf '%s\n' "$out" > "$check"
    for k in TEP_CURVE:CURVE TEP_ALLOW_STOP:ALLOW_STOP; do
        var="${k#*:}"
        _unit_env_scan "${k%%:*}" "$check" || true
        [[ "$UE_VAL" == "${!var}" ]] && continue
        rm -f "$check"
        error_exit "${UNIT} would still set ${k%%:*}=${UE_VAL} on a line set-curve cannot rewrite — edit that line by hand."
    done
    rm -f "$check"

    printf '%s\n' "$out" | _install_as_root 644 "$UNIT" || error_exit "could not write ${UNIT}"
    success "curve set to ${CURVE}"

    $SUDO "$SYSTEMCTL" daemon-reload || error_exit "daemon-reload failed"
    if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then
        $SUDO "$SYSTEMCTL" restart "$SERVICE" || error_exit "restarting ${SERVICE} failed"
        success "${SERVICE} restarted"
    fi
}

# Validated in one place, so every command fails the same way on a bad number
# instead of each one growing its own check — and called again after a unit's
# values are adopted, which no flag parsing ever saw. Each value is rewritten
# in decimal (see _dec).
validate_numbers() {
    local n
    for n in HYST INTERVAL REASSERT; do
        [[ "${!n}" =~ ^[0-9]{1,6}$ ]] || error_exit "--${n,,} must be a non-negative integer (got '${!n}')"
        printf -v "$n" '%s' "$(_dec "${!n}")"
    done
    [[ "$ALLOW_STOP" =~ ^[01]$ ]] || error_exit "TEP_ALLOW_STOP must be 0 or 1 (got '${ALLOW_STOP}')"
    (( INTERVAL >= 1 )) || error_exit "--interval must be at least 1 second"
    (( INTERVAL <= MAX_INTERVAL )) \
        || error_exit "--interval must be at most ${MAX_INTERVAL} seconds (got ${INTERVAL}) — a slower loop cannot follow a loaded SoC"
}

# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-}" args=()
    [[ $# -gt 0 ]] && shift
    while (( $# )); do
        case "$1" in
            --curve)      [[ $# -ge 2 ]] || error_exit "--curve needs POINTS";  CURVE="$2";      FROM_ENV[CURVE]=1;    shift 2 ;;
            --curve=*)    CURVE="${1#*=}";       FROM_ENV[CURVE]=1;    shift ;;
            --hyst)       [[ $# -ge 2 ]] || error_exit "--hyst needs N";        HYST="$2";       FROM_ENV[HYST]=1;     shift 2 ;;
            --hyst=*)     HYST="${1#*=}";        FROM_ENV[HYST]=1;     shift ;;
            --interval)   [[ $# -ge 2 ]] || error_exit "--interval needs N";    INTERVAL="$2";   FROM_ENV[INTERVAL]=1; shift 2 ;;
            --interval=*) INTERVAL="${1#*=}";    FROM_ENV[INTERVAL]=1; shift ;;
            --reassert)   [[ $# -ge 2 ]] || error_exit "--reassert needs N";    REASSERT="$2";   FROM_ENV[REASSERT]=1; shift 2 ;;
            --reassert=*) REASSERT="${1#*=}";    FROM_ENV[REASSERT]=1; shift ;;
            --sensors)    [[ $# -ge 2 ]] || error_exit "--sensors needs NAMES"; SENSORS="$2";    FROM_ENV[SENSORS]=1;  shift 2 ;;
            --sensors=*)  SENSORS="${1#*=}";     FROM_ENV[SENSORS]=1;  shift ;;
            --ectool)     [[ $# -ge 2 ]] || error_exit "--ectool needs PATH";   ECTOOL="$2";     FROM_ENV[ECTOOL]=1; shift 2 ;;
            --ectool=*)   ECTOOL="${1#*=}";      FROM_ENV[ECTOOL]=1; shift ;;
            --hwmon)      [[ $# -ge 2 ]] || error_exit "--hwmon needs DIR";     HWMON_ROOT="$2"; FROM_ENV[HWMON]=1;  shift 2 ;;
            --hwmon=*)    HWMON_ROOT="${1#*=}";  FROM_ENV[HWMON]=1;  shift ;;
            --unit-dirs)  [[ $# -ge 2 ]] || error_exit "--unit-dirs needs DIRS";  UNIT_DIRS="$2";  shift 2 ;;
            --unit-dirs=*) UNIT_DIRS="${1#*=}";  shift ;;
            --bin)        [[ $# -ge 2 ]] || error_exit "--bin needs PATH";      BIN="$2";        shift 2 ;;
            --bin=*)      BIN="${1#*=}";         shift ;;
            --unit)       [[ $# -ge 2 ]] || error_exit "--unit needs PATH";     UNIT="$2";       shift 2 ;;
            --unit=*)     UNIT="${1#*=}";        shift ;;
            --allow-stop) ALLOW_STOP=1; FROM_ENV[ALLOW_STOP]=1; shift ;;
            --force)      FORCE=1;      shift ;;
            --dry-run)    DRY_RUN=1;    shift ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -v|--verbose) VERBOSE=1;    shift ;;
            -h|--help)    usage; exit 0 ;;
            --)           shift; args+=("$@"); break ;;
            -*)           error_exit "unknown flag: $1 (see --help)" ;;
            *)            args+=("$1"); shift ;;
        esac
    done

    SERVICE="${UNIT##*/}"
    [[ "$SERVICE" == *.service ]] || error_exit "--unit must name a .service file (got '${UNIT##*/}')"

    validate_numbers

    # `tep --curve X simulate 75` is a natural thing to type, and taking $1 as
    # the command turns it into "unknown command: --curve". Name the real
    # mistake instead.
    case "$cmd" in
        -h|--help|help|"") : ;;
        -*) usage; error_exit "'${cmd}' is a flag, not a command — the command comes first: ${SCRIPT_NAME}.sh <command> [flags]" ;;
    esac

    case "$cmd" in
        run)        cmd_run ;;
        status)     cmd_status ;;
        once)       cmd_once ;;
        simulate)   cmd_simulate "${args[@]}" ;;
        curve)      cmd_curve ;;
        sensors)    cmd_sensors ;;
        fans)       cmd_fans ;;
        install)    cmd_install ;;
        uninstall)  cmd_uninstall ;;
        set-curve)  cmd_set_curve "${args[@]}" ;;
        conflicts)  cmd_conflicts ;;
        config)     cmd_config ;;
        version)    echo "${SCRIPT_NAME} ${VERSION}" ;;
        ""|-h|--help|help) usage; [[ -n "$cmd" ]] ;;
        *)          usage; error_exit "unknown command: ${cmd}" ;;
    esac
}

main "$@"
