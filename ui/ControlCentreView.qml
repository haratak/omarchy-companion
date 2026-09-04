import QtQuick
import QtQuick.Controls
import "Theme.js" as Theme

Item {
    id: root
    property var companionState
    property var onSetSystem // function(kind, value)

    readonly property real volume: companionState && companionState.system ? companionState.system.volume : 50
    readonly property real brightness: companionState && companionState.system ? companionState.system.brightness : 50
    readonly property bool wifi: companionState && companionState.system ? companionState.system.wifi : false
    readonly property bool bluetooth: companionState && companionState.system ? companionState.system.bluetooth : false

    Column {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 18

        Text {
            text: "Control Centre"
            color: Theme.text
            font.pixelSize: 18
            font.bold: true
        }

        // Volume
        Column {
            width: parent.width
            spacing: 6
            Text { text: "Volume  " + Math.round(root.volume) + "%"; color: Theme.muted; font.pixelSize: 12 }
            Slider {
                id: vol
                width: parent.width
                from: 0; to: 100
                value: root.volume
                onMoved: if (root.onSetSystem) root.onSetSystem("volume", value)
                background: Rectangle {
                    x: vol.leftPadding
                    y: vol.topPadding + vol.availableHeight / 2 - height / 2
                    implicitWidth: 200
                    implicitHeight: 6
                    width: vol.availableWidth
                    height: 6
                    radius: 3
                    color: "#2a2a3a"
                    Rectangle {
                        width: vol.visualPosition * parent.width
                        height: parent.height
                        radius: 3
                        color: Theme.accent
                    }
                }
                handle: Rectangle {
                    x: vol.leftPadding + vol.visualPosition * (vol.availableWidth - width)
                    y: vol.topPadding + vol.availableHeight / 2 - height / 2
                    width: 18; height: 18; radius: 9
                    color: Theme.text
                }
            }
        }

        // Brightness
        Column {
            width: parent.width
            spacing: 6
            Text { text: "Brightness  " + Math.round(root.brightness) + "%"; color: Theme.muted; font.pixelSize: 12 }
            Slider {
                id: bri
                width: parent.width
                from: 0; to: 100
                value: root.brightness
                onMoved: if (root.onSetSystem) root.onSetSystem("brightness", value)
                background: Rectangle {
                    x: bri.leftPadding
                    y: bri.topPadding + bri.availableHeight / 2 - height / 2
                    implicitWidth: 200
                    implicitHeight: 6
                    width: bri.availableWidth
                    height: 6
                    radius: 3
                    color: "#2a2a3a"
                    Rectangle {
                        width: bri.visualPosition * parent.width
                        height: parent.height
                        radius: 3
                        color: Theme.accent2
                    }
                }
                handle: Rectangle {
                    x: bri.leftPadding + bri.visualPosition * (bri.availableWidth - width)
                    y: bri.topPadding + bri.availableHeight / 2 - height / 2
                    width: 18; height: 18; radius: 9
                    color: Theme.text
                }
            }
        }

        Row {
            spacing: 10
            width: parent.width
            ToggleCard {
                width: parent.width / 2 - 5
                title: "Wi-Fi"
                subtitle: root.wifi ? "On" : "Off"
                active: root.wifi
                onToggled: if (root.onSetSystem) root.onSetSystem("wifi", !root.wifi)
            }
            ToggleCard {
                width: parent.width / 2 - 5
                title: "Bluetooth"
                subtitle: root.bluetooth ? "On" : "Off"
                active: root.bluetooth
                onToggled: if (root.onSetSystem) root.onSetSystem("bluetooth", !root.bluetooth)
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: Theme.muted
            font.pixelSize: 11
            text: "Volume uses wpctl; brightness uses brightnessctl when available. Wi-Fi / Bluetooth are stubs in v0.1."
        }
    }

    component ToggleCard: Rectangle {
        property string title
        property string subtitle
        property bool active
        signal toggled()
        height: 72
        radius: 14
        color: active ? "#2a2450" : Theme.panel2
        border.color: active ? Theme.accent : "#1affffff"
        Column {
            anchors.centerIn: parent
            spacing: 4
            Text { text: title; color: Theme.text; font.pixelSize: 14; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
            Text { text: subtitle; color: Theme.muted; font.pixelSize: 11; anchors.horizontalCenter: parent.horizontalCenter }
        }
        MouseArea { anchors.fill: parent; onClicked: parent.toggled() }
    }
}
