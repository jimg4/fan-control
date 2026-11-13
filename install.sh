#!/usr/bin/env bash
# Installs the fanctl root service (asks for sudo) and makes sure the bar
# plugin is available.
#
# Installed from the Omarchy plugin marketplace, this repository already is the
# plugin folder (~/.config/omarchy/plugins/dimef.fan-control). Run from a
# clone elsewhere, it links that clone into the plugin folder and adds the
# widget to the bar.
#
# Usage: ./install.sh [--force]   (--force skips the MacBookPro14,1 check)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
plugin_id="dimef.fan-control"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"

if [[ $EUID -eq 0 ]]; then
  echo "Run install.sh as your user; it asks for sudo when it needs it." >&2
  exit 1
fi

sudo "$repo/daemon/install-system.sh" "$@"

if [[ "$(cd "$plugin_dir" 2>/dev/null && pwd -P)" != "$repo" ]]; then
  if [[ -e $plugin_dir && ! -L $plugin_dir ]]; then
    echo "$plugin_dir already exists; leaving it alone." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$plugin_dir")"
  ln -sfn "$repo" "$plugin_dir"
  omarchy bar put "$plugin_id" --section right || true
fi

echo
echo "Installed. Click the fan in the bar, or run: omarchy-shell $plugin_id toggle"
