#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// The fingerprint PAM stays armed for the whole lock waiting for a finger, so
// `authenticating` is true from lock until unlock on every machine with a
// reader enrolled. Gating the blank on it leaves the panel lit all night.
assert(
  /if \(root\.lockRequested && !root\.authenticatingPassword\) root\.runBlank\(\)/.test(serviceQml),
  'only a password check in flight stops the blank timer from blanking'
)

assert(
  !/idleBlankTimer[\s\S]*?!root\.authenticating\)/.test(serviceQml),
  'the blank timer never gates on the combined authenticating state'
)

assert(
  /onAuthenticatingPasswordChanged: \{\s*if \(!lockRequested\) return\s*if \(authenticatingPassword\) idleBlankTimer\.stop\(\)\s*else armBlankTimer\(\)/.test(serviceQml),
  'the blank timer is held off by password entry and re-armed when it finishes'
)

assert(
  !/onAuthenticatingChanged:/.test(serviceQml),
  'the combined authenticating state no longer drives the blank timer'
)

function bodyOf(name) {
  const m = serviceQml.match(new RegExp(`\\n  function ${name}\\([^)]*\\) \\{([\\s\\S]*?)\\n  \\}`))
  return m ? m[1] : ''
}

// Nobody can touch the sensor once the panel is dark, so the reader is not
// polled through the blank: the PAM conversation is dropped, an attempt in
// flight included, and the retry timer stopped until the display comes back.
assert(
  /suspendFingerprint\(\)/.test(bodyOf('runBlank')),
  'blanking the display suspends the fingerprint'
)

const suspend = bodyOf('suspendFingerprint')
assert(
  /fingerprintRetryTimer\.stop\(\)/.test(suspend) &&
    /fingerprintReachTimer\.stop\(\)/.test(suspend) &&
    /if \(fingerprintPam\.active\) fingerprintPam\.abort\(\)/.test(suspend) &&
    /fingerprintAuthenticating = false/.test(suspend),
  'suspending stops both timers and drops the attempt in flight'
)

assert(
  !/settleFingerprintAttempt/.test(suspend),
  'a suspended attempt is not settled into the miss streak'
)

assert(
  /^\s*if \(fingerprintSuspended\) return/.test(bodyOf('startFingerprint')),
  'the fingerprint prompt does not start while suspended'
)

assert(
  /if \(!lockRequested \|\| !fingerprintConfigured \|\| fingerprintSuspended\) return/.test(bodyOf('settleFingerprintAttempt')),
  'a late completion does not re-arm the retry timer while suspended'
)

// Every route the panel can come back by re-arms the reader.
assert(
  /if \(lockRequested && fingerprintConfigured\) startFingerprint\(\)/.test(bodyOf('resumeFingerprint')),
  'resuming only re-arms a lock that still wants a fingerprint'
)

assert(
  /resumeFingerprint\(\)/.test(bodyOf('runWake')),
  'waking the display resumes the fingerprint'
)

const screens = serviceQml.match(/function onScreensChanged\(\) \{([\s\S]*?)\n    \}/)
assert(
  screens && /root\.resumeFingerprint\(\)/.test(screens[1]),
  'a panel coming back on its own resumes the fingerprint'
)

assert(
  /if \(fingerprintSuspended\) \{\s*resumeFingerprint\(\)\s*if \(lockRequested\) armBlankTimer\(\)\s*return\s*\}/.test(bodyOf('restartFingerprintAfterSleep')),
  'a resume that skips runWake re-arms the reader and the blank timer'
)

assert(
  /fingerprintSuspended = false/.test(bodyOf('resetAuthenticationState')),
  'a new lock starts with the fingerprint not suspended'
)
JS
