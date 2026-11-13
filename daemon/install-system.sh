#!/usr/bin/env bash
# System half of the install: the fanctl daemon, its service, and the config
# directory the bar plugin writes to. Run as root (install.sh calls it via sudo).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
force=0
[[ ${1:-} == "--force" ]] && force=1

if [[ $EUID -ne 0 ]]; then
  echo "install-system.sh must run as root" >&2
  exit 1
fi

model="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
if [[ $model != "MacBookPro14,1" && $force -eq 0 ]]; then
  echo "This is tuned for a MacBookPro14,1; this machine is '${model:-unknown}'. Re-run with --force to install anyway." >&2
  exit 1
fi

if [[ ! -d /sys/devices/platform/applesmc.768 ]]; then
  modprobe applesmc || true
fi

install -Dm755 "$here/fanctl.py" /usr/local/bin/fanctl
install -Dm644 "$here/fan-control.service" /etc/systemd/system/fan-control.service
install -Dm644 "$here/../README.md" /usr/local/share/doc/fan-control/README.md

# Members of wheel (who can sudo anyway) may change settings without a
# password; the daemon re-validates and clamps everything it reads.
install -d -m 2775 -o root -g wheel /etc/fan-control
if [[ ! -f /etc/fan-control/config.json ]]; then
  FANCTL_CONFIG=/etc/fan-control/config.json /usr/local/bin/fanctl mode auto >/dev/null
fi
chgrp wheel /etc/fan-control/config.json
chmod 0664 /etc/fan-control/config.json

systemctl daemon-reload
systemctl enable fan-control.service
systemctl restart fan-control.service

for _ in 1 2 3 4 5; do
  [[ -f /run/fan-control/state.json ]] && break
  sleep 1
done
/usr/local/bin/fanctl status
