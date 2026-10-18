#!/bin/bash

# omarchy-menu-select and omarchy-menu-input wait for the menu's done file
# with no timeout. A summon that replaces a picker still waiting for its
# answer must answer it as canceled, or that caller never returns.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const menuQml = fs.readFileSync(path.join(root, 'shell/plugins/menu/Menu.qml'), 'utf8')
const source = ['openDmenu', 'openExistingMenu', 'finishRequest', 'answerRequest'].map(name => {
  const match = menuQml.match(new RegExp(`\\n  function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n  \\}`))
  assert(match, `menu ${name} function exists`)
  return match[0]
}).join('\n')

// The shipped request functions, with the menu's display stubbed and its
// request files recorded instead of written.
function menu() {
  const menu = {
    writes: [],
    requestActive: false, selectionFile: '', doneFile: '', requestSerial: 0, mode: 'menu', opened: false,
    dmenuPrompt: '', dmenuOptions: [], dmenuMultiple: false, dmenuOnChange: [], dmenuChangeKey: '',
    dmenuSelected: [], dmenuSaved: [], dmenuWidth: 0, dmenuMaxHeight: 0,
    activeMenu: 'root', navStack: [], filterText: '', selectedIndex: 0, cursorActive: true, appLibrary: null,
    Commons: { I18n: { t: key => key } },
    MenuModel: { dmenuSelections: () => [] },
    selectionProc: { requestedSelection: () => [] },
    filterInput: { forceActiveFocus() {} },
    Qt: { callLater() {} },
    item: () => true,
    disarmPointer() {},
    evaluateGuards() {},
    rebuildDisplay() {},
    invalidateVolatileProvider() {},
    loadProviderForMenu() {},
    readOptionsFile: file => (file.endsWith('unreadable') ? null : ['one', 'two']),
    requestFileExists: () => true,
    writeRequestFile(file, text) { this.writes.push(`${file} ${JSON.stringify(text)}`) },
  }
  menu.root = menu
  vm.createContext(menu)
  vm.runInContext(source, menu)
  return menu
}

const picker = (name, mode = 'select') => ({
  mode,
  prompt: name,
  optionsFile: mode === 'select' ? `/run/${name}.options` : undefined,
  selectionFile: `/run/${name}`,
  doneFile: `/run/${name}.done`,
})
const answered = m => m.writes.splice(0).join(', ')

const m = menu()
m.openDmenu(picker('first'))
assert(m.requestActive && m.doneFile === '/run/first.done' && !answered(m), 'a picker opens without answering anything')

m.openDmenu(picker('second'))
assertEqual(answered(m), '/run/first.done "\\n"', 'a picker opened over a waiting one answers it as canceled')
assert(m.requestActive && m.selectionFile === '/run/second' && m.doneFile === '/run/second.done', 'the new picker is the request the menu answers next')

m.openDmenu(picker('second'))
assertEqual(answered(m), '', 'the same picker delivered again is not answered')

m.openDmenu(Object.assign(picker('refused'), { optionsFile: '/run/unreadable' }))
assertEqual(answered(m), '/run/refused.done "\\n"', 'a picker whose rows cannot be read is refused without answering the one waiting')
assert(m.requestActive && m.doneFile === '/run/second.done', 'the waiting picker stays the request after a refused one')

m.openExistingMenu('root')
assertEqual(answered(m), '/run/second.done "\\n"', 'a menu summoned over a waiting picker answers it as canceled')
assert(!m.requestActive && m.selectionFile === '' && m.doneFile === '', 'the menu then holds no request')

m.openExistingMenu('root')
m.openDmenu(picker('typed', 'input'))
assertEqual(answered(m), '', 'opening over no waiting picker answers nothing')
JS
