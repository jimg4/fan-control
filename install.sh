#!/usr/bin/env bash
# Installs the fanctl daemon (needs sudo) and links the Omarchy bar plugin.
# Usage: ./install.sh [--force]   (--force skips the MacBookPro14,1 check)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="dimef.fan-control"
plugin_dir="$HOME/.config/omarchy/plugins/$plugin_id"

if [[ $EUID -eq 0 ]]; then
  echo "Run install.sh as your user; it asks for sudo when it needs it." >&2
  exit 1
fi

sudo "$repo/daemon/install-system.sh" "$@"

mkdir -p "$(dirname "$plugin_dir")"
if [[ -e $plugin_dir && ! -L $plugin_dir ]]; then
  echo "$plugin_dir exists and is not a symlink; leaving it alone." >&2
  exit 1
fi
ln -sfn "$repo/plugin" "$plugin_dir"

# Put the widget where the old generic fan widget was, if it is in the bar.
if grep -q '"io.github.mittai17.fan-control"' "$HOME/.config/omarchy/shell.json" 2>/dev/null; then
  omarchy bar put "$plugin_id" --after io.github.mittai17.fan-control || true
  omarchy plugin disable io.github.mittai17.fan-control || true
else
  omarchy bar put "$plugin_id" --section right || true
fi

echo
echo "Installed. Click the fan in the bar, or run: omarchy-shell $plugin_id toggle"
