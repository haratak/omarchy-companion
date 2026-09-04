import QtQuick
import "../CompanionModel.js" as Model
import "Theme.js" as Theme

Item {
    id: root
    property var companionState
    property var onTypeText   // function(text)
    property var onSendKey    // function(key, mods)
    property var onPointer    // function(action, x, y)
    property var onMovePointer // function(x, y)

    property var mods: ({ super: false, alt: false, ctrl: false, shift: false })
    property bool shifted: false

    readonly property var rows: [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["⇧", "z", "x", "c", "v", "b", "n", "m", "⌫"],
        ["Ctrl", "Alt", "Super", "␣", "Tab", "Esc", "↵"]
    ]

    function toggleMod(key) {
        var m = {
            super: mods.super, alt: mods.alt, ctrl: mods.ctrl, shift: mods.shift
        }
        m[key] = !m[key]
        mods = m
    }

    function typeKey(label) {
        if (label === "⇧") {
            shifted = !shifted
            toggleMod("shift")
            return
        }
        if (label === "Ctrl") return toggleMod("ctrl")
        if (label === "Alt") return toggleMod("alt")
        if (label === "Super") return toggleMod("super")
        if (label === "Tab") { if (onSendKey) onSendKey("Tab", mods); return }
        if (label === "Esc") { if (onSendKey) onSendKey("Escape", mods); return }
        if (label === "⌫") { if (onSendKey) onSendKey("Backspace", mods); return }
        if (label === "↵") { if (onSendKey) onSendKey("Enter", mods); return }
        if (label === "␣") {
            if (mods.super) {
                if (onSendKey) onSendKey(" ", { super: true })
                var m = Object.assign({}, mods); m.super = false; mods = m
                return
            }
            if (onTypeText) onTypeText(" ")
            return
        }
        var ch = label
        if (shifted || mods.shift) ch = ch.toUpperCase()
        if (mods.super && (ch === "w" || ch === "W")) {
            if (onSendKey) onSendKey("w", { super: true })
            var m2 = Object.assign({}, mods); m2.super = false; mods = m2
            return
        }
        if (onTypeText) onTypeText(ch)
        if (shifted) {
            shifted = false
            var m3 = Object.assign({}, mods); m3.shift = false; mods = m3
        }
    }

    Row {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 8

        // Keyboard / trackpad
        Rectangle {
            id: pad
            width: parent.width * 0.66
            height: parent.height
            radius: 16
            color: "#101018"
            border.color: "#1affffff"
            clip: true

            property var pointers: ({})
            property string mode: "idle"
            property real lastX: 0
            property real lastY: 0
            property real tapX: 0
            property real tapY: 0
            property real tapT: 0
            property bool centerHeld: false

            Text {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: 6
                color: "#40ffffff"
                font.pixelSize: 9
                text: "1-finger move · 2-finger scroll · tap keys"
            }

            Column {
                id: keysCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6
                spacing: 4
                z: 2

                Repeater {
                    model: root.rows.length
                    delegate: Row {
                        property var rowKeys: root.rows[index]
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 4
                        Repeater {
                            model: rowKeys.length
                            delegate: Rectangle {
                                property string label: rowKeys[index]
                                property bool isMod: label === "⇧" || label === "Ctrl" || label === "Alt" || label === "Super"
                                property bool active:
                                    (label === "⇧" && (root.shifted || root.mods.shift)) ||
                                    (label === "Ctrl" && root.mods.ctrl) ||
                                    (label === "Alt" && root.mods.alt) ||
                                    (label === "Super" && root.mods.super)
                                width: label === "␣" ? 72 : (label.length > 1 ? 40 : 28)
                                height: 34
                                radius: 8
                                color: active ? "#4d7c6cff" : (isMod ? "#14ffffff" : "#0dffffff")
                                border.color: active ? "#997c6cff" : "#14ffffff"
                                Text {
                                    anchors.centerIn: parent
                                    text: label === "␣" ? "" : (root.shifted && label.length === 1 ? label.toUpperCase() : label)
                                    color: "#e6ffffff"
                                    font.pixelSize: 12
                                    font.bold: isMod
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onPressed: function(mouse) {
                                        mouse.accepted = true
                                        root.typeKey(label)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Trackpad layer behind keys (top half)
            MouseArea {
                id: track
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: parent.height - keysCol.height - 16
                property int fingerCount: 0
                property real lx: 0
                property real ly: 0
                property real sx: 0
                property real sy: 0
                property real st: 0

                onPressed: function(mouse) {
                    fingerCount = 1
                    lx = mouse.x; ly = mouse.y
                    sx = mouse.x; sy = mouse.y; st = Date.now()
                    pad.mode = pad.centerHeld ? "drag" : "move"
                }
                onPositionChanged: function(mouse) {
                    var dx = mouse.x - lx
                    var dy = mouse.y - ly
                    lx = mouse.x; ly = mouse.y
                    var sens = 0.0018
                    var px = companionState && companionState.pointer ? companionState.pointer.x : 0.5
                    var py = companionState && companionState.pointer ? companionState.pointer.y : 0.5
                    if (pad.mode === "move" || pad.mode === "drag") {
                        if (root.onMovePointer) root.onMovePointer(px + dx * sens, py + dy * sens)
                    } else if (pad.mode === "scroll") {
                        if (root.onPointer) root.onPointer("scroll", 0, dy * 0.4)
                    }
                }
                onReleased: function(mouse) {
                    if (Date.now() - st < 220 && Math.hypot(mouse.x - sx, mouse.y - sy) < 8 && !pad.centerHeld) {
                        if (root.onPointer) root.onPointer("click", 0, 0)
                    }
                    fingerCount = 0
                    pad.mode = "idle"
                }
                // Approximate 2-finger: wheel events
                onWheel: function(wheel) {
                    if (root.onPointer) root.onPointer("scroll", 0, -wheel.angleDelta.y * 0.1)
                }
            }
        }

        // D-pad column
        Column {
            width: parent.width * 0.32
            height: parent.height
            spacing: 8

            Grid {
                columns: 3
                spacing: 4
                width: parent.width
                Item { width: parent.width / 3 - 3; height: 36 }
                PadBtn { label: "▲"; onClicked: root.nudge(0, -0.04) }
                Item { width: parent.width / 3 - 3; height: 36 }
                PadBtn { label: "◀"; onClicked: root.nudge(-0.04, 0) }
                Rectangle {
                    width: parent.width / 3 - 3
                    height: 36
                    radius: 18
                    color: "#407c6cff"
                    border.color: "#667c6cff"
                    Text {
                        anchors.centerIn: parent
                        text: "CLICK"
                        color: "#e0dfff"
                        font.pixelSize: 9
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        onPressed: {
                            pad.centerHeld = true
                            if (root.onPointer) root.onPointer("click", 0, 0)
                        }
                        onReleased: pad.centerHeld = false
                        onCanceled: pad.centerHeld = false
                    }
                }
                PadBtn { label: "▶"; onClicked: root.nudge(0.04, 0) }
                Item { width: parent.width / 3 - 3; height: 36 }
                PadBtn { label: "▼"; onClicked: root.nudge(0, 0.04) }
                Item { width: parent.width / 3 - 3; height: 36 }
            }

            Grid {
                columns: 2
                spacing: 4
                width: parent.width
                Repeater {
                    model: [
                        { label: "Super", key: "super" },
                        { label: "Alt", key: "alt" },
                        { label: "Ctrl", key: "ctrl" },
                        { label: "Shift", key: "shift" }
                    ]
                    delegate: Rectangle {
                        width: parent.width / 2 - 2
                        height: 32
                        radius: 8
                        color: root.mods[modelData.key] ? "#407fd1c5" : "#0dffffff"
                        border.color: root.mods[modelData.key] ? "#807fd1c5" : "#1affffff"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            color: "#e6ffffff"
                            font.pixelSize: 11
                            font.bold: true
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.toggleMod(modelData.key)
                        }
                    }
                }
            }

            Row {
                spacing: 4
                width: parent.width
                Rectangle {
                    width: parent.width / 2 - 2
                    height: 32
                    radius: 8
                    color: "#0dffffff"
                    border.color: "#1affffff"
                    Text { anchors.centerIn: parent; text: "Tab"; color: "#ccffffff"; font.pixelSize: 11 }
                    MouseArea { anchors.fill: parent; onClicked: if (root.onSendKey) root.onSendKey("Tab", root.mods) }
                }
                Rectangle {
                    width: parent.width / 2 - 2
                    height: 32
                    radius: 8
                    color: "#0dffffff"
                    border.color: "#1affffff"
                    Text { anchors.centerIn: parent; text: "Esc"; color: "#ccffffff"; font.pixelSize: 11 }
                    MouseArea { anchors.fill: parent; onClicked: if (root.onSendKey) root.onSendKey("Escape", root.mods) }
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                color: "#4dffffff"
                font.pixelSize: 9
                text: "Super+Space menu · Super+W close · Hold CLICK + drag = select"
            }
        }
    }

    function nudge(dx, dy) {
        var px = companionState && companionState.pointer ? companionState.pointer.x : 0.5
        var py = companionState && companionState.pointer ? companionState.pointer.y : 0.5
        if (onMovePointer) onMovePointer(px + dx, py + dy)
    }

    component PadBtn: Rectangle {
        property string label
        signal clicked()
        width: parent.width / 3 - 3
        height: 36
        radius: 10
        color: "#14ffffff"
        border.color: "#1affffff"
        Text {
            anchors.centerIn: parent
            text: label
            color: "#ccffffff"
            font.pixelSize: 14
        }
        MouseArea {
            anchors.fill: parent
            onClicked: parent.clicked()
        }
    }
}
