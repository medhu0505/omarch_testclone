import QtQuick

// Stands in for KeyboardPanel in offscreen runs, which have no layer-shell
// backend for its PanelWindow. It takes the same properties so the panel's
// own content, cursor, and bindings run unchanged inside a plain Item, and
// caps the height so scrolling the cursor into view has somewhere to go.
Item {
  id: root

  property Item anchorItem: null
  property QtObject bar: null
  property var owner: null
  property bool open: false
  property Item focusTarget: null
  property string accessibleName: ""
  property int contentWidth: 380
  property int contentHeight: 200
  default property alias contentItem: contentHolder.children

  function fittedContentWidth(width, cap) {
    return Math.round(Number(width) || 1)
  }

  function fittedContentHeight(implicitHeight, cap) {
    return Math.min(160, Math.round(Number(implicitHeight) || 0))
  }

  width: contentWidth
  height: contentHeight

  Item {
    id: contentHolder
    anchors.fill: parent
  }
}
