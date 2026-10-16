#!/bin/bash

# ToggleSwitch is a bare track and knob, so assistive technology only learns
# what it is from the name its caller gives it. An unnamed switch stays out of
# the accessibility tree instead of announcing an anonymous checkbox, and the
# accessible actions obey the same busy and enabled gates as a click.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if ! command -v quickshell >/dev/null 2>&1; then
  pass "quickshell not installed; skipping ToggleSwitch accessibility test"
  exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/home" "$stage/runtime"
chmod 700 "$stage/runtime"
ln -s "$ROOT/shell/Ui" "$stage/Ui"
ln -s "$ROOT/shell/Commons" "$stage/Commons"

cat > "$stage/shell.qml" <<'QML'
import QtQuick
import Quickshell
import qs.Ui

ShellRoot {
  id: test
  property bool failed: false
  property int namedToggles: 0
  property int busyToggles: 0
  property int disabledToggles: 0

  function check(ok, message) {
    if (ok) return
    failed = true
    console.log("RESULT fail " + message)
  }

  Item {
    ToggleSwitch { id: unnamed }
    ToggleSwitch { id: named; accessibleName: "Named switch"; onToggled: test.namedToggles++ }
    ToggleSwitch { id: rowOwned; accessibleName: "Row switch"; interactive: false }
    ToggleSwitch { id: busy; accessibleName: "Busy switch"; busy: true; onToggled: test.busyToggles++ }
    ToggleSwitch { id: disabled; accessibleName: "Disabled switch"; enabled: false; onToggled: test.disabledToggles++ }
  }

  Timer {
    running: true
    interval: 50
    onTriggered: test.run()
  }

  function run() {
    check(unnamed.Accessible.ignored, "an unnamed switch stays out of the accessibility tree")
    check(!named.Accessible.ignored, "a named switch is exposed")
    check(named.Accessible.name === "Named switch", "a named switch announces its caller's name")
    check(named.Accessible.role === Accessible.CheckBox && named.Accessible.checkable, "a named switch is a checkable control")
    check(!named.Accessible.checked, "a named switch exposes its off state")
    named.checked = true
    check(named.Accessible.checked, "a named switch exposes its on state")
    check(rowOwned.Accessible.ignored, "a switch whose row owns the click stays out of the tree")
    check(!busy.Accessible.ignored && !disabled.Accessible.ignored, "busy and disabled switches stay announced")

    named.Accessible.toggleAction()
    named.Accessible.pressAction()
    check(namedToggles === 2, "toggle and press actions toggle an idle switch")
    busy.Accessible.toggleAction()
    busy.Accessible.pressAction()
    check(busyToggles === 0, "accessible actions are swallowed while busy")
    disabled.Accessible.toggleAction()
    disabled.Accessible.pressAction()
    check(disabledToggles === 0, "accessible actions are swallowed while disabled")

    if (!failed) console.log("RESULT pass")
    Qt.quit()
  }
}
QML

# Offscreen with a scrubbed environment: nothing maps, nothing reaches the
# running desktop or session bus.
output=$(cd "$stage" && env -i \
  HOME="$stage/home" XDG_RUNTIME_DIR="$stage/runtime" PATH=/usr/bin \
  OMARCHY_PATH="$ROOT" QT_QPA_PLATFORM=offscreen \
  "$(command -v timeout)" 30 "$(command -v quickshell)" -p "$stage" --no-color 2>&1) || fail "ToggleSwitch accessibility fixture exits cleanly" "$output"
[[ $output == *"RESULT pass"* ]] || fail "ToggleSwitch accessibility assertions pass" "$output"
if grep -Eq 'RESULT fail|ReferenceError|TypeError|Unable to assign|Binding loop|Cannot assign' <<< "$output"; then
  fail "ToggleSwitch accessibility fixture has no QML errors" "$output"
fi
pass "ToggleSwitch names, hides unnamed and row-owned switches, and gates accessible actions on busy and enabled"
