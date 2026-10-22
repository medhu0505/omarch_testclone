#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const search = requireFromRoot('shell/services/AppSearch.js')
const menuQml = fs.readFileSync(path.join(root, 'shell/plugins/menu/Menu.qml'), 'utf8')
const appLibraryQml = fs.readFileSync(path.join(root, 'shell/services/AppLibrary.qml'), 'utf8')

const entries = [
  {
    name: 'Google Contacts',
    genericName: 'Address Book',
    comment: 'Manage contacts',
    keywords: ['contacts', 'address book', 'people'],
    id: 'google-contacts.desktop'
  },
  {
    name: 'Calculator',
    genericName: 'Calculator',
    comment: 'Perform arithmetic, scientific or financial calculations',
    keywords: ['calculation', 'arithmetic', 'scientific', 'financial'],
    id: 'org.gnome.Calculator.desktop'
  },
  {
    name: 'OBS Studio',
    genericName: 'Streaming/Recording Software',
    comment: 'Free and Open Source Streaming/Recording Software',
    keywords: ['streaming', 'recording', 'capture'],
    id: 'com.obsproject.Studio.desktop'
  },
  {
    name: 'Aether',
    genericName: '',
    comment: 'Minimal internet radio player',
    keywords: ['audio', 'music', 'radio'],
    id: 'io.github.taqi.aether.desktop'
  },
  {
    name: 'Xournal++',
    genericName: 'Notetaking',
    comment: 'Take handwritten notes',
    keywords: ['notes', 'pdf', 'annotation'],
    id: 'com.github.xournalpp.xournalpp.desktop'
  },
  {
    name: 'RustDesk',
    genericName: 'Remote Desktop',
    comment: 'Remote desktop control',
    keywords: ['remote', 'desktop', 'control'],
    id: 'com.rustdesk.RustDesk.desktop'
  }
]

// Keep the packaged launcher when upstream rebuilds register their own entry.
const configuredHides = new Set(fs.readFileSync(path.join(root, 'default/omarchy/launcher.hides'), 'utf8').trim().split(/\n/))
const hermesEntries = [{ name: 'Hermes', id: 'hermes' }, { name: 'Hermes', id: 'hermes-desktop' }]
for (const query of ['', 'hermes']) {
  const visible = search.sortedEntries(hermesEntries, query, entry => configuredHides.has(entry.id))
  assertDeepEqual(visible.map(row => row.entry.id), ['hermes-desktop'], 'only the packaged Hermes launcher is visible')
}

const contactMatches = search.sortedEntries(entries, 'contact').map(row => search.entryName(row.entry))
assertDeepEqual(contactMatches, ['Google Contacts'], 'contact search only returns direct contact matches')

assert(
  search.fuzzyScore(entries[1], 'contact') < 0,
  'calculator does not match contact as a loose subsequence'
)

const acronymMatches = search.sortedEntries(entries, 'gc').map(row => search.entryName(row.entry))
assertEqual(acronymMatches[0], 'Google Contacts', 'short acronym matching still works')

const directMatches = search.sortedEntries(entries, 'obs').map(row => search.entryName(row.entry))
assertEqual(directMatches[0], 'OBS Studio', 'direct app-name matching still works')

// The menu's Apps submenu is the launcher now: app rows launch and uninstall
// through the shared app library instead of running commands themselves.
const activateMatch = menuQml.match(/function activateIndex\(index, fromPointer\) \{([\s\S]*?)\n  \}/)
assert(activateMatch, 'menu activateIndex function exists')
assert(
  activateMatch[1].includes('root.appLibrary.launch('),
  'menu routes app launch through the shared app library'
)
assert(
  !activateMatch[1].includes('entry.execute()'),
  'menu does not execute desktop entries directly'
)

const confirmDeleteMatch = menuQml.match(/function confirmDelete\(\) \{([\s\S]*?)\n  \}/)
assert(confirmDeleteMatch, 'menu confirmDelete function exists')
assert(
  confirmDeleteMatch[1].includes('root.appLibrary.remove('),
  'menu delete routes through the shared app library'
)
assert(
  confirmDeleteMatch[1].includes('root.cancel()'),
  'menu delete closes the menu after confirmation'
)

assert(
  /function remove\(desktopId, name\) \{[\s\S]*?omarchy-remove-launcher-entry[\s\S]*?\n  \}/.test(appLibraryQml),
  'app library remove runs the remover through the shell'
)

assert(
  /function launch\(desktopId, name\) \{[\s\S]*?uwsm-app[\s\S]*?\n  \}/.test(appLibraryQml) &&
    appLibraryQml.includes('Util.execDetached("uwsm-app -- gtk-launch "'),
  'app library launches desktop entries through gtk-launch in their own scope'
)

assert(
  appLibraryQml.includes('Util.shellQuote(id + ".desktop")'),
  'app library launches by full file name so ids ending in .desktop (org.telegram.desktop) resolve'
)

assert(
  /function iconIndexScanCommand\(\)[\s\S]*-path "\*\/apps\/\*" -o -path "\*\/devices\/\*"/.test(appLibraryQml),
  'app library fallback icon index includes device icons'
)

assert(
  appLibraryQml.includes('command: ["bash", "-c", root.hiddenEntryScanCommand()]') &&
    appLibraryQml.includes('command: ["bash", "-c", root.iconIndexScanCommand()]') &&
    !appLibraryQml.includes('"-lc"'),
  'app library scans avoid login shells whose profile activation retriggers the desktop-entry watcher'
)

assert(
  /if \(active === "apps"\) \{[\s\S]*?rows\.sort\(function\(a, b\)/.test(menuQml),
  'apps menu enforces alphabetical display order after provider refreshes'
)

const iconSourceMatch = appLibraryQml.match(/function iconSource\(icon\) \{([\s\S]*?)\n  \}/)
assert(iconSourceMatch, 'app library iconSource function exists')
assert(
  iconSourceMatch[1].indexOf('root.iconIndex[value]') < iconSourceMatch[1].indexOf('Quickshell.iconPath(value, true)'),
  'app library prefers indexed app icons over ambiguous themed icons'
)

const beginLaunchMatch = appLibraryQml.match(/function beginLaunchFeedback\(name\) \{([\s\S]*?)\n  \}/)
assert(beginLaunchMatch, 'app library beginLaunchFeedback function exists')
assert(
  !beginLaunchMatch[1].includes('root.launchOsdOpen = false'),
  'app library keeps owning an OSD a previous launch left on screen'
)

const openMatch = menuQml.match(/function openExistingMenu\(initialMenu\) \{([\s\S]*?)\n  \}/)
assert(openMatch, 'menu openExistingMenu function exists')
assert(
  openMatch[1].includes('root.appLibrary.refreshIcons()'),
  'menu refreshes the shared icon index when opened'
)
JS

if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell unavailable; skipping live launcher hide-list reload"
  exit 0
fi

run_node_test <<'JS'
const fs = require('fs')
const os = require('os')
const { spawnSync } = require('child_process')
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'app-hides-'))
process.on('exit', () => fs.rmSync(scratch, { recursive: true, force: true }))
fs.mkdirSync(path.join(scratch, 'default/omarchy'), { recursive: true })
fs.mkdirSync(path.join(scratch, 'runtime'), { mode: 0o700 })
fs.writeFileSync(path.join(scratch, 'default/omarchy/launcher.hides'), 'old-app.desktop\n')

// Use the real FileView cache and watcher with the library's own handlers.
const qml = fs.readFileSync(path.join(root, 'shell/services/AppLibrary.qml'), 'utf8')
const functions = ['normalizeDesktopId', 'loadConfiguredHides'].map(name =>
  qml.match(new RegExp('  function ' + name + '\\([^]*?\\n  }'))[0]).join('\n')
const watcher = qml.match(/  FileView \{[^]*?launcher\.hides[^]*?\n  }/)[0]
fs.writeFileSync(path.join(scratch, 'shell.qml'), `
import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property string omarchyPath: ${JSON.stringify(scratch)}
  property var configuredHiddenEntryIds: ({})
  property bool updating: false
  signal appsChanged()
  ${functions}
  ${watcher}
  onAppsChanged: {
    if (!updating && configuredHiddenEntryIds["old-app"]) {
      updating = true
      Qt.callLater(function() { writer.running = true })
    } else if (updating && configuredHiddenEntryIds["new-app"] && !configuredHiddenEntryIds["old-app"]) {
      console.log("APP_HIDES_RELOADED")
      Qt.quit()
    }
  }
  Process {
    id: writer
    command: ["bash", "-c", "printf 'new-app.desktop\\n' > \\\"$1\\\"", "_", root.omarchyPath + "/default/omarchy/launcher.hides"]
  }
  Timer {
    interval: 5000; running: true
    onTriggered: { console.log("STALE_HIDES", JSON.stringify(root.configuredHiddenEntryIds)); Qt.quit() }
  }
}
`)
const result = spawnSync('quickshell', ['-p', scratch, '--no-color'], {
  encoding: 'utf8', timeout: 10000,
  env: { ...process.env, HOME: scratch, XDG_RUNTIME_DIR: path.join(scratch, 'runtime'), WAYLAND_DISPLAY: '', QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: '', QT_QUICK_BACKEND: 'software' }
})
assert(result.status === 0 && (result.stdout + result.stderr).includes('APP_HIDES_RELOADED'),
  'editing launcher.hides replaces the cached hidden entries without restarting', result.stdout + result.stderr)
JS
