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

# The directory stays root-only so nobody else can create, replace or
# symlink files in it. Only config.json itself is writable by wheel (who can
# sudo anyway); the daemon opens it without following links and re-validates
# everything it reads.
conf_dir=/etc/fan-control
conf=$conf_dir/config.json
install -d -m 0755 -o root -g root "$conf_dir"
chown root:root "$conf_dir"
chmod 00755 "$conf_dir"  # 00 also clears a leftover setgid bit
rm -f "$conf_dir"/.tmp-*
if [[ -L $conf || ( -e $conf && ! -f $conf ) ]]; then
  echo "Replacing $conf: it is not a regular file." >&2
  rm -f "$conf"
fi
if [[ ! -f $conf ]]; then
  FANCTL_CONFIG=$conf /usr/local/bin/fanctl mode auto >/dev/null
fi
# -h and the regular-file check above keep these off any symlink target.
chown -h root:wheel "$conf"
chmod 0664 "$conf"

systemctl daemon-reload
systemctl enable fan-control.service
systemctl restart fan-control.service

for _ in 1 2 3 4 5; do
  [[ -f /run/fan-control/state.json ]] && break
  sleep 1
done
/usr/local/bin/fanctl status
