import QtQuick
import qs.Commons

// Collapsible bar container. Hides its content behind a chevron and reveals it
// with a hover-to-expand slide, the same gesture the system tray drawer uses.
// Collapsed, the container is only the chevron; it grows to fit its content as
// it opens, so a collapsed group costs no more bar space than its chevron.
//
// Content is supplied as a Component (not default children) so the chevron and
// clip below are not swallowed by a default-property alias, and so the loaded
// item is available to measure for the drawer extent.
Item {
  id: root

  // Host bar, injected by the caller. Supplies vertical / barSize / theming for
  // the chevron. Left null the component still lays out with Style fallbacks.
  property var bar: null
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The content to reveal. Its implicit size along the bar axis is the extent
  // the drawer opens to.
  property Component contentComponent: null
  readonly property Item body: contentLoader.item

  property bool collapsedByDefault: true
  property bool expandOnHover: true
  // Chevron glyph. Escaped codepoint on purpose: raw Nerd Font glyphs can be
  // mangled by file tooling, so the default stays stable this way.
  property string icon: ""
  property int animationDuration: 600

  // A hover reveals transiently; a chevron click pins the drawer open so it
  // survives the pointer leaving. pinnedOpen follows collapsedByDefault until the
  // first chevron click breaks the binding and hands control to the user. It must
  // stay a live binding: BarGroup sets the group's entry — and thus
  // collapsedByDefault — right after load, so freezing on completion would lock in
  // the pre-entry default and ignore a configured collapsed: false.
  property bool pinnedOpen: !collapsedByDefault
  property bool hovered: false
  readonly property bool open: pinnedOpen || (expandOnHover && hovered)

  readonly property real drawerExtent: body ? (vertical ? body.implicitHeight : body.implicitWidth) : 0
  property real revealProgress: open ? 1 : 0
  readonly property real revealExtent: drawerExtent * revealProgress

  Behavior on revealProgress {
    NumberAnimation { duration: Style.duration(root.animationDuration); easing.type: Easing.OutCubic }
  }

  implicitWidth: vertical ? barSize : Math.round(chevron.implicitWidth + revealExtent)
  implicitHeight: vertical ? Math.round(chevron.implicitHeight + revealExtent) : barSize

  // Whole-container hover drives the transient reveal. A HoverHandler on the
  // root sees the chevron and the revealed content as one region, so sliding
  // from the chevron onto the content does not collapse it mid-motion.
  HoverHandler {
    enabled: root.expandOnHover
    onHoveredChanged: root.hovered = hovered
  }

  BarIconButton {
    id: chevron
    bar: root.bar
    width: implicitWidth
    height: implicitHeight
    text: root.icon
    textRotation: root.vertical ? 90 : 0
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.pinnedOpen = !root.pinnedOpen
    }
  }

  // The revealed slice. Clipped so the content is wiped in from the chevron as
  // the slice grows, and so a partially-open drawer never paints past its edge.
  Item {
    id: revealClip
    x: root.vertical ? 0 : chevron.implicitWidth
    y: root.vertical ? chevron.implicitHeight : 0
    width: root.vertical ? root.barSize : Math.round(root.revealExtent)
    height: root.vertical ? Math.round(root.revealExtent) : root.barSize
    clip: true

    // The content is laid out at its full extent regardless of how far the
    // drawer has opened, so its widgets never reflow as it animates. On the
    // cross axis it is sized to the content and centered, so content shorter
    // than the bar sits centered rather than top/left-aligned.
    Loader {
      id: contentLoader
      sourceComponent: root.contentComponent
      x: root.vertical ? Math.round((root.barSize - implicitWidth) / 2) : 0
      y: root.vertical ? 0 : Math.round((root.barSize - implicitHeight) / 2)
      width: root.vertical ? implicitWidth : root.drawerExtent
      height: root.vertical ? root.drawerExtent : implicitHeight
    }
  }
}
