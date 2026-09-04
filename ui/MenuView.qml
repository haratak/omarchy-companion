import QtQuick
import QtQuick.Controls
import "../CompanionModel.js" as Model
import "Theme.js" as Theme

Item {
    id: root
    property var companionState
    property var onRunAction // function(id)

    readonly property var items: Model.menuItems()

    ListView {
        id: list
        anchors.fill: parent
        anchors.margins: 8
        clip: true
        spacing: 6
        model: root.items

        delegate: Rectangle {
            width: list.width
            height: 52
            radius: 12
            color: ma.containsMouse ? "#1f1f2c" : Theme.panel2
            border.color: "#1affffff"
            border.width: 1

            Row {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 12
                Rectangle {
                    width: 32; height: 32; radius: 8
                    color: "#1a7c6cff"
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                        anchors.centerIn: parent
                        text: modelData.icon || "•"
                        font.pixelSize: 14
                    }
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    Text {
                        text: modelData.label
                        color: Theme.text
                        font.pixelSize: 14
                        font.bold: true
                    }
                    Text {
                        text: modelData.hint || ""
                        color: Theme.muted
                        font.pixelSize: 11
                    }
                }
            }

            MouseArea {
                id: ma
                anchors.fill: parent
                hoverEnabled: true
                onClicked: if (root.onRunAction) root.onRunAction(modelData.id)
            }
        }
    }
}
