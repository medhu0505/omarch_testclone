#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const power = requireFromRoot('shell/plugins/panels/power/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/power/Panel.qml', 'utf8')
const states = { Charging: 1, Discharging: 2, FullyCharged: 3, PendingCharge: 4 }

assertEqual(power.selectProfileIndex(0, 1, ['balanced', 'performance']), 1, 'power advances profile selection')
assertEqual(power.selectProfileIndex(1, 1, ['balanced', 'performance']), 1, 'power clamps profile selection')

assertDeepEqual(power.parseKeyValue('time\t2:00\nenergy\t42\n'), { time: '2:00', energy: '42' }, 'power parses key-value output')
assertDeepEqual(
  power.parseProfiles('power-saver\t0\nbalanced\t1\nperformance\t0\n', 5),
  { profiles: ['power-saver', 'balanced', 'performance'], activeProfile: 'balanced', profileIndex: 2 },
  'power parses profile output and clamps selection'
)

assert(power.profileIcon('performance').length > 0, 'power maps profile icons')
assertEqual(power.batteryFraction({ isPresent: true, percentage: 1.5 }), 1, 'power clamps battery fraction')

assert(power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.PendingCharge }, false, states), 'power detects threshold by pending charge state')
assert(power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.Charging, changeRate: 0.1, timeToFull: 120 }, false, states), 'power detects threshold by stalled charging')
assert(!power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.Charging, changeRate: 1.0, timeToFull: 120 }, false, states), 'power does not flag active charging as threshold')
assert(!power.chargeThresholdActive({ isPresent: true, percentage: 0.5, state: states.Discharging }, false, states), 'power does not flag discharging as threshold')
assertEqual(power.modeLabel({ isPresent: true, percentage: 1, state: states.FullyCharged }, false, states), 'Fully charged', 'power labels full battery')
assertEqual(power.localizeReading('13.1W'), '13.1W', 'power keeps battery readings in English digits by default')
assertEqual(power.localizeReading('75-80%', function(v, d) { return '<' + v + '>' }), '<75>-<80>%', 'power localizes every number in a battery reading')
assertEqual(power.localizeReading('13.10W', function(v, d) { return v.toFixed(d).replace('.', ',') }), '13,10W', 'power keeps a reading\'s decimals when localizing')
assertEqual(power.localizeReading(undefined), '', 'power reads a missing battery field as empty')
assertEqual(power.modeLabel({ isPresent: true, percentage: 0.5, state: states.Discharging }, true, states), 'On battery', 'power labels battery mode')
assertEqual(power.modeLabel({ isPresent: true, percentage: 0.5, state: states.Discharging }, false, states), 'Charging', 'power treats external power as newer than stale discharging state')
assert(power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging }, false, states).length > 0, 'power maps battery icons')
assertEqual(
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Discharging }, false, states),
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging, changeRate: 1.0, timeToFull: 120 }, false, states),
  'power shows charging icon when external power is present before battery state refreshes'
)
assertEqual(
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging }, true, states),
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Discharging }, true, states),
  'power shows battery icon when unplugged before battery state refreshes'
)

assertEqual(power.barLabelMode(undefined, false), 'none', 'power shows no bar label by default')
assertEqual(power.barLabelMode(undefined, true), 'percentage', 'power keeps the percentage a showPercentage config shows')
assertEqual(power.barLabelMode('time', false), 'time', 'power reads the bar label setting')
assertEqual(power.barLabelMode('none', true), 'none', 'power prefers the bar label setting over showPercentage')
assertEqual(power.barLabelMode('bogus', false), 'none', 'power ignores an unknown bar label')
assertEqual(power.nextBarLabelMode('none'), 'percentage', 'power cycles from the icon to the percentage')
assertEqual(power.nextBarLabelMode('percentage'), 'time', 'power cycles from the percentage to the time')
assertEqual(power.nextBarLabelMode('time'), 'none', 'power cycles from the time back to the icon')
assertEqual(power.durationLabel(47 * 60), '47m', 'power writes a time under an hour in minutes')
assertEqual(power.durationLabel(2 * 3600), '2h', 'power writes a whole number of hours')
assertEqual(power.durationLabel(2 * 3600 + 47 * 60 + 20), '2h 47m', 'power writes hours and minutes, rounded to the minute')
assertEqual(power.durationLabel(0), '', 'power writes no time without an estimate')
assertEqual(power.durationLabel(10 * 60, function(key, english) { return key === 'power.durationMinutes' ? '%1 min' : english }, function(v) { return '<' + v + '>' }), '<10> min', 'power translates the time and its digits')
assertEqual(power.barLabel('none', 0.62, '2h 47m'), '', 'power shows no label in icon mode')
assertEqual(power.barLabel('percentage', 0.62, '2h 47m'), '62%', 'power shows only the percentage in percentage mode')
assertEqual(power.barLabel('time', 0.62, '2h 47m'), '62% · 2h 47m', 'power shows the percentage and the time in time mode')
assertEqual(power.barLabel('time', 1, ''), '100%', 'power falls back to the percentage without a time')

assert(/if \(b === Qt\.RightButton\) root\.cycleLabel\(\)/.test(panelSource), 'power right click cycles the bar label')
assert(/function setLabel\(mode\) \{\n\s*var next = Object\.assign\([^\n]+label: [^\n]+\)\n\s*delete next\.showPercentage[\s\S]*?updateEntryInline/.test(panelSource), 'power persists the bar label in place of showPercentage')
assert(/function togglePercentage\(\) \{\n\s*setLabel\(root\.labelMode === "none" \? "percentage" : "none"\)/.test(panelSource), 'power keeps togglePercentage as a percentage on/off switch')
assert(/function toggleTime\(\) \{\n\s*setLabel\(root\.labelMode === "time" \? "percentage" : "time"\)/.test(panelSource), 'power toggles the time beside the percentage')
// BarIconButton lays its label out before the icon; bar-icon-geometry-test.sh checks the order.
assert(/text: root\.batteryIcon\(\)\n\s*labelText: !vertical \? Model\.barLabel\(root\.labelMode, /.test(panelSource), 'power shows the bar label beside the battery icon')
assert(/timeToEmpty : d\.timeToFull/.test(panelSource), 'power reads the bar time live from UPower')
assert(/labelText === "" \? Style\.bar\.iconSlot\n\s*: root\.barTimeText === "" \? Style\.bar\.iconSlot \* 2\n\s*: Style\.bar\.iconSlot \+ labelMetrics\.advanceWidth/.test(panelSource), 'power widens the bar slot to the label only when the time shows')
assert(/openPanelIndicatorWidth:.*labelMode !== "none".*button\.glyphPaintedWidth : 0/.test(panelSource), 'power spans the open-panel mark across the painted label block')
assert(/IpcHandler[\s\S]*?function togglePercentage\(\) \{ root\.togglePercentage\(\) \}/.test(panelSource), 'power exposes togglePercentage over IPC')
assert(/function toggleTime\(\) \{ root\.toggleTime\(\) \}\n\s*function cycleLabel\(\) \{ root\.cycleLabel\(\) \}\n\s*function label\(\): string \{ return root\.labelMode \}/.test(panelSource), 'power exposes the bar label over IPC')
assert(/manageIpc: false/.test(panelSource), 'power owns its IPC handler so it can extend the target methods')
JS
