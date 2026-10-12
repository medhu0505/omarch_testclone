import QtQuick
import Quickshell

ShellRoot {
  id: test
  property var clipboard
  property int step: 0
  property bool preview: Quickshell.env("CLIPBOARD_PIN_PREVIEW") === "1"

  Item { id: host }

  function check(condition, message) {
    if (!condition) throw new Error(message)
  }

  function findItem(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var contents = item.children || []
    for (var i = 0; i < contents.length; i++) {
      var found = findItem(contents[i], name)
      if (found) return found
    }
    if (item.contentItem) {
      var content = findItem(item.contentItem, name)
      if (content) return content
    }
    var resources = item.resources || []
    for (var r = 0; r < resources.length; r++) {
      var resource = findItem(resources[r], name)
      if (resource) return resource
    }
    return null
  }

  function showSamples() {
    clipboard.loadHistory(JSON.stringify([
      { type: "text", text: "A recently copied item" },
      { type: "text", text: "npm run dev", pinned: true },
      { type: "text", text: "A useful note\nSaved across restarts", pinned: true },
      { type: "text", text: "Another clipboard entry" }
    ]))
    clipboard.saveHistory()
    clipboard.open("{}")
    if (preview) console.log("PREVIEW_READY")
    else screenshot.start()
  }

  Timer {
    interval: 150
    repeat: true
    running: true
    onTriggered: {
      try {
        if (test.step === 0) {
          var component = Qt.createComponent("Clipboard.qml")
          check(component.status === Component.Ready, component.errorString())
          test.clipboard = component.createObject(host)
          check(test.clipboard !== null, component.errorString())
        } else if (test.step === 1) {
          check(clipboard.historyReady, "history loads before pinning")
          clipboard.loadHistory('[{"type":"text","text":"old"}]')
          clipboard.open("{}")
          clipboard.togglePinDisplayIndex(0)
          check(clipboard.pinCount === 1, "UI action pins")
        } else if (test.step === 2) {
          clipboard.history = []
          clipboard.destroy()
          test.clipboard = Qt.createComponent("Clipboard.qml").createObject(host)
        } else if (test.step === 3) {
          check(clipboard.pinCount === 1, "a fresh plugin reloads the saved pin")
          clipboard.addClipboardEntry({type: "text", text: "recent"})
          clipboard.open("{}")
          var list = findItem(clipboard, "clipboardResults")
          check(list.model.get(0).pinned && list.model.get(0).historyIndex === 1, "UI pins come first with correct history indexes")
          clipboard.togglePinDisplayIndex(0)
          check(clipboard.pinCount === 0, "UI unpins")
        } else if (test.step === 4) {
          var result = clipboard.pinClipboardFile(Quickshell.env("CLIPBOARD_PIN_REQUEST"))
          check(result === "pinned" && clipboard.pinCount === 1, "file IPC pins a captured payload")
          check(clipboard.pinClipboardFile(Quickshell.env("CLIPBOARD_PIN_REQUEST")) === "already-pinned", "repeated IPC requests are idempotent")
          for (var i = 0; i < 9; i++) {
            clipboard.addClipboardEntry({type: "text", text: "pin " + i})
            clipboard.togglePinDisplayIndex(clipboard.pinCount)
          }
          check(clipboard.pinCount === 10, "UI permits ten pins")
          clipboard.addClipboardEntry({type: "text", text: "eleventh"})
          clipboard.togglePinDisplayIndex(10)
          check(clipboard.pinCount === 10 && clipboard.statusMessage.indexOf("Unpin") >= 0, "UI reports pin limit")
          clipboard.setFilter("eleventh")
          check(findItem(clipboard, "clipboardResults").model.count === 1, "search still finds ordinary entries")
        } else {
          running = false
          console.log("CLIPBOARD_PINS_QML_PASS")
          showSamples()
        }
        test.step++
      } catch (error) {
        console.error("CLIPBOARD_PINS_QML_FAIL: " + error)
        Qt.quit()
      }
    }
  }

  Timer {
    id: screenshot
    interval: 500
    onTriggered: {
      var card = findItem(clipboard, "clipboardCard")
      card.grabToImage(function(result) {
        if (!result.saveToFile(Quickshell.env("CLIPBOARD_PIN_SCREENSHOT")))
          console.error("CLIPBOARD_PINS_QML_FAIL: screenshot could not be saved")
        Qt.quit()
      })
    }
  }
}
