import QtQuick
import Quickshell
import qs.Commons

ShellRoot {
  id: root

  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  property var failures: []
  property int checks: 0

  Item { id: host }

  function check(condition, message) {
    checks += 1
    if (!condition) failures.push(message)
  }

  function child(service, matches, description) {
    var objects = service.data || []
    for (var i = 0; i < objects.length; i++) {
      if (matches(objects[i])) return objects[i]
    }
    throw new Error("Missing " + description)
  }

  function run() {
    var component = Qt.createComponent("file://" + rootPath + "/shell/plugins/lock/Service.qml", Component.PreferSynchronous)
    if (component.status !== Component.Ready) throw new Error(component.errorString())
    var service = component.createObject(host, { omarchyPath: rootPath })
    if (!service) throw new Error(component.errorString())
    var stabilize = null
    var pending = null

    try {
      stabilize = child(service, function(o) { return o.interval === 500 && o.repeat === false }, "stabilize timer")
      pending = child(service, function(o) { return o.interval === 100 && o.repeat === true }, "pending lock timer")
      var ipc = child(service, function(o) { return o.target === "lock" && typeof o.lock === "function" }, "lock IPC handler")

      // The state requestSessionLock leaves when Quickshell declines the lock:
      // the request stands, its retries are disarmed, and nothing is held.
      service.lockRequested = true
      service.passwordPamConfigured = true
      service.pendingSessionLock = false
      stabilize.stop()
      pending.stop()
      var status = JSON.parse(ipc.status())
      check(status.locked && !status.sessionLocked && !status.secure, "the declined lock still reads as locked")

      check(ipc.lock() === "ok", "lock() answers ok while it retries")
      check(service.pendingSessionLock, "lock() queues the declined lock again")
      check(stabilize.running && pending.running, "lock() rearms the session lock retries")

      // A request already in flight is left to finish rather than restarted.
      service.lastEvent = "in-flight"
      check(ipc.lock() === "ok", "lock() answers ok while a lock is in flight")
      check(service.lastEvent === "in-flight", "lock() leaves a lock in flight alone")
    } finally {
      service.lockRequested = false
      if (stabilize) stabilize.stop()
      if (pending) pending.stop()
      service.pendingSessionLock = false
      service.resetAuthenticationState()
      service.destroy()
    }
  }

  Timer {
    interval: 1
    running: true
    onTriggered: {
      try {
        root.run()
      } catch (error) {
        root.failures.push(String(error))
      }
      var payload = JSON.stringify({ ok: root.failures.length === 0, checks: root.checks, failures: root.failures })
      var quoted = "'" + payload.replace(/'/g, "'\\''") + "'"
      Quickshell.execDetached(["bash", "-c", "printf '%s' " + quoted + " > \"$1\"", "_", root.resultPath])
    }
  }
}
