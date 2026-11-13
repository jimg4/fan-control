#!/usr/bin/env bash
# Stops and removes the fanctl root service (Apple's SMC takes the fan back),
# then removes the plugin. Pass --purge to also delete /etc/fan-control.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_id="dimef.fan-control"
link="$HOME/.config/omarchy/plugins/$plugin_id"

sudo "$repo/daemon/uninstall-system.sh" "$@"

if [[ -L $link ]]; then
  # A development clone linked in by install.sh.
  omarchy plugin disable "$plugin_id" 2>/dev/null || true
  rm "$link"
else
  echo "Now remove the plugin itself: omarchy plugin remove $plugin_id"
fi
