#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const i18n = requireFromRoot('shell/Commons/I18nModel.js')

// 1. Locale code parsing
assertEqual(i18n.parseLocale("tr_TR.UTF-8"), "tr", "i18n parses tr_TR.UTF-8 to tr")
assertEqual(i18n.parseLocale("tr-TR"), "tr", "i18n parses tr-TR to tr")
assertEqual(i18n.parseLocale("tr"), "tr", "i18n parses tr to tr")
assertEqual(i18n.parseLocale("en_US.UTF-8"), "en", "i18n parses en_US.UTF-8 to en")
assertEqual(i18n.parseLocale(""), "en", "i18n defaults empty to en")
assertEqual(i18n.parseLocale(null), "en", "i18n defaults null to en")

// 2. Catalogs verification
const enPath = path.join(root, 'shell/locales/en.json')
const trPath = path.join(root, 'shell/locales/tr.json')

assert(fs.existsSync(enPath), "en.json locale exists")
assert(fs.existsSync(trPath), "tr.json locale exists")

const en = JSON.parse(fs.readFileSync(enPath, 'utf8'))
const tr = JSON.parse(fs.readFileSync(trPath, 'utf8'))

const catalogs = { en: en, tr: tr }

// 3. Translation resolution
assertEqual(
  i18n.translate(catalogs, "tr", "power.battery", "Battery"),
  "Pil",
  "i18n translates power.battery to Turkish"
)

assertEqual(
  i18n.translate(catalogs, "en", "power.battery", "Battery"),
  "Battery",
  "i18n translates power.battery to English"
)

assertEqual(
  i18n.translate(catalogs, "tr", "menu.apply", "Apply"),
  "Uygula",
  "i18n translates menu.apply to Turkish"
)

assertEqual(
  i18n.translate(catalogs, "tr", "system.shutdown", "Shutdown"),
  "Bilgisayarı Kapat",
  "i18n translates system.shutdown to Turkish"
)

// 4. Fallback behaviour
assertEqual(
  i18n.translate(catalogs, "tr", "nonexistent.key", "Fallback Value"),
  "Fallback Value",
  "i18n returns fallback value on unknown keys"
)

// 5. QML Singleton existence and registration
const qmldir = fs.readFileSync(path.join(root, 'shell/Commons/qmldir'), 'utf8')
assert(/singleton I18n 1\.0 I18n\.qml/.test(qmldir), "qmldir registers I18n singleton")

const i18nQml = fs.readFileSync(path.join(root, 'shell/Commons/I18n.qml'), 'utf8')
assert(/loadCatalog\("tr"/.test(i18nQml), "I18n.qml loads tr catalog")
assert(/loadCatalog\("en"/.test(i18nQml), "I18n.qml loads en catalog")
JS
