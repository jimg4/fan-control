#!/usr/bin/env python3
"""fanctl — fan control for the MacBookPro14,1 (13" 2017, applesmc, one fan).

Runs as a root systemd service (`fanctl daemon`) and as an unprivileged CLI
(`fanctl set ...`, `fanctl status`). The CLI only edits the config file; the
daemon is the only thing that ever touches the SMC.

Modes, borrowed from Macs Fan Control:
  auto    sensor-based curve: fan minimum until `rampStart`, then a straight
          line up to fan maximum at `fullBlast`.
  target  hold the control sensor at `targetTemp` with a PI loop.
  manual  constant `manualRpm`.
  system  hand the fan back to Apple's SMC.

In every mode except `system`, crossing `fullBlast` on the control sensor
forces maximum speed, and the CPU package reaching HARD_LIMIT_C does so
regardless of which sensor is selected.
"""

from __future__ import annotations

import json
import math
import os
import signal
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_PATH = Path(os.environ.get("FANCTL_CONFIG", "/etc/fan-control/config.json"))
STATE_PATH = Path(os.environ.get("FANCTL_STATE", "/run/fan-control/state.json"))
HWMON_ROOT = Path(os.environ.get("FANCTL_HWMON", "/sys/class/hwmon"))

MODES = ("auto", "target", "manual", "system")

DEFAULTS = {
    "mode": "auto",
    "sensor": "cpu",
    "manualRpm": 3000,
    "targetTemp": 70,
    "rampStart": 55,
    "fullBlast": 85,
}

# Inclusive bounds the config is clamped into. RPM is further clamped to the
# fan's own min/max at runtime.
LIMITS = {
    "manualRpm": (1000, 8000),
    "targetTemp": (45, 90),
    "rampStart": (30, 90),
    "fullBlast": (40, 95),
}
MIN_CURVE_SPAN = 5  # °C between rampStart and fullBlast

HARD_LIMIT_C = 95.0      # CPU package: full speed no matter what
BLAST_HYSTERESIS_C = 3.0  # full blast releases this far below the threshold
SENSOR_INVALID_BELOW = -40.0  # SMC reports -127/-128 for absent sensors
RPM_QUANTUM = 50
REASSERT_SECONDS = 30.0
MAX_CONFIG_BYTES = 64 * 1024

# Sensors worth showing on this machine, in display order. `source` is the
# hwmon device name, `label` the hwmon temp label (SMC key for applesmc).
SENSORS = [
    {"id": "cpu", "name": "CPU Package", "source": "coretemp", "label": "Package id 0"},
    {"id": "cpu-core-1", "name": "CPU Core 1", "source": "coretemp", "label": "Core 0"},
    {"id": "cpu-core-2", "name": "CPU Core 2", "source": "coretemp", "label": "Core 1"},
    {"id": "cpu-proximity", "name": "CPU Proximity", "source": "applesmc", "label": "TC0P"},
    {"id": "gpu", "name": "Graphics", "source": "applesmc", "label": "TCGC"},
    {"id": "pch", "name": "Chipset (PCH)", "source": "applesmc", "label": "TPCD"},
    {"id": "memory", "name": "Memory Proximity", "source": "applesmc", "label": "TM0P"},
    {"id": "heatsink", "name": "Heatsink", "source": "applesmc", "label": "Th1H"},
    {"id": "airflow", "name": "Airflow", "source": "applesmc", "label": "TaLC"},
    {"id": "ssd", "name": "SSD", "source": "nvme", "label": "Composite"},
    {"id": "battery", "name": "Battery", "source": "applesmc", "label": "TB0T"},
    {"id": "palm-rest", "name": "Palm Rest", "source": "applesmc", "label": "Ts0P"},
    {"id": "ambient", "name": "Ambient", "source": "applesmc", "label": "TA0V"},
]
SENSOR_IDS = tuple(s["id"] for s in SENSORS)
SENSOR_NAMES = {s["id"]: s["name"] for s in SENSORS}

KEY_ALIASES = {
    "rpm": "manualRpm",
    "manual": "manualRpm",
    "target": "targetTemp",
    "ramp": "rampStart",
    "blast": "fullBlast",
}


# --------------------------------------------------------------------- config

def _as_int(value, fallback):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return fallback
    if math.isnan(number) or math.isinf(number):
        return fallback
    return int(round(number))


def normalize_config(raw, prefer=None) -> dict:
    """Return a complete, valid config from untrusted input.

    `prefer` names the key the user just changed, so that when rampStart and
    fullBlast collide the other one moves out of the way.
    """
    cfg = dict(DEFAULTS)
    if isinstance(raw, dict):
        for key in DEFAULTS:
            if key in raw:
                cfg[key] = raw[key]

    cfg["mode"] = cfg["mode"] if cfg["mode"] in MODES else DEFAULTS["mode"]
    cfg["sensor"] = cfg["sensor"] if cfg["sensor"] in SENSOR_IDS else DEFAULTS["sensor"]
    for key, (low, high) in LIMITS.items():
        cfg[key] = max(low, min(high, _as_int(cfg[key], DEFAULTS[key])))

    if cfg["fullBlast"] - cfg["rampStart"] < MIN_CURVE_SPAN:
        if prefer == "rampStart":
            cfg["fullBlast"] = min(LIMITS["fullBlast"][1], cfg["rampStart"] + MIN_CURVE_SPAN)
            cfg["rampStart"] = cfg["fullBlast"] - MIN_CURVE_SPAN
        else:
            cfg["rampStart"] = max(LIMITS["rampStart"][0], cfg["fullBlast"] - MIN_CURVE_SPAN)
            cfg["fullBlast"] = cfg["rampStart"] + MIN_CURVE_SPAN
    return cfg


def load_config(path: Path = CONFIG_PATH) -> dict:
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_CONFIG_BYTES + 1)
        if len(data) > MAX_CONFIG_BYTES:
            return normalize_config(None)
        return normalize_config(json.loads(data.decode("utf-8")))
    except (OSError, ValueError, UnicodeDecodeError):
        return normalize_config(None)


def atomic_write_json(path: Path, payload, mode=0o664):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            os.fchmod(handle.fileno(), mode)
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def apply_changes(cfg: dict, pairs) -> dict:
    """Apply CLI `key value` pairs to a config, returning the normalized result."""
    updated = dict(cfg)
    last_key = None
    for key, value in pairs:
        key = KEY_ALIASES.get(key, key)
        if key not in DEFAULTS:
            raise ValueError(f"unknown setting: {key}")
        if key == "mode" and value not in MODES:
            raise ValueError(f"mode must be one of: {', '.join(MODES)}")
        if key == "sensor" and value not in SENSOR_IDS:
            raise ValueError(f"unknown sensor: {value} (see `fanctl sensors`)")
        if key in LIMITS:
            try:
                float(value)
            except ValueError:
                raise ValueError(f"{key} needs a number, got {value!r}") from None
        updated[key] = value
        last_key = key
    return normalize_config(updated, prefer=last_key)


# ------------------------------------------------------------------- hardware

def find_hwmon(name: str, root: Path = HWMON_ROOT):
    try:
        entries = sorted(root.iterdir())
    except OSError:
        return None
    for entry in entries:
        try:
            if (entry / "name").read_text().strip() == name:
                return entry
        except OSError:
            continue
    return None


def read_int(path: Path):
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def write_value(path: Path, value) -> bool:
    try:
        path.write_text(f"{int(value)}\n")
        return True
    except OSError:
        return False


class Sensors:
    """Maps sensor ids to their sysfs temp*_input files, rediscovered on demand."""

    def __init__(self, root: Path = HWMON_ROOT):
        self.root = root
        self.paths: dict[str, Path] = {}
        self.discover()

    def discover(self):
        devices = {}
        paths = {}
        for sensor in SENSORS:
            source = sensor["source"]
            if source not in devices:
                devices[source] = find_hwmon(source, self.root)
            device = devices[source]
            if device is None:
                continue
            for label_file in sorted(device.glob("temp*_label")):
                try:
                    label = label_file.read_text().strip()
                except OSError:
                    continue
                if label == sensor["label"]:
                    paths[sensor["id"]] = label_file.with_name(label_file.name.replace("_label", "_input"))
                    break
        self.paths = paths

    def read(self) -> dict:
        temps = {}
        for sensor_id, path in self.paths.items():
            millis = read_int(path)
            if millis is None:
                continue
            celsius = millis / 1000.0
            if celsius > SENSOR_INVALID_BELOW:
                temps[sensor_id] = celsius
        return temps


class Fan:
    """The single applesmc fan (fan1 / pwm1)."""

    def __init__(self, root: Path = HWMON_ROOT):
        self.root = root
        self.dir = None
        self.discover()

    def discover(self):
        self.dir = find_hwmon("applesmc", self.root)
        return self.dir is not None

    def _path(self, name):
        return self.dir / name if self.dir else None

    def read(self) -> dict:
        if not self.dir:
            return {}
        label = ""
        try:
            label = (self.dir / "fan1_label").read_text().strip()
        except OSError:
            pass
        return {
            "label": label or "Fan",
            "rpm": read_int(self._path("fan1_input")),
            "target": read_int(self._path("fan1_target")),
            "min": read_int(self._path("fan1_min")),
            "max": read_int(self._path("fan1_max")),
            "manual": read_int(self._path("pwm1_enable")) == 1,
        }

    def set_manual(self, rpm) -> bool:
        if not self.dir:
            return False
        if read_int(self._path("pwm1_enable")) != 1:
            if not write_value(self._path("pwm1_enable"), 1):
                return False
        return write_value(self._path("fan1_target"), rpm)

    def release(self) -> bool:
        if not self.dir:
            return False
        if read_int(self._path("pwm1_enable")) == 2:
            return True
        return write_value(self._path("pwm1_enable"), 2)


# ----------------------------------------------------------------- controller

def curve_rpm(temp, ramp_start, full_blast, fan_min, fan_max):
    """Macs Fan Control's sensor-based curve: flat, then linear, then flat."""
    if temp <= ramp_start:
        return float(fan_min)
    if temp >= full_blast:
        return float(fan_max)
    fraction = (temp - ramp_start) / float(full_blast - ramp_start)
    return fan_min + fraction * (fan_max - fan_min)


def quantize(rpm, fan_min, fan_max):
    rpm = int(round(rpm / RPM_QUANTUM) * RPM_QUANTUM)
    return max(fan_min, min(fan_max, rpm))


@dataclass
class Decision:
    rpm: int | None          # None hands the fan back to the SMC
    reason: str              # curve | target | manual | full-blast | hard-limit | sensor-lost | system
    sensor: str = ""
    temp: float | None = None    # smoothed control temperature
    raw: float | None = None     # unsmoothed control temperature


@dataclass
class Controller:
    fan_min: int
    fan_max: int
    # PI gains for target mode: rpm per °C, and rpm per °C·s.
    kp: float = 220.0
    ki: float = 18.0
    deadband: float = 0.5
    # Slew limits keep the fan from surging: fast up, gentle down.
    rise_rpm_per_s: float = 900.0
    fall_rpm_per_s: float = 250.0
    # Smoothing time constants for the control temperature.
    rise_tau: float = 1.5
    fall_tau: float = 6.0

    smoothed: float | None = None
    smoothed_sensor: str = ""
    integral: float = 0.0
    output: float | None = None
    blasting: bool = False
    _mode: str = field(default="", repr=False)

    def reset(self):
        self.integral = 0.0
        self.output = None
        self.blasting = False

    def _smooth(self, sensor, raw, dt):
        if self.smoothed is None or self.smoothed_sensor != sensor:
            self.smoothed = raw
            self.smoothed_sensor = sensor
            return raw
        tau = self.rise_tau if raw > self.smoothed else self.fall_tau
        alpha = 1.0 - math.exp(-max(dt, 0.0) / tau)
        self.smoothed += alpha * (raw - self.smoothed)
        return self.smoothed

    def _slew(self, desired, dt, immediate=False):
        if self.output is None or immediate:
            self.output = desired
            return desired
        delta = desired - self.output
        limit = (self.rise_rpm_per_s if delta > 0 else self.fall_rpm_per_s) * max(dt, 0.0)
        self.output += max(-limit, min(limit, delta))
        return self.output

    def step(self, cfg: dict, temps: dict, dt: float) -> Decision:
        mode = cfg["mode"]
        if mode != self._mode:
            # Carry the current output across a mode switch so the fan glides
            # instead of jumping, but start the PI integral from where the fan is.
            if mode == "target" and self.output is not None:
                self.integral = max(0.0, self.output - self.fan_min)
            elif mode != "target":
                self.integral = 0.0
            self._mode = mode

        if mode == "system":
            self.reset()
            return Decision(rpm=None, reason="system")

        sensor = cfg["sensor"]
        raw = temps.get(sensor)
        if raw is None and sensor != "cpu":
            sensor, raw = "cpu", temps.get("cpu")
        if raw is None:
            self.output = float(self.fan_max)
            return Decision(rpm=self.fan_max, reason="sensor-lost", sensor=cfg["sensor"])

        temp = self._smooth(sensor, raw, dt)
        decision = Decision(rpm=None, reason=mode, sensor=sensor, temp=temp, raw=raw)

        cpu = temps.get("cpu")
        if cpu is not None and cpu >= HARD_LIMIT_C:
            self.output = float(self.fan_max)
            decision.rpm, decision.reason = self.fan_max, "hard-limit"
            return decision

        if temp >= cfg["fullBlast"]:
            self.blasting = True
        elif temp < cfg["fullBlast"] - BLAST_HYSTERESIS_C:
            self.blasting = False
        if self.blasting:
            self._slew(self.fan_max, dt, immediate=True)
            decision.rpm, decision.reason = self.fan_max, "full-blast"
            return decision

        if mode == "auto":
            desired = curve_rpm(temp, cfg["rampStart"], cfg["fullBlast"], self.fan_min, self.fan_max)
            decision.reason = "curve"
        elif mode == "manual":
            desired = float(cfg["manualRpm"])
        else:  # target
            error = temp - cfg["targetTemp"]
            if abs(error) < self.deadband:
                error = 0.0
            span = self.fan_max - self.fan_min
            proportional = self.kp * error
            candidate = self.integral + self.ki * error * dt
            out = candidate + proportional
            # Anti-windup: don't keep integrating in the direction the output
            # is already pinned against.
            pinned = (out > span and error > 0) or (out < 0 and error < 0)
            if not pinned:
                self.integral = max(0.0, min(span, candidate))
            desired = self.fan_min + self.integral + proportional

        desired = max(self.fan_min, min(self.fan_max, desired))
        decision.rpm = quantize(self._slew(desired, dt), self.fan_min, self.fan_max)
        return decision


# --------------------------------------------------------------------- daemon

class Daemon:
    def __init__(self, config_path=CONFIG_PATH, state_path=STATE_PATH, hwmon_root=HWMON_ROOT,
                 interval=1.0, clock=time.monotonic):
        self.config_path = Path(config_path)
        self.state_path = Path(state_path)
        self.fan = Fan(hwmon_root)
        self.sensors = Sensors(hwmon_root)
        self.interval = interval
        self.clock = clock
        self.config = load_config(self.config_path)
        self.config_mtime = self._config_mtime()
        info = self.fan.read()
        self.controller = Controller(fan_min=info.get("min") or 1200, fan_max=info.get("max") or 7200)
        self.last_written = None
        self.last_write_at = 0.0
        self.last_tick = None
        self.running = True

    def _config_mtime(self):
        try:
            return self.config_path.stat().st_mtime_ns
        except OSError:
            return None

    def reload_config_if_changed(self):
        mtime = self._config_mtime()
        if mtime != self.config_mtime:
            self.config_mtime = mtime
            self.config = load_config(self.config_path)

    def tick(self):
        now = self.clock()
        dt = self.interval if self.last_tick is None else now - self.last_tick
        self.last_tick = now
        self.reload_config_if_changed()

        if self.fan.dir is None and not self.fan.discover():
            self.publish(None, {}, {}, error="applesmc fan not found")
            return
        temps = self.sensors.read()
        if not temps:
            self.sensors.discover()
            temps = self.sensors.read()

        decision = self.controller.step(self.config, temps, dt)
        error = ""
        if decision.rpm is None:
            if not self.fan.release():
                error = "could not hand the fan back to the SMC"
            self.last_written = None
        else:
            stale = now - self.last_write_at >= REASSERT_SECONDS
            info = self.fan.read()
            if (decision.rpm != self.last_written or stale or not info.get("manual")
                    or info.get("target") is None or abs(info["target"] - decision.rpm) >= RPM_QUANTUM):
                if self.fan.set_manual(decision.rpm):
                    self.last_written = decision.rpm
                    self.last_write_at = now
                else:
                    error = "could not write the fan target (is the daemon running as root?)"

        self.publish(decision, temps, self.fan.read(), error=error)

    def publish(self, decision, temps, fan_info, error=""):
        control = None
        if decision is not None:
            control = {
                "sensor": decision.sensor,
                "temp": None if decision.temp is None else round(decision.temp, 1),
                "raw": None if decision.raw is None else round(decision.raw, 1),
                "rpm": decision.rpm,
                "reason": decision.reason,
            }
        state = {
            "version": 1,
            "time": time.time(),
            "interval": self.interval,
            "config": self.config,
            "fan": fan_info,
            "control": control,
            "sensors": [
                {"id": s["id"], "name": s["name"], "temp": round(temps[s["id"]], 1)}
                for s in SENSORS if s["id"] in temps
            ],
            "hardLimit": HARD_LIMIT_C,
            "error": error,
        }
        try:
            atomic_write_json(self.state_path, state, mode=0o644)
        except OSError as exc:
            print(f"fanctl: could not write state: {exc}", file=sys.stderr)

    def shutdown(self):
        self.fan.release()
        try:
            self.state_path.unlink()
        except OSError:
            pass

    def run(self):
        def stop(_signum, _frame):
            self.running = False

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            while self.running:
                started = self.clock()
                try:
                    self.tick()
                except Exception as exc:  # never leave the fan stuck on an exception
                    print(f"fanctl: tick failed: {exc!r}", file=sys.stderr)
                    self.fan.set_manual(self.controller.fan_max)
                    self.last_written = self.controller.fan_max
                remaining = self.interval - (self.clock() - started)
                if remaining > 0 and self.running:
                    time.sleep(remaining)
        finally:
            self.shutdown()


# ------------------------------------------------------------------------ CLI

USAGE = """usage: fanctl <command>

  status [--json]          show fan, mode and sensor readings
  sensors                  list sensor ids usable with `set sensor`
  mode <auto|target|manual|system>
  set <key> <value> ...    change settings, several pairs at once
                           keys: mode, sensor, manualRpm (rpm), targetTemp (target),
                                 rampStart (ramp), fullBlast (blast)
  config                   print the current config
  daemon                   run the control loop (root, systemd)
  release                  hand the fan back to Apple's SMC (root)
"""


def read_state(path: Path = STATE_PATH):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def describe(state) -> str:
    if not state:
        return "fan-control daemon is not running (sudo systemctl enable --now fan-control)"
    cfg = state.get("config", {})
    fan = state.get("fan", {})
    control = state.get("control") or {}
    lines = [
        f"mode     {cfg.get('mode')}  ({control.get('reason', '-')})",
        f"fan      {fan.get('rpm')} rpm  target {fan.get('target')}  range {fan.get('min')}-{fan.get('max')}"
        f"  {'manual' if fan.get('manual') else 'smc'}",
    ]
    if control.get("temp") is not None:
        lines.append(f"control  {SENSOR_NAMES.get(control.get('sensor'), control.get('sensor'))} "
                     f"{control['temp']:.1f}°C (raw {control.get('raw')})")
    lines.append(f"curve    ramp {cfg.get('rampStart')}°C → full blast {cfg.get('fullBlast')}°C"
                 f"   target {cfg.get('targetTemp')}°C   manual {cfg.get('manualRpm')} rpm")
    for sensor in state.get("sensors", []):
        marker = "*" if sensor["id"] == cfg.get("sensor") else " "
        lines.append(f"  {marker} {sensor['name']:<26}{sensor['temp']:6.1f}°C")
    if state.get("error"):
        lines.append(f"error    {state['error']}")
    age = time.time() - float(state.get("time", 0))
    if age > 5:
        lines.append(f"warning  state is {age:.0f}s old; is the daemon running?")
    return "\n".join(lines)


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help", "help"):
        print(USAGE, end="")
        return 0
    command, rest = args[0], args[1:]

    if command == "daemon":
        Daemon().run()
        return 0
    if command == "release":
        return 0 if Fan().release() else 1
    if command == "status":
        state = read_state()
        if "--json" in rest:
            print(json.dumps(state, indent=2))
        else:
            print(describe(state))
        return 0 if state else 1
    if command == "sensors":
        for sensor in SENSORS:
            print(f"{sensor['id']:<15}{sensor['name']}")
        return 0
    if command == "config":
        print(json.dumps(load_config(), indent=2, sort_keys=True))
        return 0
    if command in ("mode", "set"):
        pairs = [("mode", rest[0])] if command == "mode" and len(rest) == 1 else None
        if command == "set" and rest and len(rest) % 2 == 0:
            pairs = list(zip(rest[0::2], rest[1::2]))
        if not pairs:
            print(USAGE, end="", file=sys.stderr)
            return 2
        try:
            cfg = apply_changes(load_config(), pairs)
            atomic_write_json(CONFIG_PATH, cfg)
        except ValueError as exc:
            print(f"fanctl: {exc}", file=sys.stderr)
            return 2
        except OSError as exc:
            print(f"fanctl: cannot write {CONFIG_PATH}: {exc.strerror}", file=sys.stderr)
            return 1
        print(json.dumps(cfg, sort_keys=True))
        return 0

    print(USAGE, end="", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
