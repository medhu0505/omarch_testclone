import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "ArrangementModel.js" as Model

Column {
  id: root

  property bool active: false
  property color foreground: Commons.Color.popups.text
  property string fontFamily: Style.font.family
  property var backendCommand: ["python3", Quickshell.env("OMARCHY_PATH") + "/default/hypr/monitor-position.py"]
  property var monitors: []
  property var preview: []
  property var snapshot: []
  property string moving: ""
  property string reference: ""
  property string side: ""
  property string alignment: "top"
  property string message: "Connect and enable at least two screens to arrange them."
  property bool error: false
  property bool busy: false
  property bool refreshQueued: false
  property string requestAction: ""
  property bool preserveMessage: false
  property int cursorIndex: -1
  property bool identifying: false
  property var identificationScreens: Quickshell.screens
  readonly property bool popupOpen: movingPicker.popupOpen || referencePicker.popupOpen || alignmentPicker.popupOpen
  readonly property bool ready: !busy && monitors.length >= 2
  readonly property bool canApply: ready && side !== "" && preview.length > 0
  readonly property var shownMonitors: preview.length ? preview : monitors
  readonly property var layoutBounds: Model.bounds(shownMonitors)
  readonly property var screenOptions: monitors.map(function(m) { return m.name })
  readonly property var referenceOptions: screenOptions.filter(function(name) { return name !== root.moving })
  readonly property var sides: ["left", "right", "above", "below"]
  readonly property var alignmentOptions: side === "above" || side === "below"
    ? ["left", "center", "right"] : ["top", "center", "bottom"]

  signal cursorRequested(int index, var item)
  signal applied()

  spacing: Style.space(10)
  onCursorIndexChanged: {
    var item = cursorIndex === 0 ? identifyButton : cursorIndex === 1 ? movingPicker : cursorIndex === 2 ? referencePicker
      : cursorIndex >= 3 && cursorIndex <= 6 ? directionButtons.itemAt(cursorIndex - 3)
      : cursorIndex === 7 ? alignmentPicker : cursorIndex === 8 ? applyButton : cursorIndex === 9 ? refreshButton : null
    if (item) cursorRequested(cursorIndex, item)
  }
  onActiveChanged: {
    if (active) refresh()
    else { movingPicker.close(); referencePicker.close(); alignmentPicker.close(); identifying = false; identifyTimer.stop() }
  }

  function request(action, preserve) {
    if (busy) return
    requestAction = action
    preserveMessage = !!preserve
    error = preserve ? error : false
    busy = true
    if (!preserve) message = action === "apply" ? "Applying layout…" : "Reading screens…"
    var payload = { action: action }
    if (action !== "state") {
      payload.output = moving
      payload.reference = reference
      payload.side = side
      payload.alignment = alignment
      payload.snapshot = snapshot
    }
    backend.command = backendCommand.concat(["--request", JSON.stringify(payload)])
    backend.running = true
  }

  function refresh(preserve) {
    if (busy) { refreshQueued = true; return }
    preview = []
    side = ""
    alignment = "top"
    request("state", preserve)
  }

  function invalidate() {
    preview = []
    side = ""
    alignment = "top"
    if (active) refresh()
  }

  function selectScreen(name) {
    if (!ready || screenOptions.indexOf(name) < 0) return
    moving = name
    var selected = Model.pair(monitors, moving, reference === name ? "" : reference)
    // Keep the clicked screen as the moving one, even when it was the reference.
    reference = selected.reference === moving ? referenceOptions[0] || "" : selected.reference
    clearPreview()
  }

  function clearPreview() {
    preview = []
    side = ""
    alignment = "top"
    error = false
    message = "Choose a position to preview. Apply saves the layout."
  }

  function chooseSide(value) {
    if (!ready || sides.indexOf(value) < 0) return
    preview = []
    side = value
    if (alignmentOptions.indexOf(alignment) < 0) alignment = alignmentOptions[0]
    request("preview")
  }

  function chooseAlignment(value) {
    if (!ready || side === "" || alignmentOptions.indexOf(value) < 0) return
    alignment = value
    preview = []
    request("preview")
  }

  function activate(index) {
    if (index === 0) identifyScreens()
    else if (index === 1 && ready) movingPicker.open()
    else if (index === 2 && ready) referencePicker.open()
    else if (index >= 3 && index <= 6) chooseSide(sides[index - 3])
    else if (index === 7 && ready && side !== "") alignmentPicker.open()
    else if (index === 8 && canApply) request("apply")
    else if (index === 9) refresh()
  }

  function identifyScreens() {
    identifying = true
    identifyTimer.restart()
  }

  function finish(exitCode) {
    busy = false
    var action = requestAction
    if (exitCode !== 0) {
      preview = []
      side = ""
      alignment = "top"
      if (action === "state") { monitors = []; snapshot = [] }
      var detail = String(backendError.text || "").trim() || "Cannot read or arrange the screens. Try Refresh."
      message = preserveMessage ? message + " Refresh failed: " + detail : detail
      error = true
    } else {
      try {
        var response = JSON.parse(backendOutput.text)
        if (action === "apply") {
          message = response.message
          error = false
          preview = []
          side = ""
          alignment = "top"
          refreshQueued = true
          applied()
        } else {
          if (!Array.isArray(response.monitors) || !Array.isArray(response.snapshot)) throw new Error("Invalid display response")
          if (action === "preview") {
            preview = response.monitors
            message = moving + " " + side + " of " + reference + ", aligned " + alignment + ". Preview only."
          } else {
            monitors = response.monitors
            snapshot = response.snapshot
            var selected = Model.pair(monitors, moving, reference)
            moving = selected.moving
            reference = selected.reference
            if (!preserveMessage) message = monitors.length < 2
              ? "Connect and enable at least two screens to arrange them."
              : "Choose a position to preview. Apply saves the layout."
          }
        }
      } catch (failure) {
        preview = []
        side = ""
        alignment = "top"
        monitors = []
        snapshot = []
        message = "Cannot read the display response. Try Refresh."
        error = true
      }
    }
    if (refreshQueued) {
      refreshQueued = false
      refresh(action === "apply" || error)
    }
  }

  Process {
    id: backend
    stdout: StdioCollector { id: backendOutput; waitForEnd: true }
    stderr: StdioCollector { id: backendError; waitForEnd: true }
    onExited: function(exitCode) { root.finish(exitCode) }
    // Failed-to-start emits runningChanged without exited.
    onRunningChanged: if (!running && root.busy) Qt.callLater(function() {
      if (root.busy && !backend.running) root.finish(1)
    })
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (["monitoradded", "monitoraddedv2", "monitorremoved", "configreloaded"].indexOf(event.name) >= 0)
        root.invalidate()
    }
  }

  Loader {
    active: root.identifying && root.identificationScreens.length > 0
    source: "ScreenIdentifiers.qml"
    onLoaded: {
      item.shown = Qt.binding(function() { return root.identifying })
      item.screens = Qt.binding(function() { return root.identificationScreens })
    }
  }
  Timer { id: identifyTimer; interval: 4000; onTriggered: root.identifying = false }

  Row {
    width: parent.width
    spacing: Style.space(8)
    PanelSectionHeader {
      width: parent.width - identifyButton.width - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      text: "ARRANGEMENT"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
    Button {
      id: identifyButton
      objectName: "arrangementIdentify"
      text: "Identify screens"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.caption
      verticalPadding: Style.space(4)
      bordered: true
      hasCursor: root.cursorIndex === 0
      onClicked: root.identifyScreens()
      onHovered: function(hot) { if (hot) root.cursorRequested(0, identifyButton) }
    }
  }

  Rectangle {
    id: diagram
    width: parent.width
    height: Style.space(140)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
    radius: Style.cornerRadius
    readonly property real fit: Math.min((width - Style.space(20)) / root.layoutBounds.width,
                                         (height - Style.space(20)) / root.layoutBounds.height)
    Repeater {
      model: root.shownMonitors
      Rectangle {
        required property var modelData
        x: (diagram.width - root.layoutBounds.width * diagram.fit) / 2 + (modelData.x - root.layoutBounds.x) * diagram.fit
        y: (diagram.height - root.layoutBounds.height * diagram.fit) / 2 + (modelData.y - root.layoutBounds.y) * diagram.fit
        width: modelData.logicalWidth * diagram.fit
        height: modelData.logicalHeight * diagram.fit
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, modelData.name === root.moving ? 0.16 : 0.06)
        border.width: modelData.name === root.moving ? 2 : 1
        border.color: modelData.name === root.moving ? Commons.Color.accent : root.foreground
        Text {
          anchors.centerIn: parent
          width: Math.max(0, parent.width - Style.space(8))
          textFormat: Text.PlainText
          text: modelData.name
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        MouseArea { anchors.fill: parent; enabled: root.ready; cursorShape: Qt.PointingHandCursor; onClicked: root.selectScreen(modelData.name) }
      }
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(10)
    Dropdown {
      id: movingPicker
      objectName: "arrangementMoving"
      width: (parent.width - parent.spacing) / 2
      label: "Move screen"
      value: root.moving
      options: root.screenOptions
      enabled: root.ready
      foreground: root.foreground
      fontFamily: root.fontFamily
      hasCursor: root.cursorIndex === 1
      onChanged: function(value) { root.selectScreen(value) }
      onHovered: function(hot) { if (hot) root.cursorRequested(1, movingPicker) }
    }
    Dropdown {
      id: referencePicker
      objectName: "arrangementReference"
      width: (parent.width - parent.spacing) / 2
      label: "Relative to"
      value: root.reference
      options: root.referenceOptions
      enabled: root.ready
      foreground: root.foreground
      fontFamily: root.fontFamily
      hasCursor: root.cursorIndex === 2
      onChanged: function(value) { root.reference = value; root.clearPreview() }
      onHovered: function(hot) { if (hot) root.cursorRequested(2, referencePicker) }
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(4)
    Repeater {
      id: directionButtons
      model: ["Left", "Right", "Above", "Below"]
      Button {
        id: directionButton
        required property string modelData
        required property int index
        objectName: "arrangement" + modelData
        width: (parent.width - parent.spacing * 3) / 4
        text: modelData
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: root.ready
        opacity: enabled ? 1 : 0.45
        active: root.side === root.sides[index] && root.preview.length > 0
        hasCursor: root.cursorIndex === index + 3
        onClicked: root.chooseSide(root.sides[index])
        onHovered: function(hot) { if (hot) root.cursorRequested(index + 3, directionButton) }
      }
    }
  }

  Dropdown {
    id: alignmentPicker
    objectName: "arrangementAlignment"
    width: parent.width
    label: "Align screens"
    value: root.alignment
    options: root.alignmentOptions.map(function(value) {
      return {value: value, label: value.charAt(0).toUpperCase() + value.slice(1)}
    })
    enabled: root.ready && root.side !== ""
    foreground: root.foreground
    fontFamily: root.fontFamily
    hasCursor: root.cursorIndex === 7
    onChanged: function(value) { root.chooseAlignment(value) }
    onHovered: function(hot) { if (hot) root.cursorRequested(7, alignmentPicker) }
  }

  Text {
    width: parent.width
    textFormat: Text.PlainText
    text: root.message
    color: root.error ? Commons.Color.urgent : root.foreground
    opacity: root.error ? 1 : 0.7
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  Row {
    width: parent.width
    spacing: Style.space(6)
    Button {
      id: applyButton
      objectName: "arrangementApply"
      width: (parent.width - parent.spacing) / 2
      text: root.busy && root.requestAction === "apply" ? "Applying…" : "Apply layout"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.canApply
      opacity: enabled ? 1 : 0.45
      hasCursor: root.cursorIndex === 8
      onClicked: if (root.canApply) root.request("apply")
      onHovered: function(hot) { if (hot) root.cursorRequested(8, applyButton) }
    }
    Button {
      id: refreshButton
      objectName: "arrangementRefresh"
      width: (parent.width - parent.spacing) / 2
      text: "Refresh"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !root.busy
      opacity: enabled ? 1 : 0.45
      hasCursor: root.cursorIndex === 9
      onClicked: root.refresh()
      onHovered: function(hot) { if (hot) root.cursorRequested(9, refreshButton) }
    }
  }
}
