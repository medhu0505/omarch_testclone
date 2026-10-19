import QtQuick

// Detached application-library capability for third-party menus. Callbacks
// expose the supported app-list operations without retaining AppLibrary or its
// ShellRoot parent in the plugin-visible object graph.
QtObject {
  required property string ownerPluginId
  property bool refreshingGames: false

  signal appsChanged()

  property var _entryName: null
  property var _entrySubtext: null
  property var _sortedEntries: null
  property var _iconSource: null
  property var _refreshIcons: null
  property var _refreshGames: null
  property var _canonicalId: null
  property var _launch: null
  property var _remove: null

  function entryName(entry) {
    return _entryName ? _entryName(entry) : ""
  }

  function entrySubtext(entry) {
    return _entrySubtext ? _entrySubtext(entry) : ""
  }

  function sortedEntries(query) {
    return _sortedEntries ? _sortedEntries(String(query || "")) : []
  }

  function iconSource(icon) {
    return _iconSource ? _iconSource(icon) : ""
  }

  function refreshIcons() {
    if (_refreshIcons) _refreshIcons()
  }

  function refreshGames() {
    if (_refreshGames) _refreshGames()
  }

  function canonicalId(desktopId) {
    var id = String(desktopId || "")
    return _canonicalId ? _canonicalId(id) : id
  }

  function launch(desktopId, name) {
    if (_launch) _launch(String(desktopId || ""), String(name || ""))
  }

  function remove(desktopId, name) {
    if (_remove) _remove(String(desktopId || ""), String(name || ""))
  }
}
