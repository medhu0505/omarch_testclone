#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3
require_compositor "GTK monitor positioning controls with a fake display service"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# Keep test state separate; the fake service never calls hyprctl or writes Lua.
env HOME="$scratch" XDG_CONFIG_HOME="$scratch/config" XDG_CACHE_HOME="$scratch/cache" \
  PYTHONDONTWRITEBYTECODE=1 timeout 30s python3 "$ROOT/test/shell.d/monitor-position-gui-checks.py"
pass "GTK monitor positioning remains responsive and recovers after Apply"
