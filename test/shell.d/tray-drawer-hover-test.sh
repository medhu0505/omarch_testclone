#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell unavailable; skipping tray drawer hover checks"
  exit 0
fi

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cp "$SHELL_TEST_DIR/fixtures/tray-drawer-hover/shell.qml" "$fixture/shell.qml"
ln -s "$ROOT/shell/Commons" "$fixture/Commons"
ln -s "$ROOT/shell/Ui" "$fixture/Ui"
ln -s "$ROOT/shell/plugins/bar/widgets" "$fixture/widgets"

# Keep the session's no-animations setting out of the fixture (see
# tray-direction-test.sh); the slide under a resting pointer is what is tested.
mkdir -p "$fixture/bin"
printf '#!/bin/bash\nexit 1\n' >"$fixture/bin/hyprctl"
chmod +x "$fixture/bin/hyprctl"

# Real pointer delivery (QtTest TestEvent) into an offscreen window. On failure
# print only the fixture's own result lines, not Quickshell's launcher log.
PATH="$fixture/bin:$PATH" QT_QPA_PLATFORM=offscreen timeout 30 quickshell -p "$fixture" --no-color >"$fixture/log" 2>&1 || {
  rg 'FAIL:|Error:' "$fixture/log" >&2 || cat "$fixture/log" >&2
  fail "tray drawer hover runtime"
}
if ! rg -q 'PASS: tray drawer hover' "$fixture/log" || rg -q 'FAIL:|Error:' "$fixture/log"; then
  rg 'FAIL:|Error:' "$fixture/log" >&2 || cat "$fixture/log" >&2
  fail "the collapsed tray claims no drawer space and the drawer stays open while it slides"
fi
pass "the collapsed tray claims no drawer space and the drawer stays open while it slides"
