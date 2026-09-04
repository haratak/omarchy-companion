import QtQuick
import QtQuick.Controls
import "../CompanionModel.js" as Model
import "Theme.js" as Theme

Item {
    id: root
    property var companionState
    property var onGesture  // function(type, windowId)
    property var onFocusWorkspace // function(id)
    property var onResize // function(id, rect)
    property var onFocusWindow // function(id)

    readonly property var wins: {
        var out = []
        if (!companionState || !companionState.windows) return out
        for (var i = 0; i < companionState.windows.length; i++) {
            var w = companionState.windows[i]
            if (w.workspaceId === companionState.activeWorkspaceId) out.push(w)
        }
        return out
    }

    Column {
        anchors.fill: parent
        spacing: 4

        // Workspace dots
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            height: 22
            Repeater {
                model: companionState && companionState.workspaces ? companionState.workspaces.length : 0
                delegate: Rectangle {
                    property var ws: companionState.workspaces[index]
                    property bool active: ws && ws.id === companionState.activeWorkspaceId
                    property int count: {
                        var c = 0
                        if (!companionState) return 0
                        for (var i = 0; i < companionState.windows.length; i++)
                            if (companionState.windows[i].workspaceId === ws.id) c++
                        return c
                    }
                    width: active ? 22 : 10
                    height: 10
                    radius: 5
                    color: active ? Theme.accent : "#40ffffff"
                    Behavior on width { NumberAnimation { duration: 120 } }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: if (root.onFocusWorkspace) root.onFocusWorkspace(ws.id)
                    }
                    Rectangle {
                        width: 5; height: 5; radius: 2.5
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: -2
                        anchors.topMargin: -3
                        visible: count > 0 && !active
                        color: Theme.accent2
                    }
                }
            }
        }

        // Stage canvas
        Rectangle {
            id: canvas
            width: parent.width - 8
            anchors.horizontalCenter: parent.horizontalCenter
            height: parent.height - 28
            radius: 16
            color: "#0d0d14"
            border.color: "#14ffffff"
            border.width: 1
            clip: true

            // Empty-stage swipe
            MouseArea {
                id: emptyArea
                anchors.fill: parent
                property real sx: 0
                property real sy: 0
                property real st: 0
                property bool holding: false
                property bool fired: false
                property var holdTimer
                onPressed: function(mouse) {
                    sx = mouse.x; sy = mouse.y; st = Date.now()
                    holding = false; fired = false
                    holdTimer = Qt.createQmlObject(
                        'import QtQuick; Timer { interval: 280; running: true; repeat: false }',
                        emptyArea, "holdT")
                    holdTimer.triggered.connect(function() { emptyArea.holding = true })
                }
                onPositionChanged: function(mouse) {
                    if (fired) return
                    var dx = mouse.x - sx, dy = mouse.y - sy
                    if (!holding) {
                        if (Model.shouldCancelHold(dx, dy) && holdTimer) {
                            holdTimer.stop(); holdTimer.destroy(); holdTimer = null
                        }
                        return
                    }
                    var g = Model.classifyGesture(dx, dy, Date.now() - st, true, false)
                    if (g.type !== "none") {
                        fired = true
                        if (root.onGesture) root.onGesture(g.type, null)
                    }
                }
                onReleased: function(mouse) {
                    var dx = mouse.x - sx, dy = mouse.y - sy
                    var dt = Date.now() - st
                    var wasHold = holding
                    var already = fired
                    if (holdTimer) { holdTimer.stop(); holdTimer.destroy(); holdTimer = null }
                    holding = false; fired = false
                    if (already) return
                    var g = Model.classifyGesture(dx, dy, dt, wasHold, false)
                    if (g.type !== "none" && root.onGesture) root.onGesture(g.type, null)
                }

                Text {
                    anchors.centerIn: parent
                    visible: root.wins.length === 0
                    color: "#59ffffff"
                    horizontalAlignment: Text.AlignHCenter
                    text: "Empty workspace\nSwipe ← → to change · Menu to launch"
                    font.pixelSize: 12
                }
            }

            Repeater {
                model: root.wins
                delegate: WindowTile {
                    win: modelData
                    focused: companionState && modelData.id === companionState.focusedWindowId
                    canvasWidth: canvas.width
                    canvasHeight: canvas.height
                    onTap: if (root.onFocusWindow) root.onFocusWindow(win.id)
                    onGesture: function(type) { if (root.onGesture) root.onGesture(type, win.id) }
                    onResizeRect: function(rect) { if (root.onResize) root.onResize(win.id, rect) }
                }
            }

            Text {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: 8
                color: "#40ffffff"
                font.pixelSize: 10
                text: "Hold+→ spawn · Hold+↑ float · Hold+↓ fullscreen · Corner resize"
            }
        }
    }

    component WindowTile: Item {
        id: tile
        property var win
        property bool focused
        property real canvasWidth
        property real canvasHeight
        signal tap()
        signal gesture(string type)
        signal resizeRect(var rect)

        x: (win.mode === "fullscreen" ? 0 : win.rect.x) * canvasWidth
        y: (win.mode === "fullscreen" ? 0 : win.rect.y) * canvasHeight
        width: (win.mode === "fullscreen" ? 1 : win.rect.w) * canvasWidth
        height: (win.mode === "fullscreen" ? 1 : win.rect.h) * canvasHeight
        z: win.mode === "fullscreen" ? 20 : (win.mode === "floating" ? 15 : (focused ? 5 : 1))

        Rectangle {
            anchors.fill: parent
            anchors.margins: 4
            radius: 12
            color: "#14141e"
            border.color: focused ? "#b37c6cff" : "#1affffff"
            border.width: focused ? 2 : 1

            Column {
                anchors.fill: parent
                anchors.margins: 0
                Rectangle {
                    width: parent.width
                    height: 28
                    color: "transparent"
                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        spacing: 6
                        Rectangle {
                            width: appLabel.implicitWidth + 10
                            height: 16
                            radius: 4
                            color: win.color || Theme.accent
                            Text {
                                id: appLabel
                                anchors.centerIn: parent
                                text: (win.app || "?").toUpperCase()
                                font.pixelSize: 9
                                font.bold: true
                                color: "#000000"
                            }
                        }
                        Text {
                            text: win.title || ""
                            color: "#b3ffffff"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            width: Math.max(40, tile.width - 100)
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: win.mode !== "tiled"
                        text: (win.mode || "").toUpperCase()
                        color: "#80ffffff"
                        font.pixelSize: 9
                    }
                }
                Text {
                    width: parent.width - 12
                    height: parent.height - 32
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: (win.content || "").slice(-180)
                    color: "#8cffffff"
                    font.pixelSize: 10
                    font.family: "monospace"
                    wrapMode: Text.Wrap
                    clip: true
                }
            }

            // Gesture area
            MouseArea {
                id: gma
                anchors.fill: parent
                anchors.rightMargin: 22
                anchors.bottomMargin: 22
                property real sx: 0
                property real sy: 0
                property real st: 0
                property bool holding: false
                property bool fired: false
                property var holdTimer
                onPressed: function(mouse) {
                    sx = mouse.x; sy = mouse.y; st = Date.now()
                    holding = false; fired = false
                    holdTimer = Qt.createQmlObject(
                        'import QtQuick; Timer { interval: 280; running: true; repeat: false }',
                        gma, "holdTW")
                    holdTimer.triggered.connect(function() { gma.holding = true })
                }
                onPositionChanged: function(mouse) {
                    if (fired) return
                    var dx = mouse.x - sx, dy = mouse.y - sy
                    if (!holding) {
                        if (Model.shouldCancelHold(dx, dy) && holdTimer) {
                            holdTimer.stop(); holdTimer.destroy(); holdTimer = null
                        }
                        return
                    }
                    var g = Model.classifyGesture(dx, dy, Date.now() - st, true, false)
                    if (g.type !== "none") {
                        fired = true
                        tile.gesture(g.type)
                    }
                }
                onReleased: function(mouse) {
                    var dx = mouse.x - sx, dy = mouse.y - sy
                    var dt = Date.now() - st
                    var wasHold = holding
                    var already = fired
                    if (holdTimer) { holdTimer.stop(); holdTimer.destroy(); holdTimer = null }
                    holding = false; fired = false
                    if (already) return
                    var g = Model.classifyGesture(dx, dy, dt, wasHold, false)
                    if (g.type === "tap") tile.tap()
                    else if (g.type !== "none") tile.gesture(g.type)
                }
            }

            // Resize grip
            MouseArea {
                id: grip
                width: 22; height: 22
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                cursorShape: Qt.SizeFDiagCursor
                property real sx: 0
                property real sy: 0
                property var startRect
                onPressed: function(mouse) {
                    sx = mouse.x; sy = mouse.y
                    startRect = {
                        x: win.rect.x, y: win.rect.y, w: win.rect.w, h: win.rect.h
                    }
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var dx = (mouse.x - sx) / canvasWidth
                    var dy = (mouse.y - sy) / canvasHeight
                    tile.resizeRect({
                        x: startRect.x,
                        y: startRect.y,
                        w: Math.min(1 - startRect.x, Math.max(0.15, startRect.w + dx)),
                        h: Math.min(1 - startRect.y, Math.max(0.15, startRect.h + dy))
                    })
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 4
                    width: 10; height: 10
                    color: "transparent"
                    border.color: "#59ffffff"
                    border.width: 2
                    radius: 2
                }
            }
        }
    }
}
