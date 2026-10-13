import QtQuick
import Quickshell
import "widgets"

ShellRoot {
  id: test
  property int caseIndex: -1
  property int frameCount: 0
  property int midFrames: 0
  property real pinnedScreenPosition: 0
  property var cases: []
  property var savedEntry: null
  property var savedId: null
  property string captureDir: Quickshell.env("OMARCHY_TRAY_CAPTURE_DIR")

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

  // Every frame: the tray holds only its pins, chevron and revealed icons, the
  // chevron leads the slide toward the bar center, the icons emerge from the
  // pins' side, and the pins never move on screen.
  function verifyFrame() {
    var content = layout(), drawer = content.children[0], pins = content.children[1]
    var chevron = drawer.children[0], clip = drawer.children[1], icons = clip.children[0]
    var cw = extent(chevron), revealed = tray.revealPx, full = tray.drawerExtent
    var block = tray.allItems.length > 0 ? cw + revealed : 0
    check(extent(tray) === extent(pins) + block, "tray occupies pins, chevron and revealed icons only")
    check(extent(drawer) === block, "drawer block sized from the revealed icons")
    check(extent(clip) === revealed, "icon clip tracks the revealed extent")
    check(chevron.textRotation === (host.vertical ? (tray.drawerReversed ? 270 : 90) : (tray.drawerReversed ? 180 : 0)), "chevron direction")
    if (tray.drawerReversed) {
      check(axis(pins) === 0, "pins lead the reversed tray")
      check(axis(drawer) === extent(pins), "reversed drawer follows the pins")
      check(axis(clip) === 0 && axis(chevron) === revealed, "reversed chevron leads the slide")
      check(axis(icons) + full === revealed, "reversed icons end at the chevron")
    } else {
      check(axis(drawer) === 0, "forward drawer leads the tray")
      check(axis(pins) === block, "pins follow the forward drawer")
      check(axis(chevron) === 0 && axis(clip) === cw, "forward chevron leads the slide")
      check(axis(icons) === 0, "forward icons start at the chevron")
    }
    check(axis(tray) + axis(pins) === pinnedScreenPosition, "pinned targets moved during animation")
    if (tray.revealProgress > 0 && tray.revealProgress < 1) midFrames++
    frameCount++
  }

  function capture(state, done) {
    if (captureDir && tray.pinnedIds.length && tray.testDrawerCount) {
      canvas.grabToImage(function(result) {
        result.saveToFile(test.captureDir + "/case-" + test.caseIndex + "-" + state + ".png")
        done()
      })
    } else done()
  }

  function nextCase() {
    caseIndex++
    if (caseIndex === cases.length) {
      check(midFrames > 0, "intermediate animation frames exercised")
      console.log("PASS: tray direction, collapsed footprint, stationary pins, settings; " + frameCount + " frames, " + midFrames + " mid-animation")
      Qt.quit()
      return
    }
    var c = cases[caseIndex]
    host.vertical = c.vertical
    tray.settings = {drawerReversed: c.reversed, pinned: c.pins ? ["pin-1", "pin-2"] : [], hidden: [], customSetting: "keep"}
    tray.testDrawerCount = c.drawers
    tray.expanded = false
    settle.restart()
  }

  function verifyPersistence() {
    for (var forced of [false, true]) {
      tray.settings = {id: "stale-id", drawerReversed: forced, pinned: [], hidden: [], customSetting: "keep"}
      for (var action of ["togglePin", "togglePin", "toggleHide", "toggleHide"]) {
        tray[action]("pin-1")
        check(savedId === "test.tray" && savedEntry.id === "test.tray", "clone entry id preserved")
        check(savedEntry.drawerReversed === forced && savedEntry.customSetting === "keep", "settings preserved by " + action)
        tray.settings = savedEntry
      }
      check(savedEntry.pinned.length === 0 && savedEntry.hidden.length === 0, "pin/hide toggles round trip")
    }
    tray.settings = {}
    for (var region of ["left", "center", "right"]) {
      var config = {left: [], center: [], right: []}
      config[region] = ["test.tray"]
      host.layoutConfig = config
      check(tray.drawerReversed === (region === "left"), "clone region detection: " + region)
      config = {left: [], center: [], right: []}
      config[region] = [{id: "test.tray"}]
      host.layoutConfig = config
      check(tray.drawerReversed === (region === "left"), "object entry region detection: " + region)
    }
    // An anchored center section holds its tail's leading end still and its
    // head's trailing end; without an anchor it holds neither.
    var centerCases = [
      {anchor: "omarchy.clock", center: ["omarchy.clock", "test.tray"], reversed: true, label: "tail of anchored center"},
      {anchor: "omarchy.clock", center: ["test.tray", "omarchy.clock"], reversed: false, label: "head of anchored center"},
      {anchor: "test.tray", center: ["omarchy.media", "test.tray"], reversed: false, label: "tray is the center anchor"},
      {anchor: "", center: ["omarchy.clock", "test.tray"], reversed: false, label: "unanchored center"},
      {anchor: "omarchy.clock", center: ["omarchy.media", "test.tray"], reversed: false, label: "anchor absent from center"}
    ]
    for (var cc of centerCases) {
      host.centerAnchor = cc.anchor
      host.layoutConfig = {left: [], center: cc.center, right: []}
      check(tray.drawerReversed === cc.reversed, "center detection: " + cc.label)
    }
    host.centerAnchor = ""
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
    property string centerAnchor: ""
    property var shell: QtObject {
      function updateEntryInline(id, entry) { test.savedId = id; test.savedEntry = entry }
    }
  }

  FloatingWindow {
    visible: true
    implicitWidth: 440
    implicitHeight: 300
    color: "#202020"

    Item {
      id: canvas
      anchors.fill: parent
      Rectangle { anchors.fill: parent; color: "#202020" }
      Text { x: 20; y: 12; color: "white"; text: (host.vertical ? "Vertical" : "Horizontal") + (tray.drawerReversed ? " reversed" : " forward") + (tray.expanded ? " open" : " closed") }
      // Anchor the tray the way its bar section does: a leading section fixes
      // the pins' end at the bar edge, a trailing section fixes the other end,
      // so the drawer grows toward the bar center.
      Tray {
        id: tray
        x: host.vertical ? 30 : (drawerReversed ? 30 : 410 - width)
        y: host.vertical ? (drawerReversed ? 50 : 290 - height) : 50
        width: implicitWidth; height: implicitHeight
        bar: host
        moduleName: "test.tray"
        property int testDrawerCount: 3
        function bucket(category) {
          var pins = [], drawers = []
          for (var i = 0; i < pinnedIds.length; i++) pins.push(fakeItem(pinnedIds[i], "#70e090", i + 1))
          for (var j = 0; j < testDrawerCount; j++) drawers.push(fakeItem("drawer-" + j, "#f0a050", j + 1))
          return category === "pinned" ? pins : category === "drawer" ? drawers : pins.concat(drawers)
        }
        function fakeItem(id, color, number) {
          return {id: id, status: 1, title: id, icon: "data:image/svg+xml," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"><rect width="24" height="24" rx="4" fill="' + color + '"/><text x="12" y="18" text-anchor="middle" font-size="18">' + number + '</text></svg>')}
        }
      }
    }
  }

  Timer {
    id: settle
    interval: 750
    onTriggered: {
      test.pinnedScreenPosition = test.axis(tray) + test.axis(test.layout().children[1])
      test.verifyFrame()
      test.capture("closed", function() {
        tray.expanded = true
        frames.start()
        opened.start()
      })
    }
  }
  Timer { id: frames; interval: 16; repeat: true; onTriggered: test.verifyFrame() }
  Timer {
    id: opened
    interval: 750
    onTriggered: {
      test.verifyFrame()
      test.capture("open", function() {
        tray.expanded = false
        closed.start()
      })
    }
  }
  Timer {
    id: closed
    interval: 750
    onTriggered: { test.verifyFrame(); frames.stop(); test.nextCase() }
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      test.verifyPersistence()
      var list = []
      for (var vertical of [false, true])
        for (var reversed of [false, true])
          for (var pins of [false, true])
            for (var drawers of [0, 3])
              list.push({vertical: vertical, reversed: reversed, pins: pins, drawers: drawers})
      test.cases = list
      test.nextCase()
    }
  }
}
