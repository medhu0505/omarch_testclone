import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  property var failures: []

  function fail(message) {
    failures.push(String(message))
  }

  function assertTrue(condition, message) {
    if (!condition) fail(message)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var payload = JSON.stringify({
      ok: failures.length === 0,
      failures: failures
    })

    if (resultPath) {
      Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
    }
  }

  Item { id: host; width: 800; height: 600 }

  TextMetrics {
    id: probe
    font.family: Style.font.family
  }

  Timer {
    interval: 1
    running: true
    repeat: false
    onTriggered: {
      try {
        var component = Qt.createComponent("file://" + root.rootPath + "/shell/plugins/lock/LockView.qml", Component.PreferSynchronous)
        if (component.status !== Component.Ready) {
          root.fail("LockView failed to load: " + component.errorString())
          return
        }

        var view = component.createObject(host, { width: 800, height: 600, loadBackground: false })
        if (!view) {
          root.fail("LockView failed to instantiate: " + component.errorString())
          return
        }

        var indicator = view.children ? findByObjectName(view, "fingerprintIndicator") : null
        root.assertTrue(indicator !== null, "fingerprint indicator exists in the lock view")

        if (indicator) {
          view.fingerprintConfigured = false
          root.assertTrue(!indicator.visible, "fingerprint indicator is hidden when no sensor is configured")

          view.fingerprintConfigured = true
          root.assertTrue(indicator.visible, "fingerprint indicator is shown when a sensor is configured")

          // The field reserves space for the icon so a long password can never
          // slide underneath it. The reserve must exceed the icon's own width
          // (leaving a gap), and the shrunk dots must fit the reserved-clear
          // area even at extreme lengths.
          root.assertTrue(view.fingerprintReserve > indicator.width,
            "reserved space exceeds the icon width, got reserve " + view.fingerprintReserve + " vs icon " + indicator.width)

          view.passwordText = "x".repeat(80)
          var clearWidth = view.fieldWidth - 2 * view.fingerprintReserve
          probe.font.pixelSize = Math.max(1, Math.floor(view.passwordDotFontSize * view.passwordDotScale))
          probe.font.letterSpacing = view.passwordDotLetterSpacing * view.passwordDotScale
          probe.text = "●".repeat(80)
          root.assertTrue(probe.advanceWidth <= clearWidth,
            "80 dots stay clear of the fingerprint icon, need " + probe.advanceWidth + "px of " + clearWidth)

          view.fingerprintConfigured = false
          root.assertTrue(view.fingerprintReserve === 0, "no space is reserved when no sensor is configured")

          // An unreachable reader must announce itself instead of silently
          // inviting touches that can never unlock.
          view.fingerprintConfigured = true
          var notice = findByObjectName(view, "fingerprintUnavailableNotice")
          root.assertTrue(notice !== null, "unavailable notice exists in the lock view")

          if (notice) {
            var workingGlyph = indicator.text
            root.assertTrue(!notice.visible, "notice stays hidden while the reader works")

            view.fingerprintUnavailable = true
            root.assertTrue(notice.visible, "notice appears when the reader is unavailable")
            root.assertTrue(indicator.visible, "icon stays visible when the reader is unavailable")
            root.assertTrue(indicator.text !== workingGlyph, "icon crosses out when the reader is unavailable")
            root.assertTrue(view.fingerprintReserve > 0, "space stays reserved for the crossed-out icon")

            view.fingerprintUnavailable = false
            root.assertTrue(!notice.visible, "notice clears when the reader recovers")
            root.assertTrue(indicator.text === workingGlyph, "icon restores when the reader recovers")
          }

          // A rejected finger must read differently from a reader that never
          // answered, so the user knows to try again rather than wait.
          var status = findByObjectName(view, "lockStatusText")
          root.assertTrue(status !== null, "status text exists in the lock view")

          if (status) {
            var idleColor = String(indicator.color)
            root.assertTrue(status.text === view.placeholderText, "status shows the placeholder before any touch")

            view.fingerprintRejected = true
            root.assertTrue(status.text === "Fingerprint not recognized", "status reports a rejected finger, got " + status.text)
            root.assertTrue(view.errorState, "a rejected finger puts the field in its error state")
            root.assertTrue(String(indicator.color) !== idleColor || String(Color.lock.textError) === String(Color.lock.placeholder),
              "icon tints when the finger is rejected")

            view.failureMessage = "Authentication failed (1)"
            root.assertTrue(status.text === "Authentication failed (1)", "a password failure outranks a rejected finger")
            view.failureMessage = ""

            view.fingerprintUnavailable = true
            root.assertTrue(status.text === view.placeholderText, "an unavailable reader does not also claim a rejected finger")
            view.fingerprintUnavailable = false

            view.fingerprintRejected = false
            root.assertTrue(status.text === view.placeholderText, "status returns to the placeholder once the rejection clears")
            root.assertTrue(!view.errorState, "the field leaves its error state once the rejection clears")
          }
        }

        view.destroy()
      } catch (error) {
        root.fail("lock fingerprint indicator fixture threw: " + error)
      } finally {
        root.writeResult()
      }
    }
  }

  function findByObjectName(node, name) {
    if (!node) return null
    if (node.objectName === name) return node
    var kids = node.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findByObjectName(kids[i], name)
      if (found) return found
    }
    return null
  }
}
