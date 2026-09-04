import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "CompanionModel.js" as Model
import "ui/Theme.js" as Theme
import "ui"

Panel {
  id: root
  moduleName: "harataku.companion"
  ipcTarget: "harataku.companion"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property string activeTab: "pairing" // pairing | stage | input | menu | control
  property var companionState: Model.createInitialState()
  property bool mockMode: true
  property var pairInfo: ({ running: false, url: "", token: "", port: 17832, clients: 0, host: "" })
  property string qrUrl: ""
  property string qrEncodedFor: ""

  function open() {
    root.controller.show()
    if (!root.activeTab) root.activeTab = "pairing"
    root.pullStatus()
  }

  function openFromHotkey() {
    root.controller.show()
    root.pullStatus()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function serviceInstance() {
    var sh = root.bar && root.bar.shell ? root.bar.shell : null
    if (sh && typeof sh.serviceFor === "function")
      return sh.serviceFor("harataku.companion")
    return null
  }

  function pullStatus() {
    try {
      var svc = root.serviceInstance()
      if (svc) {
        if (typeof svc.snapshotJson === "function") {
          var snap = JSON.parse(String(svc.snapshotJson() || "{}"))
          root.applySnapshot(snap)
        }
        if (typeof svc.pairInfo === "function") {
          root.pairInfo = JSON.parse(String(svc.pairInfo() || "{}"))
          root.refreshQr()
        }
        return
      }
      var sh = root.bar && root.bar.shell ? root.bar.shell : null
      if (sh && typeof sh.call === "function") {
        var raw = sh.call("harataku.companion", "status", "")
        if (raw && raw !== "unknown" && raw !== "error") {
          root.applySnapshot(JSON.parse(String(raw)))
        }
        var pi = sh.call("harataku.companion", "pairInfo", "")
        if (pi && pi !== "unknown" && pi !== "error") {
          root.pairInfo = JSON.parse(String(pi))
          root.refreshQr()
        }
        return
      }
    } catch (e) {
      console.warn("[harataku.companion] pullStatus failed", e)
    }
    if (!root.companionState.windows || root.companionState.windows.length === 0)
      root.companionState = Model.createInitialState()
    root.mockMode = !!root.companionState.mockMode
  }

  Timer {
    id: pairInfoPoll
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.pullPairInfo()
  }

  function pullPairInfo() {
    try {
      var sh = Quickshell
      if (!sh || typeof sh.call !== "function") return
      var pi = sh.call("harataku.companion", "pairInfo", "")
      if (pi) {
        var next = JSON.parse(String(pi))
        var prevUrl = root.pairInfo && root.pairInfo.url ? String(root.pairInfo.url) : ""
        var nextUrl = next && next.url ? String(next.url) : ""
        root.pairInfo = next
        if (nextUrl !== prevUrl)
          root.refreshQr()
        else if (next && next.running && root.qrUrl === "" && nextUrl)
          root.refreshQr()
      }
    } catch (e) {}
  }

  function refreshQr() {
    if (!(root.pairInfo && root.pairInfo.running && root.pairInfo.url)) {
      root.qrUrl = ""
      root.qrEncodedFor = ""
      return
    }
    var url = String(root.pairInfo.url)
    if (url === root.qrEncodedFor && root.qrUrl !== "")
      return
    qrEncodeProc.running = false
    qrEncodeProc.command = [
      "qrencode", "-t", "PNG", "-s", "8", "-m", "2",
      "-o", "/tmp/omarchy-companion-qr.png",
      url
    ]
    console.log("[harataku.companion] encoding QR", url)
    qrEncodeProc.running = true
  }

  Process {
    id: qrEncodeProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.qrEncodedFor = root.pairInfo && root.pairInfo.url ? String(root.pairInfo.url) : ""
        // Stable file URL (no cache-busting query) — Image.cache true avoids flicker
        var nextSrc = "file:///tmp/omarchy-companion-qr.png"
        if (root.qrUrl !== nextSrc)
          root.qrUrl = nextSrc
      } else {
        console.warn("[harataku.companion] qrencode failed", exitCode)
        root.qrEncodedFor = ""
        if (root.pairInfo && root.pairInfo.port)
          root.qrUrl = "https://127.0.0.1:" + root.pairInfo.port + "/qr.png?t=" + Date.now()
        else
          root.qrUrl = ""
      }
    }
  }

    function startBridge() {
    root.callService("startBridge")
    Qt.callLater(root.pullStatus)
  }

  function stopBridge() {
    root.callService("stopBridge")
    Qt.callLater(root.pullStatus)
  }

  function applySnapshot(snap) {
    if (!snap) return
    root.mockMode = !!snap.mockMode
    var windows = (snap.windows || []).map(function (w) {
      return {
        id: String(w.id),
        title: w.title || "",
        app: w.app || w.class || "App",
        className: w.class || "",
        color: Model.appColor(w.app || w.class || "App"),
        workspaceId: w.workspace != null ? w.workspace : 1,
        mode: w.mode || (w.fullscreen ? "fullscreen" : (w.floating ? "floating" : "tiled")),
        floating: !!w.floating,
        fullscreen: !!w.fullscreen,
        rect: w.rect || { x: 0, y: 0, w: 1, h: 1 },
        content: w.content || "",
        scrollY: w.scrollY || 0
      }
    })
    root.companionState = {
      workspaces: snap.workspaces || root.companionState.workspaces,
      activeWorkspaceId: snap.activeWorkspaceId || 1,
      windows: windows.length ? windows : root.companionState.windows,
      focusedWindowId: snap.focusedWindowId,
      pointer: snap.pointer || root.companionState.pointer,
      system: snap.system || root.companionState.system,
      menuOpen: !!snap.menuOpen,
      lastAction: snap.lastAction || "",
      mockMode: !!snap.mockMode,
      panelOpen: root.opened,
      activeTab: root.activeTab
    }
    if (snap.bridge) root.pairInfo = snap.bridge
  }

  function callService(method, a, b, c) {
    try {
      var svc = root.serviceInstance()
      if (svc && typeof svc[method] === "function") {
        if (c !== undefined) return svc[method](String(a), String(b), String(c))
        if (b !== undefined) return svc[method](String(a), String(b))
        if (a !== undefined) return svc[method](String(a))
        return svc[method]()
      }
      var sh = root.bar && root.bar.shell ? root.bar.shell : null
      if (sh && typeof sh.call === "function") {
        var arg = a !== undefined ? String(a) : ""
        return sh.call("harataku.companion", method, arg)
      }
    } catch (e) {
      console.warn("[harataku.companion] call failed", method, e)
    }
    return null
  }

  function handleGesture(type, windowId) {
    var result = Model.applyStageGesture(root.companionState, type, windowId)
    root.companionState = result.state
    for (var i = 0; i < result.commands.length; i++) {
      var c = result.commands[i]
      if (c.op === "focusWorkspace") callService("focusWorkspace", c.id)
      else if (c.op === "toggleFloat") callService("toggleFloat")
      else if (c.op === "toggleFullscreen") callService("toggleFullscreen")
      else if (c.op === "spawn") {
        var map = { Terminal: "kitty", Browser: "chromium", Editor: "code", Files: "nautilus" }
        callService("spawn", map[c.app] || String(c.app).toLowerCase())
      }
    }
  }

  function handleMenu(id) {
    root.companionState = Model.runMenuAction(root.companionState, id)
    if (id.indexOf("workspace-") === 0) {
      callService("focusWorkspace", id.split("-")[1])
    } else if (id === "terminal") callService("spawn", "kitty")
    else if (id === "browser") callService("spawn", "chromium")
    else if (id === "editor") callService("spawn", "code")
    else if (id === "files") callService("spawn", "nautilus")
    else if (id === "lock") callService("spawn", "omarchy-lock-screen")
    else if (id === "logout") callService("key", "Super+Escape")
    root.activeTab = "stage"
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.pullStatus()
  }

  Component.onCompleted: {
    if (!root.companionState || !root.companionState.windows || root.companionState.windows.length === 0)
      root.companionState = Model.createInitialState()
    root.mockMode = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Panel chrome
      Rectangle {
        id: chrome
        anchors.fill: parent
        color: Theme.bg
        radius: Style.cornerRadius

        // Header
        Rectangle {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 48
          color: Theme.panel

          Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
              text: "Companion"
              color: Theme.text
              font.pixelSize: 16
              font.bold: true
            }
            Text {
              id: versionLabel
              anchors.verticalCenter: parent.verticalCenter
              text: {
                var v = root.pairInfo && root.pairInfo.version ? String(root.pairInfo.version) : "0.4.9"
                return "v" + v.replace(/^v/, "")
              }
              color: Theme.muted
              font.pixelSize: 10
            }
            Rectangle {
              width: mockLabel.implicitWidth + 12
              height: 20
              radius: 6
              color: root.mockMode ? "#332a1a" : "#1a2a24"
              anchors.verticalCenter: parent.verticalCenter
              Text {
                id: mockLabel
                anchors.centerIn: parent
                text: root.mockMode ? "MOCK" : "LIVE"
                color: root.mockMode ? "#fbbf24" : Theme.accent2
                font.pixelSize: 10
                font.bold: true
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Rectangle {
              width: 36; height: 32; radius: 8
              color: root.activeTab === "control" ? "#2a2450" : "#1a1a26"
              border.color: root.activeTab === "control" ? Theme.accent : Theme.border
              Text { anchors.centerIn: parent; text: "⚙"; font.pixelSize: 14 }
              MouseArea {
                anchors.fill: parent
                onClicked: root.activeTab = root.activeTab === "control" ? "stage" : "control"
              }
            }
            Rectangle {
              width: 36; height: 32; radius: 8
              color: "#1a1a26"
              border.color: Theme.border
              Text { anchors.centerIn: parent; text: "✕"; color: Theme.muted; font.pixelSize: 14 }
              MouseArea { anchors.fill: parent; onClicked: root.close() }
            }
          }

          Text {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.bottomMargin: 2
            text: companionState.lastAction || ""
            color: Theme.muted
            font.pixelSize: 10
            width: parent.width - 100
            elide: Text.ElideRight
          }
        }

        // Body
        Item {
          id: body
          anchors.top: header.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: nav.top

          Flickable {
            anchors.fill: parent
            visible: root.activeTab === "pairing"
            contentHeight: pairCol.height + 24
            clip: true
            Column {
              id: pairCol
              width: parent.width
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: 14
              spacing: 12

              Text {
                text: "Phone pairing"
                color: Theme.text
                font.pixelSize: 18
                font.bold: true
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Start bridge → scan QR (HTTPS). Accept the cert warning once on phone, then Install / Add to Home Screen. Tailscale ON if Wi‑Fi isolates devices."
                color: Theme.muted
                font.pixelSize: 12
              }

              Row {
                spacing: 8
                Rectangle {
                  width: startLbl.implicitWidth + 24
                  height: 40
                  radius: 10
                  color: root.pairInfo.running ? "#1a2a24" : Theme.accent
                  Text {
                    id: startLbl
                    anchors.centerIn: parent
                    text: root.pairInfo.running ? "Bridge running" : "Start bridge"
                    color: "#fff"
                    font.bold: true
                    font.pixelSize: 13
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.pairInfo.running
                    onClicked: root.startBridge()
                  }
                }
                Rectangle {
                  width: stopLbl.implicitWidth + 24
                  height: 40
                  radius: 10
                  color: "#1a1a26"
                  border.color: Theme.border
                  visible: !!root.pairInfo.running
                  Text {
                    id: stopLbl
                    anchors.centerIn: parent
                    text: "Stop"
                    color: Theme.danger
                    font.bold: true
                    font.pixelSize: 13
                  }
                  MouseArea { anchors.fill: parent; onClicked: root.stopBridge() }
                }
              }

              Rectangle {
                width: parent.width
                height: clientsRow.height + 16
                radius: 10
                color: Theme.panel2
                border.color: Theme.border
                Row {
                  id: clientsRow
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 10
                  Rectangle {
                    width: 8; height: 8; radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    color: (root.pairInfo.clients || 0) > 0 ? Theme.accent2 : Theme.muted
                  }
                  Text {
                    text: (root.pairInfo.clients || 0) > 0 ? ((root.pairInfo.clients || 0) + " phone linked (WebSocket)") : (root.pairInfo.running ? "Waiting for phone link (Pad UI alone is not enough — need Online)" : "stopped")
                    color: Theme.text
                    font.pixelSize: 13
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: root.pairInfo.running ? ("port " + (root.pairInfo.port || "")) : "stopped"
                    color: Theme.muted
                    font.pixelSize: 12
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              Text {
                text: "LAN URL"
                color: Theme.muted
                font.pixelSize: 11
                font.bold: true
              }
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: root.pairInfo.url || "(start bridge to get URL)"
                color: Theme.accent2
                font.pixelSize: 12
                font.family: "monospace"
              }
              Text {
                text: "Token"
                color: Theme.muted
                font.pixelSize: 11
                font.bold: true
              }
              Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                text: root.pairInfo.token || "—"
                color: Theme.text
                font.pixelSize: 12
                font.family: "monospace"
              }

              Text {
                visible: !!root.pairInfo.running
                text: "Scan with phone camera"
                color: Theme.muted
                font.pixelSize: 11
                font.bold: true
              }
              Rectangle {
                visible: root.qrUrl !== ""
                width: Math.min(parent.width - 8, 260)
                height: width
                radius: 12
                color: "#ffffff"
                anchors.horizontalCenter: parent.horizontalCenter
                Image {
                  anchors.fill: parent
                  anchors.margins: 12
                  source: root.qrUrl
                  fillMode: Image.PreserveAspectFit
                  asynchronous: false
                  cache: true
                  smooth: false
                }
              }
              Text {
                visible: root.qrUrl === "" && !!root.pairInfo.running
                width: parent.width
                wrapMode: Text.Wrap
                text: "Generating QR… if this stays empty, install qrencode or open the LAN URL below."
                color: Theme.muted
                font.pixelSize: 11
              }

              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "VoiceBox default combo on phone Keys tab: SUPER+SHIFT+V — edit it to match your real bind."
                color: Theme.muted
                font.pixelSize: 11
              }
            }
          }

          StageView {
            anchors.fill: parent
            visible: root.activeTab === "stage"
            companionState: root.companionState
            onGesture: function(type, windowId) { root.handleGesture(type, windowId) }
            onFocusWorkspace: function(id) {
              root.companionState = Model.setActiveWorkspace(root.companionState, id)
              root.callService("focusWorkspace", id)
            }
            onFocusWindow: function(id) {
              root.companionState = Model.focusWindow(root.companionState, id)
            }
            onResize: function(id, rect) {
              root.companionState = Model.resizeWindow(root.companionState, id, rect)
              root.callService("resize", String(rect.w), String(rect.h))
            }
          }

          InputDeckView {
            anchors.fill: parent
            visible: root.activeTab === "input"
            companionState: root.companionState
            onTypeText: function(text) {
              root.companionState = Model.typeText(root.companionState, text)
              root.callService("key", text)
            }
            onSendKey: function(key, mods) {
              root.companionState = Model.sendKey(root.companionState, key, mods)
              if (root.companionState.menuOpen) root.activeTab = "menu"
              var spec = (mods && mods.super ? "Super+" : "") +
                         (mods && mods.ctrl ? "Ctrl+" : "") +
                         (mods && mods.alt ? "Alt+" : "") +
                         (mods && mods.shift ? "Shift+" : "") + key
              root.callService("key", spec)
              if (key === "w" && mods && mods.super)
                root.callService("closeFocused")
            }
            onMovePointer: function(x, y) {
              root.companionState = Model.movePointer(root.companionState, x, y)
              root.callService("pointer", "move", String(x), String(y))
            }
            onPointer: function(action, x, y) {
              if (action === "click") {
                root.companionState = Model.clickAtPointer(root.companionState)
                root.callService("pointer", "click", "0", "0")
              } else if (action === "scroll") {
                root.companionState = Model.scrollFocused(root.companionState, y)
                root.callService("pointer", "scroll", "0", String(y))
              }
            }
          }

          MenuView {
            anchors.fill: parent
            visible: root.activeTab === "menu"
            companionState: root.companionState
            onRunAction: function(id) { root.handleMenu(id) }
          }

          ControlCentreView {
            anchors.fill: parent
            visible: root.activeTab === "control"
            companionState: root.companionState
            onSetSystem: function(kind, value) {
              if (kind === "volume") root.companionState = Model.setVolume(root.companionState, value)
              else if (kind === "brightness") root.companionState = Model.setBrightness(root.companionState, value)
              else if (kind === "wifi") root.companionState = Model.setWifi(root.companionState, value)
              else if (kind === "bluetooth") root.companionState = Model.setBluetooth(root.companionState, value)
            }
          }
        }

        // Bottom nav
        Rectangle {
          id: nav
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 56
          color: Theme.panel
          Row {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 6
            Repeater {
              model: [
                { id: "pairing", label: "Pair", icon: "▣" },
                { id: "stage", label: "Stage", icon: "▦" },
                { id: "input", label: "Input", icon: "⌨" },
                { id: "menu", label: "Menu", icon: "☰" }
              ]
              delegate: Rectangle {
                width: (nav.width - 30) / 4
                height: 44
                radius: 10
                color: root.activeTab === modelData.id ? "#2a2450" : "transparent"
                border.color: root.activeTab === modelData.id ? Theme.accent : "transparent"
                Column {
                  anchors.centerIn: parent
                  spacing: 2
                  Text {
                    text: modelData.icon
                    color: root.activeTab === modelData.id ? Theme.accent : Theme.muted
                    font.pixelSize: 14
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                  Text {
                    text: modelData.label
                    color: root.activeTab === modelData.id ? Theme.text : Theme.muted
                    font.pixelSize: 11
                    font.bold: root.activeTab === modelData.id
                    anchors.horizontalCenter: parent.horizontalCenter
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.activeTab = modelData.id
                }
              }
            }
          }
        }
      }
    }
  }
}
