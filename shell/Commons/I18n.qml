pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "I18nModel.js" as I18nModel

QtObject {
  id: root

  readonly property string systemLang: Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "en"
  property string configuredLocale: ""
  readonly property string currentLocale: configuredLocale ? configuredLocale : I18nModel.parseLocale(systemLang)

  property var catalogs: ({})

  readonly property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"

  property FileView enLocaleFile: FileView {
    path: root.omarchyPath + "/shell/locales/en.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.loadCatalog("en", text())
  }

  property FileView trLocaleFile: FileView {
    path: root.omarchyPath + "/shell/locales/tr.json"
    watchChanges: false
    printErrors: false
    onLoaded: root.loadCatalog("tr", text())
  }

  function loadCatalog(localeCode, rawJson) {
    if (!rawJson) return
    try {
      var parsed = JSON.parse(rawJson)
      var next = Object.assign({}, root.catalogs)
      next[localeCode] = parsed
      root.catalogs = next
    } catch (e) {}
  }

  function t(key, fallback) {
    return I18nModel.translate(root.catalogs, root.currentLocale, key, fallback)
  }
}
