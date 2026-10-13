#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell unavailable; skipping tray direction runtime checks"
  exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp "$SHELL_TEST_DIR/fixtures/tray-direction/shell.qml" "$fixture/shell.qml"
ln -s "$ROOT/shell/Commons" "$fixture/Commons"
ln -s "$ROOT/shell/Ui" "$fixture/Ui"
ln -s "$ROOT/shell/plugins/bar/widgets" "$fixture/widgets"

# Style reads `hyprctl getoption animations:enabled` to zero every duration in
# the no-animations mode. Keep the session's setting out of the fixture so the
# drawer animates and the intermediate frames are checked.
mkdir -p "$fixture/bin"
printf '#!/bin/bash\nexit 1\n' >"$fixture/bin/hyprctl"
chmod +x "$fixture/bin/hyprctl"

# Render the real Tray and its controls without touching the desktop shell.
PATH="$fixture/bin:$PATH" QT_QPA_PLATFORM=offscreen timeout 50 quickshell -p "$fixture" --no-color >"$fixture/log" 2>&1 || {
  rg 'FAIL:|Error:' "$fixture/log" >&2 || cat "$fixture/log" >&2
  fail "tray direction runtime"
}
if ! rg -q 'PASS: tray direction' "$fixture/log" || rg -q 'FAIL:|Error:' "$fixture/log"; then
  rg 'FAIL:|Error:' "$fixture/log" >&2 || cat "$fixture/log" >&2
  fail "tray direction runtime"
fi
pass "tray direction, collapsed footprint, stationary pins, and settings persistence"
