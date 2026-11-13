<img src="assets/icon.svg" width="64" height="64" alt="">

# fan-control

Fan control for Omarchy on a **MacBookPro14,1** (13" 2017, Kaby Lake i5, one
`applesmc` fan, 1200–7200 rpm), in the spirit of Macs Fan Control.

![panel](docs/panel.png)

## Modes

| Mode | What the fan does |
|------|-------------------|
| **Auto** | Sensor-based curve: fan minimum until **Ramp up at**, then a straight line to maximum at **Full blast at**. |
| **Target** | Holds the chosen sensor at **Hold at** with a PI loop. |
| **Manual** | Constant speed. |
| **System** | Hands the fan back to Apple's SMC (the stock behaviour). |

**Full blast at** applies in Auto, Target and Manual: if the control sensor
crosses it, the fan goes to maximum until the sensor drops 3°C below it. In those
modes the CPU package reaching **95°C** also forces maximum, whichever sensor is
selected. If the sensor can't be read, the fan runs at maximum.

Click any sensor in the panel to make it the control sensor. The default is
CPU Package, smoothed so short spikes don't make the fan surge.

## How it fits together

```
plugin/  (Omarchy bar widget, symlinked into ~/.config/omarchy/plugins/dimef.fan-control)
   │  reads  /run/fan-control/state.json   (published every second)
   │  runs   fanctl set <key> <value> ...  (edits /etc/fan-control/config.json)
   ▼
fanctl daemon  (root, fan-control.service)
   writes pwm1_enable / fan1_target on the applesmc hwmon device
```

- `/etc/fan-control/` belongs to group `wheel` with mode 2775, so the bar can
  change settings without sudo. The daemon clamps and validates everything it reads.
- When the service stops for any reason, including a crash, `ExecStopPost`
  runs `fanctl release`, which hands the fan back to the SMC.
- The daemon re-asserts manual control if the SMC takes it back (e.g. after resume).

## Install

```bash
./install.sh            # sudo for the daemon, then links the plugin and adds it to the bar
./uninstall.sh [--purge]
```

## CLI

```bash
fanctl status                       # fan, mode, every sensor
fanctl mode auto|target|manual|system
fanctl set ramp 55 blast 85         # several settings at once
fanctl set target 70                # Target mode temperature
fanctl set rpm 3000                 # Manual mode speed
fanctl set sensor cpu-proximity     # see `fanctl sensors`
```

Keybinding-friendly IPC: `omarchy-shell dimef.fan-control toggle` and
`omarchy-shell dimef.fan-control mode manual`.

## Bar widget options

Show the temperature or RPM next to the icon:

```bash
omarchy bar set dimef.fan-control label temp   # or: rpm, none
```

Scrolling over the bar icon changes the speed in Manual mode and the target in
Target mode. The icon turns red during full blast.

## Development

```bash
python3 -m unittest discover -s tests   # daemon: config, curve, PI loop, fake sysfs
node --test tests/                      # panel model
sudo install -m755 daemon/fanctl.py /usr/local/bin/fanctl && sudo systemctl restart fan-control
omarchy-shell shell rescanPlugins       # reload the plugin after QML edits
```
