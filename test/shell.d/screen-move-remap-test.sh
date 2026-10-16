#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Quickshell forwards QScreen::geometryChanged to x, y, width and height alike,
# so a rotation, mode or scale change fires onXChanged/onYChanged even when the
# origin stays put. Remapping on each one flashed the bar and background and
# rebuilt the bar's widgets. The guard has to remember the last origin and
# pulse only when it actually moved.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/Ui/ScreenMoveRemap.qml', 'utf8')

assert(
  !/function on[XY]Changed\(\)\s*\{\s*settleTimer\.restart\(\)/.test(source),
  'a screen x or y signal does not restart the settle timer unconditionally'
)

const moved = source.match(/function originMoved\(\)\s*\{([^}]*)\}/)
assert(
  moved && /screen\.x === lastX && screen\.y === lastY/.test(moved[1]) &&
    moved[1].indexOf('return') !== -1 &&
    moved[1].indexOf('return') < moved[1].indexOf('settleTimer.restart()'),
  'an unchanged origin returns before the settle timer restarts'
)
assert(
  /function onXChanged\(\)\s*\{\s*root\.originMoved\(\)/.test(source) &&
    /function onYChanged\(\)\s*\{\s*root\.originMoved\(\)/.test(source),
  'both x and y signals go through the origin comparison'
)

assert(
  /function syncOrigin\(\)\s*\{[^}]*lastX = screen\.x[^}]*lastY = screen\.y/.test(source) &&
    /Component\.onCompleted: syncOrigin\(\)/.test(source) &&
    /onScreenChanged: syncOrigin\(\)/.test(source),
  'the remembered origin is seeded on completion and whenever the screen is re-pointed'
)
JS
