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

const gameEntries = [
  { id: 'steam_app_1145360', name: 'Hades', categories: ['Game'] },
  { id: 'epic-celeste', name: 'Celeste', categories: ['Game', 'ActionGame'] },
  { id: 'super-mario-world', name: 'Super Mario World', categories: ['Game', 'Emulator'] },
  { id: 'steam', name: 'Steam', categories: ['Game', 'Network'] },
  { id: 'com.heroicgameslauncher.hgl', name: 'Heroic', categories: ['Game'] },
  { id: 'org.libretro.RetroArch.desktop', name: 'RetroArch', categories: ['Game', 'Emulator'] },
  { id: 'battlenet', name: 'Battle.net', categories: ['Game'] },
  { id: 'calculator', name: 'Calculator' },
  { id: 'hidden-game', name: 'Hidden game', categories: ['Game'] },
  { id: 'no-display', name: 'Invisible game', categories: ['Game'], noDisplay: true }
]
const hiddenGame = entry => entry.id === 'hidden-game'
let libraryEntries = gameEntries
let gameRefreshes = 0
const library = {
  sortedEntries: query => search.sortedEntries(libraryEntries, query, hiddenGame),
  entryName: search.entryName, entrySubtext: search.entrySubtext,
  refreshIcons() {},
  refreshGames() { gameRefreshes++ }
}
assertDeepEqual(library.sortedEntries('').filter(row => row.category === 'games').map(row => row.entry.name),
  ['Celeste', 'Hades', 'Super Mario World'], 'games include actual titles and ROM shortcuts while clients remain apps')
assertDeepEqual(library.sortedEntries('').filter(row => row.category === 'apps').map(row => row.entry.name),
  ['Battle.net', 'Calculator', 'Heroic', 'RetroArch', 'Steam'], 'apps keep ordinary tools and gaming clients')
assertEqual(search.entryCategory({ id: 'com.valvesoftware.Steam', categories: ['Game'] }), 'apps', 'Flatpak Steam stays in Apps')
assertEqual(search.entryCategory({ id: 'net.lutris.Lutris', categories: ['Game'] }), 'apps', 'Flatpak Lutris stays in Apps')
assertEqual(search.entryCategory({ id: 'game-tool', categories: ['GameUtility'] }), 'apps', 'category matching uses the exact Game category')

// Exercise the functions the live QML uses, with its view and focus objects stubbed.
const vm = require('vm')
function qmlFunction(source, name, context) {
  const match = source.match(new RegExp('  function ' + name + '\\([^)]*\\) \\{([\\s\\S]*?)\\n  \\}'))
  assert(match, name + ' exists in QML')
  return vm.runInNewContext('(' + match[0].trim() + ')', context)
}
const gridQml = fs.readFileSync(path.join(root, 'shell/plugins/dock/AppGrid.qml'), 'utf8')
const gridRoot = { appLibrary: library, category: 'apps', apps: [], appsStale: true, opened: false, filterText: '', dragging: false }
const gridContext = { root: gridRoot, grid: { positionViewAtBeginning() {} }, Qt: { callLater(callback) { callback() } }, keyCatcher: { forceActiveFocus() {} } }
for (const name of ['open', 'close', 'toggle', 'rebuild', 'setFilter', 'isImportedGame']) gridRoot[name] = qmlFunction(gridQml, name, gridContext)
assert(gridRoot.isImportedGame({ id: 'omarchy-game-abcdef' }) && !gridRoot.isImportedGame({ id: 'steam' }), 'imported shortcuts use shortcut removal while clients keep uninstall')
gridRoot.open('games')
assertEqual(gameRefreshes, 1, 'opening Games discovers newly installed games')
assertDeepEqual(Array.from(gridRoot.apps, entry => entry.name), ['Celeste', 'Hades', 'Super Mario World'], 'Games opens the existing grid filtered to games')
gridRoot.setFilter('hades')
assertEqual(gridRoot.apps.length, 1, 'typing filters Games')
gridRoot.menuEntry = gameEntries[0]
gridRoot.toggle('apps')
assertEqual(gameRefreshes, 1, 'opening Apps does not scan game libraries')
assert(gridRoot.opened && gridRoot.category === 'apps' && gridRoot.filterText === '' && !gridRoot.menuEntry, 'switching category clears query and context menu while keeping the grid open')
assert(!gridRoot.apps.some(entry => entry.name === 'Hades'), 'Hades is absent from Apps')
gridRoot.toggle('apps')
assert(!gridRoot.opened, 'toggling the current category closes the grid')
gridRoot.open('games')
gridRoot.close()
gridRoot.open()
assertEqual(gridRoot.category, 'apps', 'the dock Apps button returns to Apps after Games')

// A client shortcut can arrive after a generated game has already been pinned.
const imported = { id: 'omarchy-game-old-pin', name: 'Hades', categories: ['Game'], command: ['xdg-open', 'steam://rungameid/1145360'] }
const native = { id: 'Hades', name: 'Hades', categories: ['Game'], command: ['steam', '-applaunch', '1145360'] }
for (const noDisplay of [false, true]) {
  imported.noDisplay = noDisplay
  for (const query of ['', 'hades']) {
    assertDeepEqual(search.sortedEntries([imported, native], query).map(row => row.entry.id), ['Hades'], 'native and imported shortcuts produce one game result even before the asynchronous import completes')
  }
}
assertDeepEqual(search.sortedEntries([imported, { ...native, noDisplay: true }], '').map(row => row.entry.id), [], 'a hidden client shortcut does not expose the imported alias')
assertEqual(search.gameIdentity({ command: ['xdg-open', 'heroic://launch?appName=Game%%2520+one&runner=gog'] }), 'heroic:gog:Game%20 one', 'Heroic identity preserves percent-encoded store IDs')
assertEqual(search.gameIdentity({ command: ['heroic', 'heroic://launch/gog/some%20game'] }), 'heroic:gog:some game', 'legacy Heroic shortcuts resolve to the same store identity')
assertEqual(search.gameIdentity({ execString: 'xdg-open "heroic://launch?appName=%invalid&runner=gog"' }), '', 'a malformed client URI cannot break the shared app list')
assertEqual(search.gameIdentity({ command: ['flatpak', 'run', 'com.valvesoftware.Steam', 'steam://run/1145360//'] }), 'steam:1145360', 'Flatpak Steam URLs share the same identity')
assertDeepEqual(search.gameAliases([native, { ...imported, command: ['xdg-open', 'steam://rungameid/999'] }]), {}, 'different game IDs are never deduplicated by title')

// Quickshell omits NoDisplay entries from applications.values, while byId still
// resolves them. Model that distinction instead of keeping aliases in the list.
const nativeById = id => [imported, native].find(entry => entry.id === id)
const canonicalLibrary = { clientGameIds: search.clientGameIds([native]) }
const canonicalContext = { root: canonicalLibrary, AppSearch: search, DesktopEntries: { byId: nativeById } }
canonicalLibrary.normalizeDesktopId = qmlFunction(appLibraryQml, 'normalizeDesktopId', canonicalContext)
canonicalLibrary.canonicalId = qmlFunction(appLibraryQml, 'canonicalId', canonicalContext)
assertEqual(canonicalLibrary.canonicalId('org.telegram.desktop'), 'org.telegram.desktop', 'canonical game resolution preserves ordinary IDs that legitimately end in .desktop')
assertEqual(search.gameAliases([imported, { ...native, id: 'Hades.desktop' }])[imported.id], 'Hades.desktop', 'native game IDs are preserved verbatim too')
const dockQml = fs.readFileSync(path.join(root, 'shell/plugins/dock/Dock.qml'), 'utf8')
const dockRoot = { appLibrary: canonicalLibrary, dockConfig: { pinned: [imported.id, native.id] }, defaultDockConfig: {} }
const dockContext = { root: dockRoot, DockModel: requireFromRoot('shell/plugins/dock/DockModel.js'), DesktopEntries: { heuristicLookup: () => imported, byId: nativeById } }
dockRoot.resolvePinnedIds = qmlFunction(dockQml, 'resolvePinnedIds', dockContext)
dockRoot.entryForAppId = qmlFunction(dockQml, 'entryForAppId', dockContext)
assertDeepEqual(Array.from(dockRoot.resolvePinnedIds()), ['Hades'], 'an old imported pin resolves to the client entry once, without rewriting the saved config')
assertEqual(dockRoot.entryForAppId('steam_app_1145360').id, 'Hades', 'running windows and migrated pins resolve to the same dock entry')
dockRoot.storedPinIds = qmlFunction(dockQml, 'storedPinIds', dockContext)
assertDeepEqual(Array.from(dockRoot.storedPinIds(['calculator', 'Hades'])), ['calculator', imported.id], 'changing another pin or the dock order keeps the original game ID in saved settings')
canonicalLibrary.clientGameIds = search.clientGameIds([imported])
dockRoot.dockConfig.pinned = [imported.id]
assertDeepEqual(Array.from(dockRoot.resolvePinnedIds()), [imported.id], 'when the client entry disappears the original imported pin still resolves')
canonicalLibrary.clientGameIds = search.clientGameIds([native])
let savedPins = null
dockRoot.pinnedKeys = dockRoot.resolvePinnedIds()
dockRoot.savePins = pins => { savedPins = pins }
qmlFunction(dockQml, 'setPinned', dockContext)('Hades', false)
assertDeepEqual(Array.from(savedPins), [], 'unpinning the client entry removes the old alias pin too')

// Discovery is independent of icon refresh and runs once per relevant menu open.
let iconsRunning = false
let discoveryRunning = false
const refreshContext = {
  root: {},
  iconIndexScan: { get running() { return iconsRunning }, set running(value) { iconsRunning = value } },
  gameShortcutScan: { get running() { return discoveryRunning }, set running(value) { discoveryRunning = value } }
}
qmlFunction(appLibraryQml, 'refreshIcons', refreshContext)()
assert(iconsRunning && !discoveryRunning, 'opening an unrelated menu only refreshes icons')
qmlFunction(appLibraryQml, 'refreshGames', refreshContext)()
assert(discoveryRunning, 'game discovery starts only through its explicit refresh')
const refreshRoot = { appLibrary: library, opened: true, gamesRefreshed: false, activeMenu: 'system', itemOrder: [], item: id => ({ id }), providersLoaded: {} }
refreshRoot.refreshGamesOnce = qmlFunction(menuQml, 'refreshGamesOnce', { root: refreshRoot })
const refreshSearch = qmlFunction(menuQml, 'loadProvidersForSearch', { root: refreshRoot })
const beforeSearch = gameRefreshes
refreshSearch()
assertEqual(gameRefreshes, beforeSearch, 'search inside System does not import games')
refreshRoot.activeMenu = 'root'
refreshSearch()
refreshSearch()
assertEqual(gameRefreshes, beforeSearch + 1, 'typing a root search imports once rather than once per keystroke')
refreshRoot.gamesRefreshed = false
refreshRoot.opened = false
refreshSearch()
assertEqual(gameRefreshes, beforeSearch + 1, 'closed menus cannot trigger game import')

const menuModel = requireFromRoot('shell/plugins/menu/MenuModel.js')
const baseMenu = menuModel.mergeMenuSources(menuModel.parseMenuJsonc(fs.readFileSync(path.join(root, 'default/omarchy/omarchy-menu.jsonc'), 'utf8')), [])
const menuRoot = { appLibrary: library, items: baseMenu.items, itemOrder: baseMenu.itemOrder, opened: false }
const mergeApps = qmlFunction(menuQml, 'mergeAppRows', { root: menuRoot, MenuModel: menuModel })
mergeApps()
mergeApps()
const hadesId = 'apps.steam_app_1145360'
assertEqual(menuRoot.items[hadesId].parent, 'games', 'the canonical game row belongs only to Games')
assertEqual(menuRoot.itemOrder.filter(id => menuRoot.items[id].appId === 'steam_app_1145360').length, 1, 'provider reloads keep a single Hades result')
assert(menuModel.isDescendantOf(menuRoot.items, hadesId, 'games') && !menuModel.isDescendantOf(menuRoot.items, hadesId, 'apps'), 'Apps search excludes game descendants')
assert(menuModel.isDescendantOf(menuRoot.items, hadesId, 'root') && menuModel.matchesQuery(menuRoot.items[hadesId], 'hades', true), 'root search still finds the game')
libraryEntries = gameEntries.filter(entry => entry.id !== 'steam_app_1145360')
mergeApps()
assert(!menuRoot.items[hadesId] && !menuRoot.itemOrder.includes(hadesId), 'uninstalled games disappear without stale menu rows')

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
  /if \(active === "apps" \|\| active === "games"\) \{[\s\S]*?rows\.sort\(function\(a, b\)/.test(menuQml),
  'apps and games menus enforce alphabetical display order after provider refreshes'
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
