#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=""
QS_PID=""
GESTURE_LOG=""

cleanup() {
  if [[ -n $QS_PID ]] && kill -0 "$QS_PID" 2>/dev/null; then
    kill "$QS_PID" 2>/dev/null || true
    wait "$QS_PID" 2>/dev/null || true
  fi
  if [[ -n $TMPDIR && -d $TMPDIR ]]; then
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

# The gates the gestures-off mode is built on, checked everywhere first.
run_node_test <<'JS'
const fs = require('fs')

const barSource = fs.readFileSync(root + '/shell/plugins/bar/Bar.qml', 'utf8')
assert(/property bool editGestures: true/.test(barSource), 'the bar keeps its direct-edit gestures on by default')
assert(/editGestures = config\.editGestures !== false/.test(barSource), 'only an explicit false in shell.json turns the gestures off')
const gestureAreaSource = barSource.slice(barSource.indexOf('component CenterGestureArea'), barSource.indexOf('component ModuleList'))
assert(gestureAreaSource.includes('acceptedButtons: Qt.LeftButton') && gestureAreaSource.includes('enabled: root.editGestures'), 'the center gesture area goes idle with the gestures off')
assert(/canReorder: root\.editGestures &&/.test(barSource), 'widget reorder drags run only while the gestures are on')

const readmeSource = fs.readFileSync(root + '/shell/plugins/bar/README.md', 'utf8')
assert(/editGestures/.test(readmeSource), 'the bar README documents the gestures opt-out')

const manualSource = fs.readFileSync(root + '/manual/05-the-top-bar.md', 'utf8')
assert(/editGestures/.test(manualSource), 'the manual documents the gestures opt-out')
JS

require_compositor "bar gestures off test"

if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell not installed; skipping bar gestures off test"
  exit 0
fi

require_command jq

TMPDIR=$(mktemp -d)
result="$TMPDIR/result.json"
log="$TMPDIR/quickshell.log"
GESTURE_LOG="$TMPDIR/omarchy-bar-calls.log"
config_dir="$TMPDIR/bar-gestures-off"
mkdir -p "$config_dir" "$TMPDIR/home" "$TMPDIR/bin"
cp "$SHELL_TEST_DIR/fixtures/bar-gestures-off/shell.qml" "$config_dir/shell.qml"
ln -s "$ROOT/shell/Ui" "$config_dir/Ui"
ln -s "$ROOT/shell/Commons" "$config_dir/Commons"
# The bar syncs Hyprland's blur through omarchy-bar, and the double-click
# gesture cycles the background through it. Log every call; the runtime half
# counts "background cycle" lines against the gestures.
{
  echo '#!/bin/bash'
  echo 'echo "$*" >>"$OMARCHY_GESTURE_LOG"'
  echo 'exit 0'
} >"$TMPDIR/bin/omarchy-bar"
chmod +x "$TMPDIR/bin/omarchy-bar"

OMARCHY_PATH="$ROOT" \
OMARCHY_QML_TEST_RESULT="$result" \
OMARCHY_GESTURE_LOG="$GESTURE_LOG" \
HOME="$TMPDIR/home" \
XDG_CONFIG_HOME="$TMPDIR/home/.config" \
XDG_CACHE_HOME="$TMPDIR/home/.cache" \
XDG_STATE_HOME="$TMPDIR/home/.local/state" \
PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
  quickshell -p "$config_dir" --no-color >"$log" 2>&1 &
QS_PID=$!

for _ in {1..100}; do
  [[ -s $result ]] && break
  if ! kill -0 "$QS_PID" 2>/dev/null; then
    sed -n '1,160p' "$log" >&2
    fail "bar gestures off quickshell exited before writing result"
  fi
  sleep 0.1
done

[[ -s $result ]] || {
  sed -n '1,160p' "$log" >&2
  fail "bar gestures off test timed out"
}

if ! jq -e '.ok == true' "$result" >/dev/null; then
  printf 'bar gestures off result:\n' >&2
  jq . "$result" >&2
  printf 'bar gestures off log:\n' >&2
  sed -n '1,160p' "$log" >&2
  fail "the bar gestures respect bar.editGestures in shell.json"
fi
pass "the bar gestures respect bar.editGestures in shell.json"

# The off phase runs its double-click on empty space before the config write
# turns the gestures on, whose own double-click cycles once: so exactly one
# cycle call can be in the log.
count=$(grep -cx 'background cycle' "$GESTURE_LOG" || true)
if [[ $count != 1 ]]; then
  printf 'omarchy-bar calls (%s background cycles):\n' "$count" >&2
  cat "$GESTURE_LOG" >&2
  fail "exactly one background cycle: from the gestures-on double-click only"
fi
pass "a gestures-on double-click cycles the background, a gestures-off one doesn't"
