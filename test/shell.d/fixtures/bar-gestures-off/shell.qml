import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

// Presses the bar the way a user does: with bar.editGestures off, a drag,
// a double-click and a widget drag on the bar move and cycle nothing; turned
// back on through shell.json, the same gestures move the bar to the bottom
// edge and cycle the background again, so the one gate drives all of them.
// The bar draws in its own window per screen, so the pointer events go to
// items inside that window, at coordinates local to them. The background-
// cycle calls go through a logged omarchy-bar stub; the test script counts
// them in the log.
ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  property var failures: []
  property var bar: null
  property var surface: null
  property var gestureArea: null
  // A point over empty bar space, between the left section and the centered
  // box, in the gesture area's own coordinates.
  property real patchX: 0
  property real patchY: 0

  function check(condition, message) {
    if (!condition) failures = failures.concat([String(message)])
  }

  function ids(region) {
    return (host.config.bar.layout[region] || []).map(function(entry) { return entry.id })
  }

  // The center gesture area fills the bar and the widgets are drawn over it;
  // the only MouseArea with a hand-set pressAndHoldInterval is this one, so
  // a walk of the bar window's content finds it wherever it ends up.
  function findGestureArea(item) {
    if (typeof item.cursorShape !== "undefined" && typeof item.pressAndHoldInterval === "number" && item.pressAndHoldInterval === 200)
      return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findGestureArea(item.children[i])
      if (found) return found
    }
    return null
  }

  Component {
    id: testWidget

    Rectangle {
      property var bar: null
      property string moduleName: ""
      property var settings: ({})
      property string fixedEdge: "center"

      implicitWidth: 30
      implicitHeight: 20
      color: "steelblue"
    }
  }

  QtObject {
    id: registry

    property int revision: 0
    property var widgets: ({
      "test.a": { component: testWidget },
      "test.clock": { component: testWidget },
      "test.b": { component: testWidget }
    })

    function metadataFor(id) {
      return widgets[id] ? { firstParty: true } : null
    }
  }

  QtObject {
    id: host

    property var config: ({
      bar: {
        position: "top",
        background: "opaque",
        editGestures: false,
        layout: {
          left: [{ id: "test.a" }],
          center: [{ id: "test.clock" }],
          right: [{ id: "test.b" }]
        }
      }
    })

    function mutateShellConfig(mutator) {
      var copy = JSON.parse(JSON.stringify(config))
      mutator(copy)
      config = copy
    }
  }

  TestCase {
    id: tc
    name: "bar-gestures-off"
    when: false
  }

  FileView {
    id: result
    path: root.resultPath
  }

  Component.onCompleted: {
    var steps = [
      [function() {
        var component = Qt.createComponent("file://" + root.rootPath + "/shell/plugins/bar/Bar.qml")
        if (component.status !== Component.Ready) {
          root.check(false, "Bar.qml loads: " + component.errorString())
          return
        }
        root.bar = component.createObject(root, { barWidgetRegistry: registry, shell: host, barConfig: host.config.bar })
        root.bar.barConfig = Qt.binding(function() { return host.config.bar })
      }, 1200],

      [function() {
        root.check(root.bar.editGestures === false, "the config's editGestures false reaches the bar")
        var a = root.bar.moduleSlots.filter(function(slot) { return slot && slot.moduleName === "test.a" })[0]
        root.check(a, "the left widget is on the bar")
        if (!a) return
        root.surface = root.bar.slotWindow(a)
        root.check(root.surface && root.surface.contentItem, "the bar's window is there")
        if (!root.surface || !root.surface.contentItem) return
        var area = root.findGestureArea(root.surface.contentItem)
        root.check(area, "the center gesture area is there")
        root.gestureArea = area
        root.check(area && area.enabled === false, "the gestures off leave the center gesture area idle")
        root.patchX = area ? area.width * 0.35 : 0
        root.patchY = area ? area.height / 2 : 0
      }, 300],

      // An empty-space drag with the gestures off moves or bothers nothing.
      [function() {
        tc.mousePress(root.gestureArea, root.patchX, root.patchY, Qt.LeftButton)
      }, 100],
      [function() {
        tc.mouseMove(root.gestureArea, root.patchX + 60, root.patchY, -1, Qt.LeftButton)
      }, 200],
      [function() {
        root.check(root.bar.barMoveActive === false, "a drag on empty space doesn't start a bar move: " + root.bar.barMoveActive)
        root.check(host.config.bar.position === "top", "the bar holds its position: " + host.config.bar.position)
        tc.mouseRelease(root.gestureArea, root.patchX + 60, root.patchY)
      }, 300],

      // A double-click on empty space with the gestures off cycles nothing:
      // the omarchy-bar stub's log stays free of "background cycle" calls,
      // which the test script counts at the end.
      [function() {
        tc.mouseDoubleClickSequence(root.gestureArea, root.patchX, root.patchY)
      }, 300],

      // A widget drag with the gestures off reorders nothing.
      [function() {
        var twin = root.bar.moduleSlots.filter(function(slot) { return slot && slot.moduleName === "test.b" })[0]
        if (!twin) {
          root.check(false, "the right widget is on the bar")
          return
        }
        tc.mousePress(twin, twin.width / 2, twin.height / 2, Qt.LeftButton)
      }, 100],
      [function() {
        var twin = root.bar.moduleSlots.filter(function(slot) { return slot && slot.moduleName === "test.b" })[0]
        tc.mouseMove(twin, twin.width / 2 + 40, twin.height / 2, -1, Qt.LeftButton)
      }, 200],
      [function() {
        root.check(root.bar.barDragSource === null, "a widget drag with the gestures off never starts: " + root.bar.barDragSource)
        var twin = root.bar.moduleSlots.filter(function(slot) { return slot && slot.moduleName === "test.b" })[0]
        tc.mouseRelease(twin, twin.width / 2 + 40, twin.height / 2)
      }, 300],
      [function() {
        root.check(JSON.stringify(root.ids("right")) === JSON.stringify(["test.b"]), "the widgets keep their lineup: " + JSON.stringify(root.ids("right")))

        host.mutateShellConfig(function(config) { config.bar.editGestures = true })
      }, 400],

      [function() {
        root.check(root.bar.editGestures === true, "a config write turns the gestures back on")
        root.check(root.gestureArea && root.gestureArea.enabled === true, "the center gesture area answers again")
        tc.mouseDoubleClickSequence(root.gestureArea, root.patchX, root.patchY)
      }, 400],

      // And the bar-move drag moves the bar toward the pointer's edge: the
      // area holds the grab, so the move reaching the screen's bottom keeps
      // coming to it well outside its own thickness.
      [function() {
        tc.mousePress(root.gestureArea, root.patchX, root.patchY, Qt.LeftButton)
      }, 100],
      [function() {
        tc.mouseMove(root.gestureArea, root.patchX, Quickshell.screens[0].height - 8, -1, Qt.LeftButton)
      }, 300],
      [function() {
        root.check(root.bar.barMoveActive === true, "the same drag with the gestures on moves the bar")
        tc.mouseRelease(root.gestureArea, root.patchX, Quickshell.screens[0].height - 8)
      }, 700],
      [function() {
        root.check(host.config.bar.position === "bottom", "the bar lands at the bottom edge: " + host.config.bar.position)
      }, 300]
    ]

    stepper.steps = steps
    stepper.start()
  }

  Timer {
    id: stepper
    property var steps: []
    property int at: 0
    interval: 10
    onTriggered: {
      if (at >= steps.length) {
        result.setText(JSON.stringify({ ok: failures.length === 0, failures: failures }))
        quitter.start()
        return
      }
      var current = steps[at++]
      try {
        current[0]()
      } catch (e) {
        root.check(false, "step " + at + " threw: " + e)
      }
      interval = current[1]
      restart()
    }
  }

  Timer {
    id: quitter
    interval: 200
    onTriggered: Qt.quit()
  }
}
