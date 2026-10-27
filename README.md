# thermal-exhaust-port

A stepped fan curve for machines whose fans sit behind an embedded controller
rather than hwmon PWM. Gum-free, flag-driven, and built to run as a systemd
service — the interactive front-end lives in
[scomp-link](https://github.com/malahmen/scomp-link).

## Why this exists

On a Framework Desktop (Ryzen AI Max 300), `/sys/class/hwmon` exposes **no
`pwm*` nodes at all**:

```
hwmon5  amdgpu    temp1_input           (edge)
hwmon6  k10temp   temp1_input           (Tctl)
hwmon8  cros_ec   fan1_input  1025      fan1_target  926   (read-only)
```

`cros_ec` offers read-only RPM and temperatures, and `fan1_target` is not
writable. Every hwmon-based fan tool — fan-control, `fancontrol`,
coolercontrol — has nothing to drive. Fan control goes through the EC, via
`ectool`.

And the stock EC curve is lazy. On that board the SoC idles near 70 °C with the
fan at ~1000 RPM, and under load drifts into the 80s and 90s before the EC does
much about it.

**This is not a wrapper around `ectool`.** `ectool fanduty 50` sets one duty
cycle and forgets it. The curve, the hysteresis, the sensor resolution and the
daemon are here.

## Install

```sh
git clone https://github.com/malahmen/thermal-exhaust-port.git
cd thermal-exhaust-port
./thermal-exhaust-port.sh install --curve "72:35 78:60 84:85 88:100"
```

That copies the script to `/usr/local/bin`, writes
`/etc/systemd/system/thermal-exhaust-port.service`, and enables it. On an ostree
host (Fedora Atomic, Bazzite) both land in writable overlays — `/usr/local` is a
symlink to `/var/usrlocal` — so the install survives `rpm-ostree` updates.

It needs `ectool` on `PATH` (Bazzite already ships it, as `ectool`, `fw-ectool`
and `framework_tool`). Nothing is installed for you: there is nobody here to ask.

## Commands

```
run                      the daemon loop; what the systemd unit calls
status                   service state, resolved config, temperature, fan RPM
once                     the hottest watched sensor and the duty the curve picks
simulate T...            walk the curve over temperatures, change nothing
curve                    the resolved curve as TSV: degC<TAB>duty
sensors                  every hwmon sensor as TSV: name<TAB>degC<TAB>watched(0|1)
fans                     fan RPM as TSV: index<TAB>rpm
install                  write the systemd unit and enable it
uninstall                remove it, hand the fans back to the EC
set-curve POINTS         rewrite the installed unit's curve and restart
conflicts                other services that drive ectool, as TSV
config                   the resolved config as key=value
version
```

Data goes to stdout, logs to stderr, so the TSV commands pipe cleanly. Run
`--help` for the flags.

**The command comes first**, then flags: `thermal-exhaust-port.sh simulate
--curve "70:40" 75`.

## The curve

Each `degC:duty%` point is a step. The duty applied is the highest step whose
temperature the hottest watched sensor has reached. Below the first point, the
EC's own control is handed back (`ectool autofanctrl`).

Hysteresis is **one-sided**: a step is entered at its temperature but only left
once the temperature falls `--hyst` degrees below it. So a machine hovering on a
threshold does not oscillate:

```sh
$ ./thermal-exhaust-port.sh simulate --curve "72:35 78:60 84:85 88:100" 71 72 79 85 89 84 79 73 67
71   auto (EC)
72   35%
79   60%
85   85%
89   100%
84   100%      # held: 84 is not yet 4 below 88
79   60%
73   35%
67   auto (EC)
```

`simulate` touches no hardware, so try a curve before installing it.

**A fan never cools less as it gets hotter.** Duties may not fall from one step
to the next — `72:60 80:20` (20% at 85 °C) is refused, naming the point. That
leaves 0% (fans stopped) possible only on the coolest steps, and even there it
stops fans that the EC's own control, below the first point, keeps turning:
`60:0 90:100` stops them from 60 °C until 90 °C. `run`, `install` and
`set-curve` refuse such a curve unless `--allow-stop` says the fans may stop
(the unit records it as `TEP_ALLOW_STOP=1`, and `set-curve` without the flag
resets it); `simulate` warns. The same rules as carbonite.

## Tuning

| Flag | `TEP_*` | Default | Meaning |
| --- | --- | --- | --- |
| `--curve` | `TEP_CURVE` | `72:35 78:60 84:85 88:100` | `degC:duty%` points, ascending |
| `--hyst` | `TEP_HYST` | `4` | degC to fall below a step before dropping to it |
| `--interval` | `TEP_INTERVAL` | `3` | seconds between checks, 1-60: a loaded SoC climbs tens of degrees in a few seconds |
| `--reassert` | `TEP_REASSERT` | `60` | seconds; re-send the current state |
| `--sensors` | `TEP_SENSORS` | `k10temp amdgpu` | hwmon names to watch, hottest wins |
| `--allow-stop` | `TEP_ALLOW_STOP=1` | off | let a curve start with 0% steps (fans stopped) |
| `--ectool` | `TEP_ECTOOL` | `/usr/bin/ectool` | the EC tool |
| `--hwmon` | `TEP_HWMON` | `/sys/class/hwmon` | sysfs hwmon root |
| `--unit-dirs` | `TEP_UNIT_DIRS` | the four systemd dirs | where `conflicts` looks for unit files |
| `--bin` | `TEP_BIN` | `/usr/local/bin/thermal-exhaust-port.sh` | where `install` puts the script |
| `--unit` | `TEP_UNIT` | `/etc/systemd/system/thermal-exhaust-port.service` | the systemd unit |

Change the curve of a running service without editing the unit by hand:

```sh
./thermal-exhaust-port.sh set-curve "60:35 70:45 75:60 80:85 85:100"
```

It validates the new curve **before** touching the file, rewrites only the
`TEP_CURVE=` and `TEP_ALLOW_STOP=` lines — so an interval or a dependency you
added by hand survives; a missing line goes under `[Service]` — and restarts
the service only if it was already running.

## Where the configuration lives

**In the systemd unit**, as `Environment=` lines — not in `~/.config`.

The daemon runs as root under systemd, so a per-user XDG config would be read by
the CLI and ignored by the service: two sources of truth that disagree exactly
when it matters.

The unit sets the **`TEP_`-prefixed** names — `TEP_CURVE`, `TEP_HYST`,
`TEP_INTERVAL`, `TEP_REASSERT`, `TEP_SENSORS`, `TEP_ALLOW_STOP`, `TEP_ECTOOL`,
`TEP_HWMON` — because those are the ones the
daemon reads from its environment. These must stay in step: a unit that sets a
name the daemon ignores makes the service run its defaults while `status`
reports the unit's curve, which is the worst of both. `tests/test-run.sh`
exports the generated unit's `Environment` lines, starts the daemon with no
flags, and asserts it announces the unit's values — and audits that every key
written is one the engine reads, and that every one of them is written:
`install --ectool /opt/fw/ectool` once left the service looking for
`/usr/bin/ectool` and restarting every 5 s. `install` refuses a relative
`--ectool`, `--hwmon` or `--bin`, or one with a space, quote, backslash, `%`
or `$`, which systemd would reinterpret in the unit. A unit from before the prefix is detected and
called out rather than silently misreported. `status`, `once`, `curve` and `config` read the unit back;
`set-curve` rewrites it. An explicit flag or `TEP_*` variable overrides it, and
`config` says so in its `config_source` line.

`simulate` is the deliberate exception — it ignores the unit, because it is the
"what if" command.

This is a documented departure from the sibling engines (`~/.config/<name>/`),
and the reason is the root daemon.

## Two daemons, one register

The EC has a single fan-duty register and no record of who wrote it. **This
firmware answers `pwmgetduty` with `INVALID_COMMAND`** — tested on a Framework
Desktop, for every PWM index — so a duty set by something else cannot be read
back, detected or attributed. `fan1_target` in sysfs is no help either: it
tracks the EC's auto-mode target and goes stale the moment a duty is forced.

Last write wins, silently. Two things are done about it:

- **`--reassert` recovers.** The current step is re-sent every N seconds
  (default 60), so a foreign write is overridden back within that window. Lower
  it if something on the machine is known to fight.
- **`conflicts` warns.** It lists services whose unit file mentions the EC tool
  — active ones *and* enabled-but-stopped ones, since those fight after the next
  boot. `install` and `status` show it too.

```sh
$ ./thermal-exhaust-port.sh conflicts
fancurve.service    failed, enabled at boot    /etc/systemd/system/fancurve.service
```

It is a heuristic and is documented as one: a daemon that calls `ectool` only
from inside a script it launches names it nowhere in its unit and will not
appear. No drift detector is built on RPM, because this board has three fan
slots of which two always read 0 RPM, and the calibration would be fiction.

## Checking what it is doing

```sh
./thermal-exhaust-port.sh status
journalctl -u thermal-exhaust-port -f      # one line per step change
```

`once` reports the duty a **cold start** would pick, and labels itself
`cold-start`. A running service can legitimately differ, because hysteresis
holds it on a higher step on the way down — `status` prints the service's own
journal lines for the real answer.

## Notes

- **hwmon indices are not stable across reboots.** A driver loading in a
  different order renumbers them, so sensors are resolved by `name` on every
  read. A hardcoded `hwmon6` silently starts reading the wrong chip.
- **An unreadable sensor is not a cold machine.** A failed read holds the
  current duty and says so once, rather than handing a hot machine back to the
  EC on the strength of it.
- **The fans always go back to the EC.** An `EXIT` trap, separate signal traps
  that actually exit, and `ExecStopPost` in the unit. A `TERM` handler that only
  cleans up does *not* end the process — bash resumes the loop — so `systemctl
  stop` would otherwise hand the fans back and then wait for SIGKILL.
- **The EC forgets a forced duty across suspend/resume**, so the current state
  is re-sent every `--reassert` seconds even when nothing changed.
- **Numbers are decimal.** Curve points, `--hyst`, `--interval`, `--reassert`
  and the unit's values are read with `10#`, so `072:35` is a step at 72 °C
  and `--hyst 08` is 8 — bash arithmetic would otherwise take them as octal.
- **`set -e` is deliberately absent.** `(( s-- ))` evaluating to 0 returns
  non-zero, and errexit would kill the daemon loop mid-step.
- **The unit is parsed in pure bash**, not by `eval`-ing `systemctl show -p
  Environment`. That output is shell-quoted, and eval on a root-owned file
  people hand-edit is a code-injection path for no benefit.
- **`install` keeps an existing unit** unless `--force`, so re-running it after
  pulling a new version does not reset a curve somebody chose on purpose.
- **The service name follows `--unit`.** It is the unit file's own basename, not
  a constant: with a fixed name, `--unit` would write one file and then enable,
  restart and report on a different unit entirely.
- **Read-only EC queries use `sudo -n`.** A plain `sudo` cost `status` eight
  seconds on a host with no cached credential, and would hang where nothing can
  answer the prompt. Reports degrade to "unreadable"; only writes prompt.

## Tests

```sh
tests/run-all.sh
```

No network, no hardware, no privilege — a fake sysfs tree, recording `ectool`
and `systemctl` stubs, and `TEP_SUDO=""`. `tests/test-run.sh` drives the real
daemon loop, changes the temperature under it, and asserts on the `ectool` calls
it makes.

## License

MIT
