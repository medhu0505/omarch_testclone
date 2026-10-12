#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// A scan window that ends without a finger counts as a usable attempt, so with
// the panel blanked the reader re-arms every 250 ms for as long as the screen is
// off, self-heating the device into a thermal cutoff. Pause new scans while the
// display is blanked and re-arm on every route the panel can come back.
function bodyOf(name) {
  const m = serviceQml.match(new RegExp(`\\n  function ${name}\\(\\) \\{([\\s\\S]*?)\\n  \\}`))
  return m ? m[1] : ''
}

assert(
  /fingerprintRetryTimer\.stop\(\)/.test(bodyOf('runBlank')),
  'blanking the display stops the fingerprint retry loop'
)

assert(
  /if \(displaysBlank\) return/.test(bodyOf('startFingerprint')),
  'startFingerprint refuses to scan while the display is blanked'
)

// runWake() clears the flag for a normal wake; onScreensChanged() for a panel
// set change; restartFingerprintAfterSleep() for a resume that kept the same
// outputs and so never reached runWake().
assert(
  /root\.displaysBlank = false/.test(bodyOf('runWake')),
  'runWake clears the blank state'
)

const screens = serviceQml.match(/Connections \{\s*target: Quickshell\s*function onScreensChanged\(\) \{([\s\S]*?)\n    \}/)
assert(
  screens && /root\.displaysBlank = false/.test(screens[1]),
  'onScreensChanged clears the blank state'
)

assert(
  /root\.displaysBlank = false/.test(bodyOf('restartFingerprintAfterSleep')),
  'resume after sleep clears the blank state, so the reader re-arms without a keypress'
)

const handler = serviceQml.match(/\n  onDisplaysBlankChanged: \{([\s\S]*?)\n  \}/)
assert(
  handler && /if \(!displaysBlank && lockRequested && fingerprintConfigured && !authenticatingPassword\) startFingerprint\(\)/.test(handler[1]),
  'a falling displaysBlank re-arms scanning from the handler rather than on every input'
)
JS
