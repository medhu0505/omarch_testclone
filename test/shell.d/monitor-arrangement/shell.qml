import QtQuick
import Quickshell
import Quickshell.Io

// Real controls + real Python backend; only the compositor is simulated.
ShellRoot {
  id: root
  property int phase: 0
  property int ticks: 0
  property int beforeTicks: 0
  property var failures: []
  property var checks: []
  property bool finished: false
  readonly property var ui: controls.item
  readonly property var secondUi: secondControls.item
  readonly property string testDir: Quickshell.env("ARRANGEMENT_TEST_DIR")
  readonly property string resultPath: Quickshell.env("ARRANGEMENT_TEST_RESULT")

  function check(condition, message) {
    if (!condition) failures.push(message)
  }
  function child(name, item) {
    item = item || ui
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = child(name, item.children[i])
      if (found) return found
    }
    return null
  }
  function screen(name) {
    return ui.monitors.filter(function(m) { return m.name === name })[0]
  }
  function configure(values) {
    control.command = ["python3", testDir + "/fake-hyprctl.py", "--control", JSON.stringify(values)]
    control.running = true
  }
  function done(name) { checks.push(name) }
  function finish() {
    if (finished) return
    finished = true
    writer.command = ["python3", "-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2])",
                      resultPath, JSON.stringify({ok: failures.length === 0, checks: checks, failures: failures})]
    writer.running = true
  }

  Process { id: control }
  Process { id: writer; onExited: Qt.quit() }

  FloatingWindow {
    width: 400
    height: 650
    visible: true
    Loader {
      id: controls
      width: 380
      active: false
      source: "file://" + Quickshell.env("OMARCHY_PATH") + "/shell/plugins/panels/monitor/Arrangement.qml"
      onLoaded: { item.width = width; item.active = true }
    }
    Loader {
      id: secondControls
      width: 380
      active: false
      visible: false
      source: controls.source
      onLoaded: { item.width = width; item.active = true }
    }
  }

  Timer {
    interval: 20
    running: !root.finished
    repeat: true
    onTriggered: {
      root.ticks++
      if (root.ticks > 1500) { root.failures.push("Timed out in phase " + root.phase); root.finish(); return }
      if (control.running) return
      switch (root.phase) {
      case 0:
        root.configure({reset: true, delay: 0.6})
        root.phase++
        break
      case 1:
        controls.active = true
        root.beforeTicks = root.ticks
        root.phase++
        break
      case 2:
        if (!ui || ui.busy) return
        root.check(root.ticks - root.beforeTicks >= 15, "Delayed query leaves the event loop responsive")
        root.check(ui.monitors.length === 3 && !ui.canApply, "Startup loads three displays without applying")
        root.check(ui.moving === "DP-3" && ui.reference === "eDP-1", "Defaults choose distinct moving/reference screens")
        root.done("responsive startup")
        root.configure({delay: 0})
        root.phase++
        break
      case 3:
        root.child("arrangementLeft").clicked()
        root.phase++
        break
      case 4:
        if (ui.busy) return
        root.check(ui.canApply && ui.preview[2].x === -1920 && root.screen("DP-3").x === 3840, "Left previews without changing the displays")
        root.child("arrangementMoving").changed("DP-2")
        root.check(ui.moving === "DP-2" && !ui.canApply && ui.preview.length === 0, "Changing selection clears the preview")
        root.done("preview and selection")
        root.child("arrangementBelow").clicked()
        root.phase++
        break
      case 5:
        if (ui.busy) return
        root.check(ui.canApply, "Below preview can be applied")
        root.child("arrangementApply").clicked()
        root.check(ui.busy && !root.child("arrangementApply").enabled && !root.child("arrangementMoving").enabled, "Apply disables conflicting controls")
        root.phase++
        break
      case 6:
        if (ui.busy) return
        root.check(root.screen("DP-2").y === 1080 && ui.message.indexOf("Saved") >= 0 && !ui.canApply, "Apply saves and refreshes the actual layout")
        root.done("successful Apply")
        root.configure({reloadError: true})
        root.child("arrangementLeft").clicked()
        root.phase++
        break
      case 7:
        if (ui.busy) return
        root.child("arrangementApply").clicked()
        root.phase++
        break
      case 8:
        if (ui.busy) return
        root.check(ui.error && ui.message.indexOf("restored") >= 0 && !ui.canApply, "Failed Apply reports rollback and clears preview")
        root.child("arrangementRefresh").clicked()
        root.phase++
        break
      case 9:
        if (ui.busy) return
        root.check(root.screen("DP-2").y === 1080, "Rollback restored the saved display layout")
        root.child("arrangementLeft").clicked()
        root.phase++
        break
      case 10:
        if (ui.busy) return
        root.child("arrangementApply").clicked()
        root.phase++
        break
      case 11:
        if (ui.busy) return
        root.check(!ui.error && root.screen("DP-2").x === -1920, "Apply can be retried after rollback")
        root.done("rollback and retry")
        root.child("arrangementAbove").clicked()
        root.phase++
        break
      case 12:
        if (ui.busy) return
        root.configure({move: true})
        root.phase++
        break
      case 13:
        root.child("arrangementApply").clicked()
        root.phase++
        break
      case 14:
        if (ui.busy) return
        root.check(ui.error && ui.message.indexOf("changed since") >= 0 && !ui.canApply, "Apply rejects a stale preview")
        root.done("stale preview")
        root.configure({disconnect: true, delay: 0.5})
        root.phase++
        break
      case 15:
        root.child("arrangementRefresh").clicked()
        root.beforeTicks = root.ticks
        root.check(ui.busy && !ui.ready, "Refresh disables arrangement controls")
        root.phase++
        break
      case 16:
        if (ui.busy) return
        root.check(root.ticks - root.beforeTicks >= 10 && ui.monitors.length === 1 && !ui.ready && ui.preview.length === 0, "Delayed refresh handles a disconnected screen")
        root.done("responsive refresh and disconnection")
        root.configure({readError: true, delay: 0})
        root.phase++
        break
      case 17:
        root.child("arrangementRefresh").clicked()
        root.phase++
        break
      case 18:
        if (ui.busy) return
        root.check(ui.error && ui.monitors.length === 0 && !ui.canApply && root.child("arrangementRefresh").enabled, "Failed refresh leaves a usable retry control")
        root.configure({reset: true})
        root.phase++
        break
      case 19:
        root.child("arrangementRefresh").clicked()
        root.phase++
        break
      case 20:
        if (ui.busy) return
        root.check(!ui.error && ui.ready, "Refresh recovers after query failure")
        root.done("refresh recovery")
        root.configure({delay: 0.5})
        root.phase++
        break
      case 21:
        root.child("arrangementRefresh").clicked()
        ui.active = false
        root.check(ui.busy, "Closing does not block on an in-flight query")
        root.phase++
        break
      case 22:
        if (ui.busy) return
        ui.active = true
        root.phase++
        break
      case 23:
        if (ui.busy) return
        root.check(ui.ready && !ui.canApply, "Reopening refreshes the screens without applying")
        root.done("close and reopen during query")
        root.configure({reset: true, reloadDelay: 0.5})
        root.phase++
        break
      case 24:
        ui.refresh()
        secondControls.active = true
        root.phase++
        break
      case 25:
        if (ui.busy || !secondUi || secondUi.busy) return
        ui.selectScreen("DP-3")
        root.child("arrangementLeft").clicked()
        root.child("arrangementBelow", secondUi).clicked()
        root.phase++
        break
      case 26:
        if (ui.busy || secondUi.busy) return
        root.check(ui.canApply && secondUi.canApply, "Two panel instances can each preview a layout")
        root.child("arrangementApply").clicked()
        root.child("arrangementApply", secondUi).clicked()
        root.phase++
        break
      case 27:
        if (ui.busy || secondUi.busy) return
        root.check(ui.error !== secondUi.error && (ui.error ? secondUi : ui).message.indexOf("Saved") >= 0,
                   "Only one competing panel transaction saves its preview")
        var rejected = (ui.error ? ui : secondUi).message
        root.check((rejected.indexOf("in progress") >= 0 || rejected.indexOf("changed since") >= 0) && !ui.canApply && !secondUi.canApply,
                   "The competing panel reports a lock or stale preview and clears its preview")
        root.done("competing panel instances")
        root.finish()
        break
      }
    }
  }
}
