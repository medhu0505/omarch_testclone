#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const read = name => fs.readFileSync(path.join(root, name), 'utf8')
const indicator = read('shell/plugins/bar/indicators/PasswordlessSudo.qml')
const widget = read('shell/plugins/bar/widgets/Indicators.qml')
const manifest = JSON.parse(read('shell/plugins/bar/widgets/Indicators.manifest.json'))
assert(widget.match(/defaultIndicatorEntries: \[ "PasswordlessSudo", "ScreenRecording"/), 'passwordless sudo is included in the default indicator tray')
assert(manifest.barWidget.schema.find(field => field.key === 'items').options.some(option => option.value === 'PasswordlessSudo'), 'passwordless sudo is configurable alongside Night Light')
assert(indicator.includes('useActiveColor: true') && indicator.includes('activeColor: Commons.Color.urgent'), 'active passwordless sudo uses the theme danger color')
assertEqual(indicator.match(/activeText: "([^"]+)"/)[1], indicator.match(/inactiveText: "([^"]+)"/)[1], 'sudo keeps the same icon in both states')
assert(!widget.includes('sudoHorizontal') && !widget.includes('sudoVertical'), 'sudo participates in the normal indicator blocks')
assert(!indicator.includes('visible:'), 'sudo uses the shared indicator visibility and hover behavior')
assert(indicator.includes('command: ["omarchy-sudo-passwordless", "--active"]'), 'indicator uses the noninteractive grant probe')
assert(indicator.includes('root.granted = exitCode === 0 && exitStatus === 0'), 'failed or interrupted probes do not claim an active grant')
const script = read('bin/omarchy-sudo-passwordless')
assert(!indicator.includes('Timer'), 'indicator does not poll the sudo probe')
assert(indicator.includes('function onRefreshRequested() { root.refresh() }'), 'indicator probes when the indicator host asks for a refresh')
assert(script.includes('/usr/bin/omarchy-shell -q omarchy.indicators refresh'), 'grant changes push an indicator refresh')
assert(/change_grant\(\) \{[\s\S]*?\/usr\/bin\/sudo "\$@" \|\| status=\$\?\n  refresh_indicator\n/.test(script), 'every privileged grant change refreshes the indicator, failed ones included')
assert(script.includes('change_grant -n -N -- "$INSTALLED_SELF" __disable "$uid"'), 'disabling refreshes the indicator')
assertEqual(script.split('change_grant -N -- "$INSTALLED_SELF" __enable "$uid" "$minutes"').length, 3, 'both enable paths refresh the indicator')
assert(!/\/usr\/bin\/sudo (-n )?-N -- "\$INSTALLED_SELF" __(enable|disable)/.test(script), 'no grant change bypasses the refresh')
assert(script.match(/show_enabled\(\) \{\n  schedule_expiry_refresh\n/), 'a timed grant schedules a refresh after expiry')
assert(script.includes('--on-calendar="@$((EPOCHSECONDS + 10#$minutes * 60 + 2))"') && script.includes('--timer-property=AccuracySec=1s'), 'expiry refresh follows the wall clock through suspend and fires just after the deadline')
assert(indicator.includes('command: ["omarchy-sudo-passwordless", "--disable"]'), 'active indicator revokes access through a background process')
assert(indicator.includes('if (root.granted) disableProc.running = true'), 'active click bypasses the terminal launcher')
assert(indicator.includes('root.indicatorHost.refresh()'), 'disabling access refreshes all indicator instances immediately')
const press = new Function('root', 'disableProc', indicator.match(/onPressed: function\(\) \{([\s\S]*?)\n  \}/)[1])
const launched = []
const button = { granted: true, bar: { run: command => launched.push(command) } }
const revoke = { running: false }
press(button, revoke)
assert(revoke.running && launched.length === 0, 'clicking active sudo starts background revocation without a terminal')
button.granted = false
press(button, revoke)
assert(launched.length === 0, 'repeat clicks during revocation cannot open the enable flow')
revoke.running = false
press(button, revoke)
assertDeepEqual(launched, ['omarchy-launch-floating-terminal-with-presentation omarchy-sudo-passwordless'], 'inactive click still opens interactive setup')
JS
