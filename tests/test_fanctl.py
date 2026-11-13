"""Tests for daemon/fanctl.py. Run: python3 -m unittest discover -s tests"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("fanctl", HERE.parent / "daemon" / "fanctl.py")
fanctl = importlib.util.module_from_spec(spec)
sys.modules["fanctl"] = fanctl
spec.loader.exec_module(fanctl)

FAN_MIN, FAN_MAX = 1200, 7200


def cfg(**overrides):
    return fanctl.normalize_config({**fanctl.DEFAULTS, **overrides})


def run(controller, config, temp, seconds, dt=1.0, extra=None):
    decision = None
    for _ in range(int(seconds / dt)):
        temps = {"cpu": temp, **(extra or {})}
        decision = controller.step(config, temps, dt)
    return decision


class ConfigTests(unittest.TestCase):
    def test_garbage_falls_back_to_defaults(self):
        self.assertEqual(fanctl.normalize_config("nope"), fanctl.DEFAULTS)
        self.assertEqual(fanctl.normalize_config({"mode": "turbo", "sensor": "../etc"})["mode"], "auto")

    def test_values_are_clamped(self):
        c = fanctl.normalize_config({"manualRpm": 99999, "targetTemp": -5, "fullBlast": "nan"})
        self.assertEqual(c["manualRpm"], 8000)
        self.assertEqual(c["targetTemp"], 45)
        self.assertEqual(c["fullBlast"], fanctl.DEFAULTS["fullBlast"])

    def test_raising_ramp_pushes_full_blast_up(self):
        c = fanctl.apply_changes(cfg(rampStart=55, fullBlast=85), [("ramp", "84")])
        self.assertEqual((c["rampStart"], c["fullBlast"]), (84, 89))

    def test_lowering_full_blast_pushes_ramp_down(self):
        c = fanctl.apply_changes(cfg(rampStart=55, fullBlast=85), [("blast", "50")])
        self.assertEqual((c["rampStart"], c["fullBlast"]), (45, 50))

    def test_ramp_at_ceiling_stays_valid(self):
        c = fanctl.apply_changes(cfg(), [("rampStart", "90"), ("fullBlast", "95")])
        self.assertEqual((c["rampStart"], c["fullBlast"]), (90, 95))
        c = fanctl.apply_changes(c, [("rampStart", "93")])
        self.assertGreaterEqual(c["fullBlast"] - c["rampStart"], fanctl.MIN_CURVE_SPAN)

    def test_rejects_unknown_keys_and_values(self):
        with self.assertRaises(ValueError):
            fanctl.apply_changes(cfg(), [("speed", "1")])
        with self.assertRaises(ValueError):
            fanctl.apply_changes(cfg(), [("mode", "fast")])
        with self.assertRaises(ValueError):
            fanctl.apply_changes(cfg(), [("sensor", "nope")])
        with self.assertRaises(ValueError):
            fanctl.apply_changes(cfg(), [("rpm", "fast")])

    def test_oversized_config_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"mode": "manual", "pad": "x" * 70000}))
            self.assertEqual(fanctl.load_config(path)["mode"], "auto")


class ConfigFileSafetyTests(unittest.TestCase):
    """config.json is writable by wheel; the root daemon must treat it as hostile."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.path = self.dir / "config.json"

    def tearDown(self):
        self.tmp.cleanup()

    def test_symlinked_config_is_not_followed(self):
        target = self.dir / "elsewhere.json"
        target.write_text(json.dumps({"mode": "manual"}))
        self.path.symlink_to(target)
        self.assertIsNone(fanctl.read_config(self.path))
        with self.assertRaises(OSError):
            fanctl.write_config(fanctl.normalize_config(None), self.path)
        self.assertEqual(json.loads(target.read_text()), {"mode": "manual"})

    def test_fifo_does_not_block(self):
        os.mkfifo(self.path)
        self.assertIsNone(fanctl.read_config(self.path))  # would hang without O_NONBLOCK
        with self.assertRaises(OSError):
            fanctl.write_config(fanctl.normalize_config(None), self.path)

    def test_write_config_rewrites_in_place(self):
        fanctl.write_config(fanctl.normalize_config({"mode": "manual", "manualRpm": 4000}), self.path)
        inode = self.path.stat().st_ino
        fanctl.write_config(fanctl.normalize_config({"mode": "target"}), self.path)
        self.assertEqual(self.path.stat().st_ino, inode)
        self.assertEqual(fanctl.read_config(self.path)["mode"], "target")

    def test_daemon_keeps_last_good_config_on_bad_read(self):
        root = self.dir / "hwmon"
        root.mkdir()
        FakeHwmon(root)
        fanctl.write_config(fanctl.normalize_config({"mode": "manual"}), self.path)
        daemon = fanctl.Daemon(self.path, self.dir / "state.json", root, clock=lambda: 0.0)
        self.assertEqual(daemon.config["mode"], "manual")
        self.path.write_text('{"mode": "sys')  # caught mid-write
        os.utime(self.path, ns=(1, 1))
        daemon.reload_config_if_changed()
        self.assertEqual(daemon.config["mode"], "manual")


class CurveTests(unittest.TestCase):
    def test_curve_shape(self):
        self.assertEqual(fanctl.curve_rpm(40, 55, 85, FAN_MIN, FAN_MAX), FAN_MIN)
        self.assertEqual(fanctl.curve_rpm(70, 55, 85, FAN_MIN, FAN_MAX), 4200)
        self.assertEqual(fanctl.curve_rpm(90, 55, 85, FAN_MIN, FAN_MAX), FAN_MAX)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.c = fanctl.Controller(fan_min=FAN_MIN, fan_max=FAN_MAX)

    def test_system_mode_releases(self):
        d = self.c.step(cfg(mode="system"), {"cpu": 99}, 1)
        self.assertIsNone(d.rpm)

    def test_auto_follows_curve_after_settling(self):
        d = run(self.c, cfg(mode="auto"), 70, 30)
        self.assertEqual(d.reason, "curve")
        self.assertEqual(d.rpm, 4200)

    def test_cool_auto_sits_at_minimum(self):
        self.assertEqual(run(self.c, cfg(mode="auto"), 45, 10).rpm, FAN_MIN)

    def test_manual_is_constant(self):
        self.assertEqual(run(self.c, cfg(mode="manual", manualRpm=3000), 60, 20).rpm, 3000)

    def test_manual_clamped_to_fan_range(self):
        self.assertEqual(run(self.c, cfg(mode="manual", manualRpm=1000), 60, 20).rpm, FAN_MIN)

    def test_full_blast_overrides_manual_with_hysteresis(self):
        config = cfg(mode="manual", manualRpm=2000, fullBlast=80, rampStart=60)
        d = run(self.c, config, 81, 5)
        self.assertEqual((d.rpm, d.reason), (FAN_MAX, "full-blast"))
        d = run(self.c, config, 78.5, 30)  # inside hysteresis band
        self.assertEqual(d.reason, "full-blast")
        d = run(self.c, config, 70, 30)
        self.assertEqual(d.reason, "manual")

    def test_hard_limit_applies_whatever_the_sensor(self):
        config = cfg(mode="manual", manualRpm=2000, sensor="palm-rest")
        d = self.c.step(config, {"cpu": 96, "palm-rest": 30}, 1)
        self.assertEqual((d.rpm, d.reason), (FAN_MAX, "hard-limit"))

    def test_missing_sensor_falls_back_to_cpu_then_full_speed(self):
        d = self.c.step(cfg(sensor="ssd"), {"cpu": 50}, 1)
        self.assertEqual(d.sensor, "cpu")
        d = self.c.step(cfg(sensor="ssd"), {}, 1)
        self.assertEqual((d.rpm, d.reason), (FAN_MAX, "sensor-lost"))

    def test_slew_limits_ramp_down(self):
        config = cfg(mode="manual", manualRpm=7000)
        run(self.c, config, 50, 10)
        d = self.c.step(cfg(mode="manual", manualRpm=1200), {"cpu": 50}, 1)
        self.assertGreater(d.rpm, 6000)

    def test_target_raises_fan_when_hot_and_lowers_when_cool(self):
        config = cfg(mode="target", targetTemp=70)
        hot = run(self.c, config, 80, 20).rpm
        self.assertGreater(hot, 4000)
        cool = run(self.c, config, 60, 120).rpm
        self.assertEqual(cool, FAN_MIN)

    def test_target_converges_on_simple_plant(self):
        # Toy thermal model: heat input pushes temperature up, fan speed pulls
        # it toward ambient. At 1200 rpm it settles ~88°C, at 7200 rpm ~58°C.
        config = cfg(mode="target", targetTemp=72, fullBlast=95, rampStart=60)
        temp, ambient = 85.0, 30.0
        history = []
        for _ in range(900):
            d = self.c.step(config, {"cpu": temp}, 1.0)
            rpm = d.rpm
            cooling = 0.02 + 0.06 * (rpm - FAN_MIN) / (FAN_MAX - FAN_MIN)
            temp += 1.2 - cooling * (temp - ambient) * 0.75
            history.append(temp)
        tail = history[-120:]
        self.assertLess(abs(sum(tail) / len(tail) - 72), 1.0)
        self.assertLess(max(tail) - min(tail), 2.0)


class FakeHwmon:
    def __init__(self, root: Path):
        self.root = root
        self.smc = self._device("hwmon3", "applesmc")
        for name, value in {"fan1_input": 2400, "fan1_min": FAN_MIN, "fan1_max": FAN_MAX,
                            "fan1_target": 2400, "pwm1_enable": 2}.items():
            (self.smc / name).write_text(f"{value}\n")
        (self.smc / "fan1_label").write_text("Exhaust  \n")
        self._temp(self.smc, 1, "TC0P", 60000)
        self._temp(self.smc, 2, "TB0T", -127000)
        self.core = self._device("hwmon4", "coretemp")
        self._temp(self.core, 1, "Package id 0", 70000)

    def _device(self, name, kind):
        path = self.root / name
        path.mkdir()
        (path / "name").write_text(kind + "\n")
        return path

    def _temp(self, device, index, label, millis):
        (device / f"temp{index}_label").write_text(label + "\n")
        (device / f"temp{index}_input").write_text(f"{millis}\n")

    def set_cpu(self, celsius):
        (self.core / "temp1_input").write_text(f"{int(celsius * 1000)}\n")

    def read(self, name):
        return int((self.smc / name).read_text())


class DaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        (root / "hwmon").mkdir()
        self.hw = FakeHwmon(root / "hwmon")
        self.config = root / "etc" / "config.json"
        self.state = root / "run" / "state.json"
        self.now = [0.0]
        self.daemon = fanctl.Daemon(self.config, self.state, root / "hwmon", clock=lambda: self.now[0])

    def tearDown(self):
        self.tmp.cleanup()

    def tick(self, seconds=1):
        for _ in range(seconds):
            self.now[0] += 1
            self.daemon.tick()
        return json.loads(self.state.read_text())

    def write_config(self, **values):
        fanctl.atomic_write_json(self.config, fanctl.normalize_config({**fanctl.DEFAULTS, **values}))
        os.utime(self.config, ns=(int(self.now[0] * 1e9) + 1, int(self.now[0] * 1e9) + 1))

    def test_manual_mode_writes_target_and_enables_manual(self):
        self.write_config(mode="manual", manualRpm=3000)
        state = self.tick()
        self.assertEqual(self.hw.read("pwm1_enable"), 1)
        self.assertEqual(self.hw.read("fan1_target"), 3000)
        self.assertEqual(state["control"]["reason"], "manual")

    def test_state_lists_valid_sensors_only(self):
        state = self.tick()
        ids = [s["id"] for s in state["sensors"]]
        self.assertEqual(ids, ["cpu", "cpu-proximity"])  # battery reads -127 → hidden
        self.assertEqual(state["fan"]["label"], "Exhaust")

    def test_switching_to_system_hands_back(self):
        self.write_config(mode="manual")
        self.tick()
        self.write_config(mode="system")
        self.tick()
        self.assertEqual(self.hw.read("pwm1_enable"), 2)

    def test_reasserts_manual_if_smc_drops_it(self):
        self.write_config(mode="manual", manualRpm=3000)
        self.tick()
        (self.hw.smc / "pwm1_enable").write_text("2\n")  # e.g. after resume
        self.tick()
        self.assertEqual(self.hw.read("pwm1_enable"), 1)

    def test_shutdown_releases_fan_and_removes_state(self):
        self.write_config(mode="manual")
        self.tick()
        self.daemon.shutdown()
        self.assertEqual(self.hw.read("pwm1_enable"), 2)
        self.assertFalse(self.state.exists())

    def test_full_blast_from_cpu(self):
        self.write_config(mode="auto", rampStart=50, fullBlast=80)
        self.hw.set_cpu(82)
        state = self.tick()
        self.assertEqual(self.hw.read("fan1_target"), FAN_MAX)
        self.assertEqual(state["control"]["reason"], "full-blast")


if __name__ == "__main__":
    unittest.main()
