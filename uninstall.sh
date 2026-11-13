#!/usr/bin/env bash
# Removes the bar plugin link and the daemon. Pass --purge to also delete
# /etc/fan-control.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="dimef.fan-control"

omarchy plugin disable "$plugin_id" 2>/dev/null || true
link="$HOME/.config/omarchy/plugins/$plugin_id"
[[ -L $link ]] && rm "$link"

sudo "$repo/daemon/uninstall-system.sh" "$@"
