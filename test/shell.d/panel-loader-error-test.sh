#!/bin/bash

# Issue #15969: the panel plugin Loader's onStatusChanged handler reads the
# bare identifier `errorString`, which Loader does not expose in that scope.
# The ReferenceError aborts the handler before the diagnostic warning and
# shell.hide() run, so a failed panel plugin loads silently. The handler must
# read the loader explicitly (with a guard) so the error path completes.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const qml = fs.readFileSync(root + '/shell/shell.qml', 'utf8')

const blockStart = qml.indexOf('property Loader panelLoader: Loader {')
assert(blockStart !== -1, 'shell.qml declares the panel plugin Loader')

const handlerStart = qml.indexOf('onStatusChanged: {', blockStart)
assert(handlerStart !== -1 && handlerStart < blockStart + 3000, 'the panel Loader has an onStatusChanged handler')

// Brace-match the handler body so the extraction cannot swallow a sibling
// handler further down the file.
let depth = 0
let end = -1
for (let i = handlerStart + 'onStatusChanged:'.length; i < qml.length; i++) {
  if (qml[i] === '{') depth++
  else if (qml[i] === '}') {
    depth--
    if (depth === 0) { end = i; break }
  }
}
assert(end !== -1, 'the handler block closes')

const inner = qml.slice(qml.indexOf('{', handlerStart) + 1, end)
const handler = new Function('status', 'Loader', 'panelLoader', 'sourceComponent', 'panelEntry', 'console', 'shell', inner)

// Run the handler in Loader.Error state. `errorString` is deliberately NOT
// in scope: in QML the bare identifier resolves to nothing there.
const ERROR = 3

function run(panelLoader, sourceComponent) {
  const warns = []
  const hidden = []
  const fakeConsole = { warn: (...args) => warns.push(args.join(' ')) }
  const fakeShell = { hide: (id) => hidden.push(id) }
  let threw = null
  try {
    handler(ERROR, { Error: ERROR }, panelLoader, sourceComponent,
      { pluginId: 'io.example.panel' }, fakeConsole, fakeShell)
  } catch (err) {
    threw = err
  }
  return { threw, warns, hidden }
}

// A source-load failure where Loader.errorString() carries the diagnostic.
let result = run({ errorString: () => 'Type GalleryWidget unavailable' }, null)
assert(!result.threw, 'the error handler survives without a ReferenceError',
  result.threw && result.threw.stack)
assert(result.hidden.length === 1 && result.hidden[0] === 'io.example.panel',
  'a failed panel plugin is hidden after the error is reported')
assert(result.warns.length === 1 && result.warns[0].includes('io.example.panel'),
  'the warning names the failed plugin')
assert(result.warns.length === 1 && result.warns[0].includes('Type GalleryWidget unavailable'),
  'the warning carries the loader error detail')

// A component-level failure: no loader detail, sourceComponent.errorString().
result = run({}, { errorString: () => 'GalleryWorkspacePage is not a type' })
assert(!result.threw, 'the error handler survives when the loader has no errorString',
  result.threw && result.threw.stack)
assert(result.hidden.length === 1 && result.hidden[0] === 'io.example.panel',
  'a component-level failure still hides the panel')
assert(result.warns.length === 1 && result.warns[0].includes('GalleryWorkspacePage is not a type'),
  'the warning falls back to the component error detail')
JS
