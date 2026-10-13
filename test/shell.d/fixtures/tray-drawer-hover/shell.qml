import QtQuick
import QtTest
import Quickshell
import "widgets"

// Real pointer delivery into an offscreen window: the collapsed tray claims
// no space where its drawer will open, the chevron opens the drawer, the
// drawer stays open while it slides out from under a resting pointer and while
// the pointer rests on the revealed icons, and it closes when the pointer leaves.
ShellRoot {
  id: test
  property int caseIndex: -1
  property var cases: []
  property int step: 0

  function check(condition, message) {
    if (!condition) {
      console.error("FAIL: case " + caseIndex + ": " + message)
      Qt.quit()
      throw new Error(message)
    }
  }

  function layout() {
    for (var i = 0; i < tray.children.length; i++) {
      if (tray.children[i].item) return tray.children[i].item
    }
    throw new Error("tray layout not loaded")
  }

  function axis(item) { return host.vertical ? item.y : item.x }
  function extent(item) { return host.vertical ? item.height : item.width }
  function reversed() { return tray.settings.drawerReversed === true }
  function label() { return (host.vertical ? "vertical" : "horizontal") + (reversed() ? " reversed" : " forward") }
  function moveTo(position) {
    var across = host.vertical ? tray.x + tray.width / 2 : tray.y + tray.height / 2
    if (host.vertical) pointer.mouseMove(canvas, across, position, 0, 0, 0)
    else pointer.mouseMove(canvas, position, across, 0, 0, 0)
  }
  function moveAway() { pointer.mouseMove(canvas, 5, 5, 0, 0, 0) }

  // Screen position along the bar axis of the chevron's centre right now.
  function chevronCenter() {
    var drawer = layout().children[0], chevron = drawer.children[0]
    return axis(tray) + axis(drawer) + axis(chevron) + extent(chevron) / 2
  }
  // Screen position in the middle of where the open drawer's icons will be,
  // measured from the pins: past the chevron on the bar-center side.
  function futureDrawerCenter() {
    var pins = layout().children[1], chevron = layout().children[0].children[0]
    var pinsStart = axis(tray) + axis(pins), reach = extent(chevron) + tray.drawerExtent / 2
    return reversed() ? pinsStart + extent(pins) + reach : pinsStart - reach
  }
  function iconsCenter() {
    var drawer = layout().children[0], clip = drawer.children[1]
    return axis(tray) + axis(drawer) + axis(clip) + extent(clip) / 2
  }

  function nextCase() {
    caseIndex++
    if (caseIndex === cases.length) {
      console.log("PASS: tray drawer hover; " + cases.length + " cases")
      Qt.quit()
      return
    }
    var c = cases[caseIndex]
    host.vertical = c.vertical
    tray.settings = {drawerReversed: c.reversed, pinned: ["pin-1", "pin-2"], hidden: []}
    moveAway()
    tray.expanded = false
    step = 0
    settle.restart()
  }

  function runStep() {
    if (step === 0) {
      check(!tray.expanded, label() + ": drawer collapsed before probing")
      var pins = layout().children[1], chevron = layout().children[0].children[0]
      check(extent(tray) === extent(pins) + extent(chevron), label() + ": the collapsed tray is wider than its pins and chevron")
      moveTo(futureDrawerCenter())
      check(!tray.expanded, label() + ": the collapsed tray claimed the space its drawer opens into")
      moveTo(chevronCenter())
      check(tray.expanded, label() + ": hovering the chevron opens the drawer")
      step = 1
      settle.restart()
    } else if (step === 1) {
      check(tray.revealProgress === 1, label() + ": drawer fully open")
      check(tray.expanded, label() + ": the chevron slid out from under the resting pointer and the drawer closed")
      moveTo(iconsCenter())
      check(tray.expanded, label() + ": resting on the revealed icons keeps the drawer open")
      moveAway()
      check(!tray.expanded, label() + ": leaving the tray closes the drawer")
      nextCase()
    }
  }

  QtObject {
    id: host
    property bool vertical: false
    property int barSize: 36
    property color foreground: "#ffffff"
    property color barForeground: "#ffffff"
    property color urgent: "#ff0000"
    property bool foregroundAnimationEnabled: false
    function hideTooltip(item) {}
    function showTooltip(item, text) {}
    property string fontFamily: "JetBrainsMono Nerd Font"
    property string position: vertical ? "right" : "top"
    property var layoutConfig: ({left: ["test.tray"], center: [], right: []})
    property var shell: QtObject { function updateEntryInline(id, entry) {} }
  }

  TestEvent { id: pointer }

  FloatingWindow {
    visible: true
    implicitWidth: 440
    implicitHeight: 400
    color: "#202020"

    Item {
      id: canvas
      anchors.fill: parent
      // Anchored as in its bar section, so the drawer grows toward the center.
      Tray {
        id: tray
        x: host.vertical ? 30 : (test.reversed() ? 30 : 410 - width)
        y: host.vertical ? (test.reversed() ? 50 : 390 - height) : 50
        width: implicitWidth; height: implicitHeight
        bar: host
        moduleName: "test.tray"
        function bucket(category) {
          var pins = [], drawers = []
          for (var i = 0; i < pinnedIds.length; i++) pins.push({id: pinnedIds[i], status: 1, title: pinnedIds[i], icon: ""})
          for (var j = 0; j < 3; j++) drawers.push({id: "drawer-" + j, status: 1, title: "drawer-" + j, icon: ""})
          return category === "pinned" ? pins : category === "drawer" ? drawers : pins.concat(drawers)
        }
      }
    }
  }

  Timer { id: settle; interval: 900; onTriggered: test.runStep() }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      var list = []
      for (var vertical of [false, true])
        for (var reversed of [true, false])
          list.push({vertical: vertical, reversed: reversed})
      test.cases = list
      test.nextCase()
    }
  }
}
