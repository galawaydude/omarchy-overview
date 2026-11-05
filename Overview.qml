import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import "Layout.js" as Layout

// GNOME-style overview: windows spread out as live thumbnails, with an "All"
// tab (every workspace at once, the default) and one tab per workspace along
// the top. Toggle: `omarchy-shell shell toggle galawaydude.overview` (bind it to a key).
//   click window: focus it      drag window onto tab: move it there
//   click tab: view it          double-click tab / click empty space: go there
//   type: search all windows    Tab/Shift+Tab: next/prev tab
//   arrows: move between windows, stepping to the next tab at the left/right edge
//   Enter: pick                 Esc: clear search, then close
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool closing: false
  property bool spread: false
  property int viewedWs: 0          // 0 = All
  property string query: ""
  property int selected: -1
  property var targetScreen: null

  // Window being dragged toward a workspace tab.
  property var dragWin: null
  property point dragPos: Qt.point(0, 0)
  property int dropWs: 0

  readonly property bool shown: opened || closing
  readonly property int animMs: 240
  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color accent: Color.accent
  readonly property color muted: Color.muted
  readonly property string fontFamily: Style.font.family

  readonly property var mon: Hyprland.focusedMonitor
  readonly property int activeWs: mon && mon.activeWorkspace ? mon.activeWorkspace.id : 1

  readonly property var workspaces: Hyprland.workspaces.values
    .filter(function (w) { return w.id > 0 })
    .sort(function (a, b) { return a.id - b.id })
  readonly property int newWs: workspaces.length ? workspaces[workspaces.length - 1].id + 1 : 1

  readonly property var shownWindows: {
    var q = query.trim().toLowerCase()
    return Hyprland.toplevels.values.filter(function (t) {
      var o = t.lastIpcObject
      if (!o || !o.at || o.hidden || !t.workspace || (t.workspace.id <= 0 && !isMinimized(t))) return false
      if (!q) return viewedWs === 0 || homeWs(t) === viewedWs
      return ((o.title || "") + " " + (o.class || "")).toLowerCase().indexOf(q) !== -1
    }).sort(function (a, b) {
      var oa = a.lastIpcObject, ob = b.lastIpcObject
      return (homeWs(a) - homeWs(b)) || (oa.at[1] - ob.at[1]) || (oa.at[0] - ob.at[0])
    })
  }

  // Omarchy minimizes a window by parking it on this special workspace, tagged
  // with the workspace it came from; the dock brings it back.
  function isMinimized(t) {
    return !!t.workspace && t.workspace.name === "special:minimized"
  }

  // The workspace a window belongs to: its own, or where it was minimized from
  // (0 if unknown).
  function homeWs(t) {
    if (!isMinimized(t)) return t.workspace ? t.workspace.id : 0
    var tags = (t.lastIpcObject && t.lastIpcObject.tags) || []
    for (var i = 0; i < tags.length; i++) {
      var m = /^omarchy-minimized-from-(\d+)/.exec(tags[i])
      if (m) return parseInt(m[1])
    }
    return 0
  }

  // Thumbnails only change when the set of windows does; Hyprland events
  // rebuild shownWindows constantly, which would recreate tiles mid-animation.
  property var tiles: []
  property int startWs: 1
  property var picked: null

  onShownWindowsChanged: {
    var n = shownWindows
    if (opened && (n.length !== tiles.length || n.some(function (t, i) { return t !== tiles[i] }))) tiles = n
  }

  readonly property var slots: Layout.spread(tiles.map(function (t) {
    var s = t.lastIpcObject.size
    return { w: Math.max(1, s[0]), h: Math.max(1, s[1]) }
  }), area.width, area.height, Style.space(28))

  // ---- lifecycle (shell contract: opened / open / close)

  function open(payloadJson) {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
    var name = mon ? mon.name : ""
    var screens = Quickshell.screens
    targetScreen = screens[0]
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) targetScreen = screens[i]
    viewedWs = 0
    startWs = activeWs
    picked = null
    query = ""
    selected = -1
    dragWin = null
    closeTimer.stop()
    closing = false
    spread = false
    // Fresh tiles before the Repeater rebuilds: old ones may be closed windows.
    tiles = shownWindows
    opened = true
    spreadTimer.restart()
    Qt.callLater(function () { search.forceActiveFocus() })
  }

  function close() {
    if (!opened) return
    opened = false
    spread = false
    dragWin = null
    closing = true
    closeTimer.restart()
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide("galawaydude.overview")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  // ---- actions (hyprctl, as the built-in workspaces widget does)

  function dispatch(expr) {
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  function activate(t) {
    if (!t || !t.lastIpcObject) return
    picked = t
    var target = 'window = "address:' + t.lastIpcObject.address + '"'
    // A minimized window comes back to where it was minimized from first.
    var focus = 'hl.dsp.focus({ ' + target + ' })'
    if (isMinimized(t)) {
      var move = 'hl.dsp.window.move({ workspace = "' + (homeWs(t) || startWs) + '", ' + target + ' })'
      Quickshell.execDetached(["sh", "-c", 'hyprctl dispatch "$1" && hyprctl dispatch "$2"', "sh", move, focus])
    } else {
      dispatch(focus)
    }
    dismiss()
  }

  function goTo(id) {
    if (id > 0 && id !== activeWs) dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
    dismiss()
  }

  function moveTo(t, id) {
    if (!t || !t.lastIpcObject || !t.workspace || t.workspace.id === id) return
    dispatch('hl.dsp.window.move({ workspace = "' + id + '", follow = false, window = "address:' + t.lastIpcObject.address + '" })')
    refreshTimer.restart()
  }

  function cycleWs(step) {
    var ids = [0].concat(workspaces.map(function (w) { return w.id }))
    var i = ids.indexOf(viewedWs)
    viewedWs = ids[((i < 0 ? 0 : i) + step + ids.length) % ids.length]
    query = ""
    selected = -1
  }

  // Nearest window in the arrow's direction; past the left/right edge, the
  // previous/next tab (landing on its last/first window).
  function moveSelection(dx, dy) {
    var n = tiles.length
    if (selected < 0 || selected >= n || !slots[selected]) {
      if (n) { selected = 0; return }
      if (dx) cycleWs(dx)
      return
    }
    var c = slots[selected], cx = c.x + c.w / 2, cy = c.y + c.h / 2
    var best = -1, bestScore = Infinity
    for (var i = 0; i < n; i++) {
      var s = slots[i]
      if (i === selected || !s) continue
      var ox = s.x + s.w / 2 - cx, oy = s.y + s.h / 2 - cy
      var along = dx ? ox * dx : oy * dy, across = dx ? Math.abs(oy) : Math.abs(ox)
      if (along <= 1) continue
      var score = along + across * 2
      if (score < bestScore) { bestScore = score; best = i }
    }
    if (best >= 0) { selected = best; return }
    if (!dx) return
    cycleWs(dx)
    Qt.callLater(function () {
      if (tiles.length) selected = dx > 0 ? 0 : tiles.length - 1
    })
  }

  function iconFor(cls) {
    var e = cls ? DesktopEntries.heuristicLookup(cls) : null
    return e && e.icon ? Quickshell.iconPath(e.icon, true) : ""
  }

  // Monitor-local logical geometry of a window, for tabs and fly-in.
  function localRect(t) {
    var o = t.lastIpcObject, m = t.monitor || (t.workspace && t.workspace.monitor)
    var mx = m ? m.x : 0, my = m ? m.y : 0
    return { x: o.at[0] - mx, y: o.at[1] - my, w: o.size[0], h: o.size[1] }
  }

  Timer { id: spreadTimer; interval: 16; onTriggered: {
    root.spread = true
    var a = Hyprland.activeToplevel
    root.selected = a ? root.tiles.indexOf(a) : -1
  } }
  // Drop window references once hidden, so none outlive their window.
  Timer { id: closeTimer; interval: root.animMs; onTriggered: {
    root.closing = false
    root.tiles = []
    root.picked = null
  } }
  Timer { id: refreshTimer; interval: 120; onTriggered: Hyprland.refreshToplevels() }

  PanelWindow {
    id: panel
    visible: root.shown
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "galawaydude-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      id: scrim
      anchors.fill: parent
      color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 1)
      opacity: root.spread ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }

      MouseArea {
        anchors.fill: parent
        onClicked: root.goTo(root.viewedWs)
      }
    }

    Item {
      id: chrome
      anchors.fill: parent
      opacity: root.spread ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: root.animMs } }

      // ---- search
      Rectangle {
        id: searchBox
        anchors.top: parent.top
        anchors.topMargin: Style.space(24)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Style.space(360)
        height: Style.space(36)
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
        border.width: search.activeFocus && root.query ? 1 : 0
        border.color: root.accent

        Text {
          anchors.fill: parent
          anchors.leftMargin: Style.space(16)
          verticalAlignment: Text.AlignVCenter
          visible: !search.text
          text: "Type to search windows"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        TextInput {
          id: search
          anchors.fill: parent
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(16)
          verticalAlignment: TextInput.AlignVCenter
          color: root.fg
          selectionColor: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          clip: true
          text: root.query
          onTextEdited: { root.query = text; root.selected = text ? 0 : -1 }

          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            var n = root.tiles.length
            switch (event.key) {
            case Qt.Key_Escape:
              if (root.query) root.query = ""
              else root.dismiss()
              break
            case Qt.Key_Return:
            case Qt.Key_Enter:
              if (root.selected >= 0 && root.selected < n) root.activate(root.tiles[root.selected])
              else root.goTo(root.viewedWs)
              break
            case Qt.Key_Tab:
              root.cycleWs(1)
              break
            case Qt.Key_Backtab:
              root.cycleWs(-1)
              break
            case Qt.Key_Right:
              root.moveSelection(1, 0)
              break
            case Qt.Key_Left:
              root.moveSelection(-1, 0)
              break
            case Qt.Key_Down:
              root.moveSelection(0, 1)
              break
            case Qt.Key_Up:
              root.moveSelection(0, -1)
              break
            default:
              return
            }
            event.accepted = true
          }
        }
      }

      // ---- workspace tabs
      Row {
        id: tabs
        anchors.top: searchBox.bottom
        anchors.topMargin: Style.space(18)
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        readonly property real aspect: panel.height > 0 ? panel.width / panel.height : 16 / 9
        readonly property real tabW: Math.min(Style.space(170),
          (panel.width * 0.9 - spacing * (root.workspaces.length + 1)) / (root.workspaces.length + 1.5))
        readonly property real tabH: tabW / aspect

        // Workspace id under a point in panel coordinates, 0 if none.
        function wsAt(px, py) {
          for (var i = 0; i < children.length; i++) {
            var c = children[i]
            if (c.wsId === undefined) continue
            var p = c.mapFromItem(null, px, py)
            if (p.x >= 0 && p.y >= 0 && p.x <= c.width && p.y <= c.height) return c.wsId
          }
          return 0
        }

        // Every workspace at once. Not a drop target, so it has no wsId.
        Rectangle {
          readonly property bool viewed: !root.query && root.viewedWs === 0
          width: tabs.tabW * 0.5
          height: tabs.tabH
          radius: Style.space(6)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
          border.width: viewed ? 2 : 1
          border.color: viewed ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, allArea.containsMouse ? 0.5 : 0.15)

          Text {
            anchors.centerIn: parent
            text: "All"
            color: parent.viewed ? root.accent : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: allArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.viewedWs = 0; root.query = ""; root.selected = -1 }
          }
        }

        Repeater {
          model: root.shown ? root.workspaces : []

          delegate: Rectangle {
            id: tab
            required property var modelData
            readonly property int wsId: modelData.id
            readonly property var m: modelData.monitor
            readonly property real sx: tabs.tabW / (m ? m.width / m.scale : panel.width)
            readonly property bool viewed: !root.query && root.viewedWs === wsId

            width: tabs.tabW
            height: tabs.tabH
            radius: Style.space(6)
            clip: true
            color: root.dropWs === wsId ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.3)
                                        : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)
            border.width: viewed ? 2 : 1
            border.color: viewed ? root.accent : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, tabArea.containsMouse ? 0.5 : 0.15)

            Repeater {
              // Floating windows above tiled ones, most recently focused on top.
              model: tab.modelData.toplevels.values.filter(function (t) {
                var o = t.lastIpcObject
                return o && o.at && !o.hidden
              }).sort(function (a, b) {
                var oa = a.lastIpcObject, ob = b.lastIpcObject
                return (oa.floating - ob.floating) || (ob.focusHistoryID - oa.focusHistoryID)
              })

              delegate: ScreencopyView {
                required property var modelData
                layer.enabled: true
                readonly property var r: root.localRect(modelData)
                x: r.x * tab.sx
                y: r.y * tab.sx
                width: r.w * tab.sx
                height: r.h * tab.sx
                captureSource: modelData.wayland
                live: false
              }
            }

            Text {
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(5)
              text: tab.modelData.name
              color: tab.viewed ? root.accent : root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: tab.wsId === root.activeWs
              style: Text.Outline
              styleColor: root.bg
            }

            MouseArea {
              id: tabArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.viewedWs = tab.wsId; root.query = ""; root.selected = -1 }
              onDoubleClicked: root.goTo(tab.wsId)
            }
          }
        }

        // New empty workspace: drop a window here or click to go there.
        Rectangle {
          readonly property int wsId: root.newWs
          width: tabs.tabW * 0.5
          height: tabs.tabH
          radius: Style.space(6)
          color: root.dropWs === wsId ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.3) : "transparent"
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, newArea.containsMouse ? 0.5 : 0.2)

          Text {
            anchors.centerIn: parent
            text: "+"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          MouseArea {
            id: newArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.goTo(parent.wsId)
          }
        }
      }
    }

    // Where the spread windows go.
    Item {
      id: area
      anchors.fill: parent
      anchors.topMargin: tabs.y + tabs.height + Style.space(36)
      anchors.bottomMargin: Style.space(64)
      anchors.leftMargin: Style.space(48)
      anchors.rightMargin: Style.space(48)

      Text {
        anchors.centerIn: parent
        visible: root.shownWindows.length === 0
        opacity: chrome.opacity
        text: root.query ? "No matching windows" : "No windows on workspace " + root.viewedWs
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    // ---- window thumbnails
    Repeater {
      model: root.shown ? root.tiles : []

      delegate: Item {
        id: tile
        required property var modelData
        required property int index

        readonly property var o: modelData.lastIpcObject
        readonly property var slot: root.slots[index] || { x: 0, y: 0, w: 0, h: 0 }
        readonly property var real: root.localRect(modelData)
        // Windows already on screen fly between their place and their slot; the
        // rest fade. Picking a window on another workspace flies only that one.
        readonly property bool fromScreen: !root.query && modelData.workspace && modelData.workspace.id === root.startWs
        readonly property bool home: root.picked && root.picked.workspace && root.picked.workspace.id !== root.startWs
          ? root.picked === modelData : fromScreen
        readonly property bool atSlot: root.spread || !home
        readonly property bool hot: root.selected === index
        readonly property bool dragged: root.dragWin === modelData

        x: atSlot ? area.x + slot.x : real.x
        y: atSlot ? area.y + slot.y : real.y
        width: atSlot ? slot.w : real.w
        height: atSlot ? slot.h : real.h
        opacity: dragged ? 0.35 : (home || root.spread ? 1 : 0)
        z: root.picked === modelData ? 3 : hot ? 2 : 1

        Behavior on x { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on width { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on height { NumberAnimation { duration: root.animMs; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: root.animMs } }

        // Captures write their own alpha straight through to the overlay, so a
        // translucent window would show the real desktop behind. A layer makes
        // it blend over the backdrop instead (same on the tab and drag views).
        ScreencopyView {
          anchors.fill: parent
          captureSource: tile.modelData.wayland
          live: true
          layer.enabled: true
        }

        Rectangle {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          radius: Style.space(6)
          color: "transparent"
          border.width: Style.space(3)
          border.color: root.accent
          opacity: tile.hot && root.spread ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        // App icon straddling the bottom edge, falling back to a letter.
        Rectangle {
          id: badge
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.verticalCenter: parent.bottom
          width: Style.space(40)
          height: width
          radius: width / 2
          color: root.bg
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.2)
          opacity: root.spread ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: root.animMs } }

          readonly property string icon: root.iconFor(tile.o.class)

          Image {
            anchors.centerIn: parent
            width: parent.width * 0.7
            height: width
            sourceSize: Qt.size(width * 2, height * 2)
            source: badge.icon
            visible: badge.icon !== ""
          }
          Text {
            anchors.centerIn: parent
            visible: badge.icon === ""
            text: (tile.o.class || "?").charAt(0).toUpperCase()
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }
        }

        Rectangle {
          anchors.top: badge.bottom
          anchors.topMargin: Style.space(6)
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(titleText.implicitWidth + Style.space(20), Math.max(tile.width, Style.space(220)))
          height: titleText.implicitHeight + Style.space(8)
          radius: height / 2
          color: root.bg
          visible: tile.hot && root.spread
          z: 3

          Text {
            id: titleText
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: ((root.query || root.viewedWs === 0) && root.homeWs(tile.modelData) ? root.homeWs(tile.modelData) + "  ·  " : "")
              + (root.isMinimized(tile.modelData) ? "minimized  ·  " : "") + (tile.o.title || tile.o.class || "")
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: root.opened
          cursorShape: Qt.PointingHandCursor
          property point pressAt: Qt.point(0, 0)
          property bool didDrag: false

          onEntered: root.selected = tile.index
          onPressed: function (mouse) { pressAt = Qt.point(mouse.x, mouse.y); didDrag = false }
          onPositionChanged: function (mouse) {
            if (!pressed) return
            if (!root.dragWin && Math.abs(mouse.x - pressAt.x) + Math.abs(mouse.y - pressAt.y) > 8)
              root.dragWin = tile.modelData
            if (root.dragWin) {
              var p = mapToItem(null, mouse.x, mouse.y)
              root.dragPos = p
              root.dropWs = tabs.wsAt(p.x, p.y)
            }
          }
          onReleased: function (mouse) {
            if (!root.dragWin) return
            didDrag = true
            if (root.dropWs) root.moveTo(root.dragWin, root.dropWs)
            root.dragWin = null
            root.dropWs = 0
          }
          onClicked: if (!didDrag) root.activate(tile.modelData)
        }
      }
    }

    // Thumbnail following the cursor while dragging.
    ScreencopyView {
      visible: root.dragWin !== null
      captureSource: root.dragWin ? root.dragWin.wayland : null
      live: true
      layer.enabled: true
      z: 10
      width: Style.space(200)
      height: root.dragWin && root.dragWin.lastIpcObject.size
        ? width * root.dragWin.lastIpcObject.size[1] / Math.max(1, root.dragWin.lastIpcObject.size[0]) : width
      x: root.dragPos.x - width / 2
      y: root.dragPos.y - height / 2
      opacity: 0.85
    }
  }
}
