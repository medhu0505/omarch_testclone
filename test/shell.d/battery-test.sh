#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const battery = requireFromRoot('shell/plugins/services/battery/BatteryModel.js')
const fs = require('fs')
const os = require('os')
const pathModule = require('path')
const vm = require('vm')
const { execFileSync, spawn } = require('child_process')
const discharging = 1

assertEqual(battery.batteryPercentage({ isPresent: true, percentage: 0.126 }), 13, 'battery rounds display percentage')
assertEqual(battery.batteryPercentage({ isPresent: false, percentage: 0.5 }), -1, 'battery reports missing battery')
assert(battery.isDischarging({ isPresent: true, state: discharging }, true, discharging), 'battery detects discharging state')
assert(!battery.isDischarging({ isPresent: true, state: discharging }, false, discharging), 'battery requires on-battery state')

assertDeepEqual(
  battery.shouldWarnLowBattery({ isPresent: true, percentage: 0.08, state: discharging }, true, discharging, 10, false),
  { level: 8, notify: true, notifiedLowBattery: true },
  'battery warns once under threshold'
)
assertDeepEqual(
  battery.shouldWarnLowBattery({ isPresent: true, percentage: 0.08, state: discharging }, true, discharging, 10, true),
  { level: 8, notify: false, notifiedLowBattery: true },
  'battery keeps low-battery notified state'
)
assertDeepEqual(
  battery.shouldWarnLowBattery({ isPresent: true, percentage: 0.4, state: discharging }, true, discharging, 10, true),
  { level: 40, notify: false, notifiedLowBattery: false },
  'battery clears notified state after recovery'
)

const reply = profile => JSON.stringify({ type: 's', data: profile })
assertEqual(battery.parseActiveProfile(reply('power-saver')), 'power-saver', 'battery parses the busctl profile reply')
assertEqual(battery.parseActiveProfile(''), '', 'battery reads a missing daemon as no profile')

// Walk the profile through a session on battery: a startup read, then change
// signals, with the lock video gated on power-saver.
let profile = battery.profileAfterRead('', reply('balanced'), 0, 0)
assert(!battery.isPowerSaverOnBattery(true, profile), 'battery keeps the video on balanced')
profile = 'power-saver'
assert(battery.isPowerSaverOnBattery(true, profile), 'battery stops the video when power-saver arrives on battery')
assert(!battery.isPowerSaverOnBattery(false, profile), 'battery ignores power-saver on AC')
profile = 'balanced'
assert(!battery.isPowerSaverOnBattery(true, profile), 'battery resumes the video when power-saver ends')

// A read that sampled balanced before a power-saver signal must not undo it.
const signalsAtStart = 3
profile = 'power-saver'
profile = battery.profileAfterRead(profile, reply('balanced'), signalsAtStart, signalsAtStart + 1)
assertEqual(profile, 'power-saver', 'battery drops a read made stale by a change signal')
assert(battery.isPowerSaverOnBattery(true, profile), 'battery keeps the video stopped after a stale read')
assertEqual(
  battery.profileAfterRead('balanced', reply('power-saver'), signalsAtStart, signalsAtStart),
  'power-saver',
  'battery takes a read no signal overtook'
)

async function testNotificationBoundary() {
  const fixture = fs.mkdtempSync(pathModule.join(os.tmpdir(), 'omarchy-battery-low-'))
  try {
    const notificationArgs = pathModule.join(fixture, 'notification-args')
    const hookArgs = pathModule.join(fixture, 'hook-args')
    const stub = (name, body) => {
      const file = pathModule.join(fixture, name)
      fs.writeFileSync(file, `#!/bin/bash\n${body}`)
      fs.chmodSync(file, 0o755)
    }
    stub('omarchy-notification-send', 'printf \'%s\\0\' "$@" >"$NOTIFICATION_ARGS"\nfor arg in "$@"; do\n  if [[ $arg == -p || $arg == --print-id ]]; then printf \'321\\n\'; exit 0; fi\ndone\n')
    stub('omarchy-i18n', 'case "$1" in\n  battery.lowTitle) printf \'Batterie fast leer\\n\' ;;\n  battery.lowBody) printf \'Akku bei %s Prozent\\n\' "$2" ;;\n  *) exit 2 ;;\nesac\n')
  stub('omarchy-hook', 'printf \'%s\\0\' "$@" >"$HOOK_ARGS"\nif [[ ${BLOCK_HOOK:-0} == 1 ]]; then\n  printf \'HOOK_STARTED\\n\' >&2\n  IFS= read -r _\nfi\n')
    const senderOutput = execFileSync(pathModule.join(root, 'bin/omarchy-battery-low'), ['8'], {
      env: {
        ...process.env,
        PATH: `${fixture}:${process.env.PATH}`,
        NOTIFICATION_ARGS: notificationArgs,
        HOOK_ARGS: hookArgs
      }
    })

    const args = fs.readFileSync(notificationArgs, 'utf8').split('\0').filter(Boolean)
    const valueAfter = flag => args[args.indexOf(flag) + 1]
    const appName = valueAfter('--app-name')
    const urgencyName = valueAfter('-u')
    const title = args[args.indexOf(urgencyName) + 1]
    const hook = fs.readFileSync(hookArgs, 'utf8').split('\0').filter(Boolean)
    assertEqual(appName, 'omarchy-battery-low', 'battery warning command sends its dedicated app identity')
    assertEqual(urgencyName, 'critical', 'battery warning command sends critical urgency')
    assertEqual(title, 'Batterie fast leer', 'battery warning command sends the localized title')
    assert(args.includes('-p') || args.includes('--print-id'), 'battery warning command requests the notification id')
    assertEqual(senderOutput.toString().trim(), '321', 'battery warning command prints the notification id before running its hook')
    assertDeepEqual(hook, ['battery-low', '8'], 'battery warning command runs its hook through the stub')

    const notifications = requireFromRoot('shell/plugins/notifications/NotificationLogic.js')
    const urgency = { low: 0, normal: 1, critical: 2 }[urgencyName]
    assert(notifications.shouldBypassDnd({ appName, urgency }, 2), 'captured battery warning identity and urgency bypass DND')
    assert(!notifications.shouldBypassDnd({ appName, urgency: 1 }, 2), 'captured battery warning identity remains silenced at normal urgency')

    const service = fs.readFileSync(pathModule.join(root, 'shell/plugins/notifications/Service.qml'), 'utf8')
    const dismissBody = /function dismissLowBattery\(\) \{([\s\S]*?)\n  \}/.exec(service)[1]
    const dismissed = []
    const popupModel = {
      count: 2,
      get(index) { return [
        { app: appName, summary: title },
        { app: 'chat', summary: title }
      ][index] }
    }
    vm.runInNewContext(`(function() { ${dismissBody} })()`, {
      popupModel,
      service: { dismissPopup(index) { dismissed.push(index) } }
    })
    assertDeepEqual(dismissed, [0], 'dismissal uses the captured sender and preserves another sender with the localized title')

    const batteryService = fs.readFileSync(pathModule.join(root, 'shell/plugins/services/battery/Service.qml'), 'utf8')
    const notificationService = fs.readFileSync(pathModule.join(root, 'shell/plugins/notifications/Service.qml'), 'utf8')
    const dismissWarningBody = /function dismissLowBatteryWarning\(\) \{([\s\S]*?)\n  \}/.exec(batteryService)[1]
    const readHandler = /stdout:\s*SplitParser\s*\{\s*onRead:\s*(Qt\.callLater\(root\.dismissLowBatteryWarning\))\s*\}/.exec(batteryService)[1]
    const notificationDismissBody = /function dismissLowBattery\(\) \{([\s\S]*?)\n  \}/.exec(notificationService)[1]
    assert(/Qt\.callLater\(function\(\) \{[\s\S]*?popupModel\.insert\(0, snapshot\)/.test(notificationService), 'notification popup insertion is deferred')
    const child = spawn(pathModule.join(root, 'bin/omarchy-battery-low'), ['8'], {
      env: {
        ...process.env,
        PATH: `${fixture}:${process.env.PATH}`,
        NOTIFICATION_ARGS: notificationArgs,
        HOOK_ARGS: hookArgs,
        BLOCK_HOOK: '1',
      }
    })
    let output = ''
    let hookOutput = ''
    let closeResult
    const closed = new Promise(resolve => child.once('close', (code, signal) => {
      closeResult = { code, signal }
      resolve(closeResult)
    }))
    const sendCompleted = new Promise(resolve => child.stdout.on('data', chunk => {
      output += chunk.toString()
      const line = output.split('\n').find(value => value === '321')
      if (line) resolve(line)
    }))
    const hookStarted = new Promise(resolve => child.stderr.on('data', chunk => {
      hookOutput += chunk.toString()
      if (hookOutput.includes('HOOK_STARTED\n')) resolve()
    }))
    const deferred = []
    const popupRows = []
    const dismissedRows = []
    const streamedPopupModel = {
      get count() { return popupRows.length },
      get(index) { return popupRows[index] }
    }
    const notificationContext = {
      popupModel: streamedPopupModel,
      service: { dismissPopup(index) { dismissedRows.push(index); popupRows.splice(index, 1) } }
    }
    const dismissLowBattery = vm.runInNewContext(`(function() { ${notificationDismissBody} })`, notificationContext)
    const batteryContext = {
      Qt: { callLater(callback) { deferred.push(callback) } },
      UPower: { onBattery: false },
      root: { notificationService: { dismissLowBattery } }
    }
    vm.runInNewContext(`root.dismissLowBatteryWarning = function() { ${dismissWarningBody} }`, batteryContext)
    let deferredBeforeInsert = false
    let dismissedWhileHookBlocked = false
    let unpluggedWarningPreserved = false
    try {
      let timeout
      await Promise.race([
        Promise.all([sendCompleted, hookStarted]),
        new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('timed out waiting for send and hook output')), 3000) })
      ])
      clearTimeout(timeout)
      deferred.push(() => popupRows.unshift({ app: appName, summary: title }))
      vm.runInNewContext(readHandler, batteryContext)
      deferredBeforeInsert = popupRows.length === 0 && deferred.length === 2
      deferred.shift()()
      deferred.shift()()
      dismissedWhileHookBlocked = dismissedRows.length === 1 && popupRows.length === 0 && child.exitCode === null && child.signalCode === null
      popupRows.push({ app: appName, summary: title })
      batteryContext.UPower.onBattery = true
      batteryContext.root.dismissLowBatteryWarning()
      unpluggedWarningPreserved = popupRows.length === 1 && dismissedRows.length === 1
    } finally {
      child.stdin.end('release\n')
      if (child.exitCode === null && child.signalCode === null) {
        let timeout
        await Promise.race([closed, new Promise(resolve => { timeout = setTimeout(resolve, 1000) })])
        clearTimeout(timeout)
        if (child.exitCode === null && child.signalCode === null) {
          child.kill('SIGKILL')
          await closed
        }
      }
    }
    assert(deferredBeforeInsert, 'streamed completion queues dismissal behind the deferred popup insertion')
    assert(dismissedWhileHookBlocked, 'notification send output dismisses while the battery hook remains blocked')
    assert(unpluggedWarningPreserved, 'unplugging before deferred dismissal preserves the warning')
    assertDeepEqual(closeResult, { code: 0, signal: null }, 'battery warning sender exits after the hook is released')
  } finally {
    fs.rmSync(fixture, { recursive: true, force: true })
  }
}

testNotificationBoundary().catch(error => {
  console.error(error)
  process.exitCode = 1
})
JS
