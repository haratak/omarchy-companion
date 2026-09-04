import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "harataku.companion"

  property bool clientConnected: false
  property int clientCount: 0
  property bool bridgeRunning: false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
    else if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "Pad"
    active: root.opened
    horizontalMargin: 8.5
    tooltipText: ""

    onPressed: function(b) {
      if (!root.bar) return
      root.togglePanel()
    }

    // Status dot: teal = phone connected, amber = bridge up, purple = panel open
    Rectangle {
      width: 6
      height: 6
      radius: 3
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: 2
      anchors.topMargin: 4
      visible: root.opened || root.clientConnected || root.bridgeRunning
      color: root.clientConnected ? "#4fd1c5" : (root.bridgeRunning ? "#fbbf24" : "#7c6cff")
      z: 2
    }
  }

  function refreshBridgeHint() {
    var got = false
    try {
      var sh = root.bar && root.bar.shell ? root.bar.shell : null
      var svc = sh && typeof sh.serviceFor === "function" ? sh.serviceFor("harataku.companion") : null
      if (svc && typeof svc.pairInfo === "function") {
        var pi = JSON.parse(String(svc.pairInfo() || "{}"))
        root.clientCount = Number(pi.clients || 0)
        root.clientConnected = root.clientCount > 0
        root.bridgeRunning = !!pi.running
        got = true
      } else if (sh && typeof sh.call === "function") {
        var raw = sh.call("harataku.companion", "pairInfo", "")
        if (raw && raw !== "unknown" && raw !== "error") {
          var info = JSON.parse(String(raw))
          root.clientCount = Number(info.clients || 0)
          root.clientConnected = root.clientCount > 0
          root.bridgeRunning = !!info.running
          got = true
        }
      }
    } catch (e) {}
    if (!got) {
      statusReadProcess.running = false
      statusReadProcess.running = true
    }
  }

  Process {
    id: statusReadProcess
    running: false
    command: ["sh", "-c", "test -f /tmp/omarchy-companion-bridge.json && cat /tmp/omarchy-companion-bridge.json || echo ''"]
    stdout: StdioCollector {
      onStreamFinished: {
        var raw = String(this.text || "").trim()
        if (!raw) return
        try {
          var info = JSON.parse(raw)
          root.clientCount = Number(info.clients || 0)
          root.clientConnected = root.clientCount > 0
          root.bridgeRunning = true
        } catch (e) {}
      }
    }
  }

  Timer {
    interval: 1500
    running: true
    repeat: true
    onTriggered: root.refreshBridgeHint()
  }
}
