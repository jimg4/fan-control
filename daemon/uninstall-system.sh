#!/usr/bin/env bash
# Stops the daemon (which hands the fan back to the SMC) and removes it.
# Keeps /etc/fan-control unless --purge is given.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "uninstall-system.sh must run as root" >&2
  exit 1
fi

systemctl disable --now fan-control.service 2>/dev/null || true
/usr/local/bin/fanctl release 2>/dev/null || true
rm -f /etc/systemd/system/fan-control.service /usr/local/bin/fanctl
rm -rf /usr/local/share/doc/fan-control
systemctl daemon-reload
[[ ${1:-} == "--purge" ]] && rm -rf /etc/fan-control
echo "fan-control removed; Apple's SMC is in charge of the fan again."
