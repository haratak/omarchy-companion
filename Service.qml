import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "CompanionModel.js" as Model

/**
 * Headless companion service.
 * Host injects: omarchyPath, shell, manifest, pluginRegistry / barWidgetRegistry.
 */
Item {
    id: root

    property var omarchyPath
    property var shell
    property var manifest
    property var pluginRegistry
    property var barWidgetRegistry

    property bool mockMode: true
    property bool panelOpen: false
    property var state: Model.createInitialState()
    property string lastWarning: ""

    // --- Phone bridge (v0.2) ---
    // pluginDir: directory containing this Service.qml / bridge/server.py.
    // Defaults via Qt.resolvedUrl("."); override for install
    // (~/.config/omarchy/plugins/harataku.companion) or dev
    // (/workspace/omarchy-companion-plugin).
    property string pluginDir: ""
    property alias pluginRoot: root.pluginDir
    property int bridgePort: 17832
    property string bridgeToken: ""
    property string bridgeUrl: ""
    property int bridgeClients: 0
    property string pluginVersion: "0.4.9"
    property bool bridgeRunning: false
    property string advertiseIp: ""
    property bool pendingBridgeStart: false
    property alias bridgeHostIp: root.advertiseIp
    property string statusFile: "/tmp/omarchy-companion-bridge.json"
    property string pairStateFile: ""
    property alias bridgeStatusFile: root.statusFile
    property string lastBridgeError: ""

    property bool _hyprReady: false

    Timer {
        id: refreshTimer
        interval: 800
        running: true
        repeat: true
        onTriggered: root.refreshFromHyprland()
    }

    Component.onCompleted: {
        root.resolvePluginDir()
        root.pairStateFile = root.pluginDir + "/state/pair.json"
        root.loadPairState()
        root.refreshFromHyprland()
        root.detectLanIp()
        // Resume existing bridge (same token) if status file is live — phone can reconnect
        Qt.callLater(root.tryResumeBridge)
        console.log("[harataku.companion] service loaded; pluginDir=", root.pluginDir)
    }

    function loadPairState() {
        try {
            pairLoadProcess.command = ["sh", "-c",
                "test -f '" + root.pairStateFile + "' && cat '" + root.pairStateFile + "' || echo '{}'"]
            pairLoadProcess.running = true
        } catch (e) {
            console.warn("[harataku.companion] loadPairState", e)
        }
    }

    function savePairState() {
        if (!root.bridgeToken || root.bridgeToken.length < 8) return
        var payload = JSON.stringify({
            token: root.bridgeToken,
            port: root.bridgePort,
            publicBase: "https://haratarch.tail46c55.ts.net/companion"
        })
        // Avoid shell heredoc quoting issues
        pairSaveProcess.command = [
            "python3", "-c",
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(sys.argv[2]+chr(10))",
            root.pairStateFile,
            payload
        ]
        pairSaveProcess.running = true
    }

    function tryResumeBridge() {
        // If a bridge process we own isn't running but status file has our token, adopt it.
        // If nothing running, auto-start with persisted token so phone pairing resumes.
        root.refreshBridgeStatus()
        resumeBridgeTimer.restart()
    }

    function snapshotJson() {
        var snap = Model.toSnapshot(root.state)
        snap.panelOpen = root.panelOpen
        snap.mockMode = root.mockMode
        snap.lastWarning = root.lastWarning
        snap.bridge = root.pairInfoObj()
        return JSON.stringify(snap)
    }

    function resolvePluginDir() {
        if (root.pluginDir && root.pluginDir.length)
            return root.pluginDir
        var resolved = ""
        try {
            var u = String(Qt.resolvedUrl("."))
            if (u.indexOf("file://") === 0)
                resolved = decodeURIComponent(u.substring(7)).replace(/\/$/, "")
            // file:///path => /path
            if (resolved.length && resolved.charAt(0) !== "/" && resolved.indexOf(":") < 0)
                resolved = "/" + resolved
        } catch (e) {}
        if (!resolved || resolved.indexOf("qrc") === 0) {
            // Dev + install fallbacks (documented)
            resolved = "/workspace/omarchy-companion-plugin"
        }
        root.pluginDir = resolved
        return resolved
    }

    function pairInfoObj() {
        return {
            running: root.bridgeRunning,
            url: root.bridgeUrl,
            token: root.bridgeToken,
            port: root.bridgePort,
            host: root.advertiseIp,
            clients: root.bridgeClients,
            statusFile: root.statusFile,
            pluginDir: root.pluginDir,
            error: root.lastBridgeError,
            version: root.pluginVersion
        }
    }

    function pairInfo() {
        return JSON.stringify(root.pairInfoObj())
    }

    function detectLanIp() {
        // ONLY Tailscale 100.x from QML side. Never fall back to LAN here.
        // Empty result => launch omits --advertise-ip; server.py resolves Tailscale.
        lanIpProcess.command = ["sh", "-c",
            "TS=$(/usr/bin/tailscale ip -4 2>/dev/null | head -1);"
            + " if echo \"$TS\" | grep -q '^100\.'; then echo \"$TS\"; exit 0; fi;"
            + " sleep 0.5;"
            + " TS=$(/usr/bin/tailscale ip -4 2>/dev/null | head -1);"
            + " if echo \"$TS\" | grep -q '^100\.'; then echo \"$TS\"; exit 0; fi;"
            + " echo ''; exit 0"
        ]
        lanIpProcess.running = true
    }

    function startBridge() {
        root.lastBridgeError = ""
        root.resolvePluginDir()
        root.bridgePort = 17832
        // Stop our Process handle; sibling python bridges are stopped inside server.py on spawn
        if (bridgeProcess.running)
            bridgeProcess.running = false
        if (!root.bridgeToken || root.bridgeToken.length < 8)
            root.bridgeToken = Model.generatePairToken(16)
        root.savePairState()
        // Do NOT pre-kill here with pgrep (matches launcher shells). server.py cleans siblings.
        root.advertiseIp = ""
        root.pendingBridgeStart = true
        root.detectLanIp()
        bridgeStartFallback.restart()
        return root.pairInfo()
    }

    function launchBridgeProcess() {
        root.pendingBridgeStart = false
        bridgeStartFallback.stop()
        var dir = root.pluginDir
        var script = dir + "/bridge/server.py"
        var phone = dir + "/phone"
        var ip = root.advertiseIp || ""
        // Only pin advertise-ip when we already have Tailscale 100.x.
        // Otherwise let server.py detect (it prefers /usr/bin/tailscale) so we never force 192.
        var cmd = [
            "python3", script,
            "--http",
            "--port", String(root.bridgePort),
            "--token", root.bridgeToken,
            "--phone-dir", phone,
            "--status-file", root.statusFile,
            "--pair-state", root.pairStateFile
        ]
        if (ip.indexOf("100.") === 0) {
            cmd.push("--advertise-ip")
            cmd.push(ip)
        } else {
            console.warn("[harataku.companion] deferring advertise-ip to server.py (probe was)", ip || "(empty)")
            ip = ""
        }
        bridgeProcess.command = cmd
        bridgeProcess.running = true
        root.bridgeRunning = true
        // Temporary URL; READY / status poll will replace with server-detected host
        root.bridgeUrl = ip ? Model.buildPairUrl(ip, root.bridgePort, root.bridgeToken) : ("(detecting Tailscale… token " + root.bridgeToken + ")")
        statusPoll.running = true
        root.refreshBridgeStatus()
        console.log("[harataku.companion] bridge starting", root.bridgeUrl, "dir=", dir)
    }

    function stopBridge() {
        if (bridgeProcess.running) {
            bridgeProcess.running = false
        }
        // Best-effort kill by status / pkill pattern
        bridgeKillProcess.command = ["sh", "-c", "for p in $(pgrep -f '/usr/bin/python3 .*/harataku.companion/bridge/server.py' || true); do kill -TERM $p 2>/dev/null; done; sleep 0.2; for p in $(pgrep -f '/usr/bin/python3 .*/harataku.companion/bridge/server.py' || true); do kill -KILL $p 2>/dev/null; done; true"]
        bridgeKillProcess.running = true
        root.bridgeRunning = false
        root.bridgeClients = 0
        statusPoll.running = false
        console.log("[harataku.companion] bridge stopped")
        return root.pairInfo()
    }

    function refreshBridgeStatus() {
        statusReadProcess.command = ["sh", "-c", "test -f '" + root.statusFile + "' && cat '" + root.statusFile + "' || echo '{}'"]
        statusReadProcess.running = false
        statusReadProcess.running = true
        return root.pairInfo()
    }

    function applyBridgeStatus(raw) {
        try {
            var info = JSON.parse(String(raw || "{}"))
            if (info.port) root.bridgePort = Number(info.port)
            if (info.token) root.bridgeToken = String(info.token)
            if (info.host) root.advertiseIp = String(info.host)
            if (info.url) root.bridgeUrl = String(info.url)
            if (info.clients != null) root.bridgeClients = Number(info.clients)
            if (info.version) root.pluginVersion = String(info.version)
            if (info.url || info.port || root.bridgeRunning) root.bridgeRunning = true
            root.lastBridgeError = ""
        } catch (e) {}
    }

    function keycombo(spec) {
        var keys = Model.parseKeycombo(spec)
        if (!keys.length) return "empty"
        if (root.mockMode) {
            root.setState(Model.sendKey(root.state, keys[keys.length - 1], {
                super: keys.indexOf("SUPER") >= 0,
                alt: keys.indexOf("ALT") >= 0,
                ctrl: keys.indexOf("CTRL") >= 0,
                shift: keys.indexOf("SHIFT") >= 0
            }))
            return "ok"
        }
        var args = Model.keycomboToWtypeArgs(keys)
        if (toolProbe.wtype) {
            injectProcess.command = ["wtype"].concat(args)
            injectProcess.running = true
            return "ok"
        }
        return root.key(Model.formatKeycombo(keys))
    }

    function text(payload) {
        var t = String(payload || "")
        if (!t) return "empty"
        if (root.mockMode) {
            root.setState(Model.typeText(root.state, t))
            return "ok"
        }
        if (toolProbe.wtype) {
            injectProcess.command = ["wtype", "--", t]
            injectProcess.running = true
            return "ok"
        }
        if (toolProbe.ydotool) {
            injectProcess.command = ["ydotool", "type", "--", t]
            injectProcess.running = true
            return "ok"
        }
        root.lastWarning = "No wtype/ydotool for text inject"
        return "no-injector"
    }

    function shortcut(id) {
        var dispatch = Model.shortcutToHyprDispatch(id)
        if (!dispatch) return "unknown"
        if (root.mockMode) {
            var parsed = Model.parseShortcutId(id)
            if (parsed.kind === "workspace" && parsed.workspaceId != null)
                root.setState(Model.setActiveWorkspace(root.state, parsed.workspaceId))
            else if (parsed.kind === "workspace" && parsed.dir)
                root.setState(Model.setActiveWorkspace(root.state, Model.nextWorkspaceId(root.state, parsed.dir)))
            else if (parsed.kind === "menu")
                root.setState(Object.assign(Model.cloneState(root.state), { menuOpen: true, activeTab: "menu" }))
            return "ok"
        }
        root.dispatchHypr(dispatch)
        return "ok"
    }

    function pointerRelative(dx, dy) {
        var x = Number(dx) || 0
        var y = Number(dy) || 0
        if (root.mockMode) {
            var px = Math.min(1, Math.max(0, (root.state.pointer.x || 0.5) + x / 800))
            var py = Math.min(1, Math.max(0, (root.state.pointer.y || 0.5) + y / 800))
            root.setState(Model.movePointer(root.state, px, py))
            return "ok"
        }
        if (toolProbe.ydotool) {
            injectProcess.command = ["ydotool", "mousemove", "-x", String(Math.round(x)), "-y", String(Math.round(y))]
            injectProcess.running = true
            return "ok"
        }
        root.lastWarning = "No ydotool for relative pointer"
        return "no-injector"
    }

    function setState(next) {
        root.state = next
        root.mockMode = !!next.mockMode
    }

    function refreshFromHyprland() {
        var hypr = { workspaces: [], toplevels: [], focusedId: null, activeWorkspaceId: null }
        try {
            if (typeof Hyprland === "undefined" || !Hyprland) {
                root.applyHypr(hypr)
                return
            }
            var wss = []
            if (Hyprland.workspaces) {
                var n = Hyprland.workspaces.count !== undefined
                    ? Hyprland.workspaces.count
                    : (Hyprland.workspaces.values ? Hyprland.workspaces.values.length : 0)
                if (Hyprland.workspaces.values) {
                    for (var i = 0; i < Hyprland.workspaces.values.length; i++) {
                        var ws = Hyprland.workspaces.values[i]
                        wss.push({ id: ws.id, name: ws.name })
                    }
                } else if (typeof Hyprland.workspaces.count === "number") {
                    for (var j = 0; j < Hyprland.workspaces.count; j++) {
                        var ws2 = Hyprland.workspaces.get ? Hyprland.workspaces.get(j) : null
                        if (ws2) wss.push({ id: ws2.id, name: ws2.name })
                    }
                }
            }
            var tops = []
            if (Hyprland.toplevels) {
                if (Hyprland.toplevels.values) {
                    for (var k = 0; k < Hyprland.toplevels.values.length; k++) {
                        var t = Hyprland.toplevels.values[k]
                        tops.push(root._mapToplevel(t))
                    }
                } else if (typeof Hyprland.toplevels.count === "number") {
                    for (var m = 0; m < Hyprland.toplevels.count; m++) {
                        var t2 = Hyprland.toplevels.get ? Hyprland.toplevels.get(m) : null
                        if (t2) tops.push(root._mapToplevel(t2))
                    }
                }
            }
            hypr.workspaces = wss
            hypr.toplevels = tops
            if (Hyprland.focusedWorkspace)
                hypr.activeWorkspaceId = Hyprland.focusedWorkspace.id
            if (Hyprland.activeToplevel)
                hypr.focusedId = String(Hyprland.activeToplevel.address || Hyprland.activeToplevel.id || "")
            root._hyprReady = wss.length > 0 || tops.length > 0
        } catch (e) {
            root.lastWarning = "Hyprland read failed: " + e
            root._hyprReady = false
        }
        root.applyHypr(hypr)
    }

    function _mapToplevel(t) {
        var wsId = 1
        try {
            if (t.workspace && t.workspace.id != null) wsId = t.workspace.id
            else if (t.workspaceId != null) wsId = t.workspaceId
        } catch (e) {}
        var floating = false
        var fullscreen = false
        try { floating = !!(t.floating || (t.lastIpcObject && t.lastIpcObject.floating)) } catch (e2) {}
        try { fullscreen = !!(t.fullscreen || (t.lastIpcObject && t.lastIpcObject.fullscreen)) } catch (e3) {}
        return {
            id: String(t.address || t.id || ""),
            title: t.title || "",
            class: t.class || t.waylandClass || "",
            workspace: wsId,
            floating: floating,
            fullscreen: fullscreen
        }
    }

    function applyHypr(hypr) {
        // Preserve UI-only fields across Hyprland merges
        var prev = root.state
        var merged = Model.mergeHyprland(prev, hypr)
        merged.panelOpen = root.panelOpen
        merged.activeTab = prev.activeTab || "pairing"
        merged.pointer = prev.pointer
        merged.system = prev.system
        merged.menuOpen = prev.menuOpen
        if (!merged.mockMode) {
            // keep lastAction from prev unless empty
            if (prev.lastAction) merged.lastAction = prev.lastAction
        }
        root.setState(merged)
    }

    function dispatchHypr(request) {
        try {
            if (typeof Hyprland !== "undefined" && Hyprland && Hyprland.dispatch) {
                Hyprland.dispatch(request)
                return true
            }
        } catch (e) {
            root.lastWarning = "dispatch failed: " + e
        }
        // Fallback: hyprctl without login shell
        hyprProcess.command = ["hyprctl", "dispatch"].concat(String(request).split(" "))
        hyprProcess.running = true
        return false
    }

    function focusWorkspace(id) {
        var nid = Number(id)
        if (root.mockMode) {
            root.setState(Model.setActiveWorkspace(root.state, nid))
            return "ok"
        }
        // Prefer Lua-style Omarchy 4 / Hyprland 0.55+
        var luaOk = false
        try {
            if (typeof Hyprland !== "undefined" && Hyprland && Hyprland.usingLua)
                luaOk = true
        } catch (e) {}
        if (luaOk) {
            root.dispatchHypr(Model.hyprDispatchFocusWorkspace(nid))
        } else {
            // Try lua form first, then classic
            try {
                Hyprland.dispatch(Model.hyprDispatchFocusWorkspace(nid))
            } catch (e2) {
                root.dispatchHypr("workspace " + nid)
            }
        }
        root.setState(Model.setActiveWorkspace(root.state, nid))
        return "ok"
    }

    function closeFocused() {
        if (root.mockMode) {
            root.setState(Model.closeFocused(root.state))
            return "ok"
        }
        root.dispatchHypr(Model.hyprDispatchClose())
        root.setState(Model.closeFocused(root.state))
        return "ok"
    }

    function toggleFloat() {
        if (root.mockMode) {
            var id = root.state.focusedWindowId
            if (id) root.setState(Model.setWindowMode(root.state, id, "floating"))
            return "ok"
        }
        root.dispatchHypr(Model.hyprDispatchToggleFloat())
        return "ok"
    }

    function toggleFullscreen() {
        if (root.mockMode) {
            var id = root.state.focusedWindowId
            if (id) root.setState(Model.setWindowMode(root.state, id, "fullscreen"))
            return "ok"
        }
        root.dispatchHypr(Model.hyprDispatchToggleFullscreen())
        return "ok"
    }

    function resize(dx, dy) {
        if (root.mockMode) {
            var id = root.state.focusedWindowId
            if (!id) return "no-focus"
            var win = null
            for (var i = 0; i < root.state.windows.length; i++) {
                if (root.state.windows[i].id === id) win = root.state.windows[i]
            }
            if (!win) return "no-focus"
            var rect = {
                x: win.rect.x,
                y: win.rect.y,
                w: Math.min(1 - win.rect.x, Math.max(0.15, win.rect.w + Number(dx))),
                h: Math.min(1 - win.rect.y, Math.max(0.15, win.rect.h + Number(dy)))
            }
            root.setState(Model.resizeWindow(root.state, id, rect))
            return "ok"
        }
        root.dispatchHypr(Model.hyprDispatchResize(Number(dx) * 40, Number(dy) * 40))
        return "ok"
    }

    function spawn(cmd) {
        var c = String(cmd || "").trim()
        if (!c) return "empty"
        if (root.mockMode) {
            root.setState(Model.spawnWindow(root.state, c))
            return "ok"
        }
        try {
            Hyprland.dispatch("exec " + c)
        } catch (e) {
            spawnProcess.command = ["sh", "-c", c]
            spawnProcess.running = true
        }
        root.setState(Object.assign(Model.cloneState(root.state), { lastAction: "Spawn " + c }))
        return "ok"
    }

    function key(spec) {
        // spec: "Super+w" or plain "a"
        var s = String(spec || "")
        var mods = { super: false, alt: false, ctrl: false, shift: false }
        var parts = s.split("+")
        var keyName = parts[parts.length - 1]
        for (var i = 0; i < parts.length - 1; i++) {
            var p = parts[i].toLowerCase()
            if (p === "super" || p === "meta" || p === "mod") mods.super = true
            if (p === "alt") mods.alt = true
            if (p === "ctrl" || p === "control") mods.ctrl = true
            if (p === "shift") mods.shift = true
        }
        if (root.mockMode) {
            root.setState(Model.sendKey(root.state, keyName, mods))
            return "ok"
        }
        return root.injectKey(keyName, mods)
    }

    function pointer(action, x, y) {
        var a = String(action || "move")
        if (a === "move") {
            root.setState(Model.movePointer(root.state, Number(x), Number(y)))
            if (!root.mockMode) root.injectPointerMove(Number(x), Number(y))
            return "ok"
        }
        if (a === "click") {
            root.setState(Model.clickAtPointer(root.state))
            if (!root.mockMode) root.injectClick()
            return "ok"
        }
        if (a === "scroll") {
            root.setState(Model.scrollFocused(root.state, Number(y) || 0))
            if (!root.mockMode) root.injectScroll(Number(y) || 0)
            return "ok"
        }
        return "unknown"
    }

    function injectKey(keyName, mods) {
        // Prefer wtype, then ydotool, then dotool
        var args = null
        if (toolProbe.wtype) {
            args = ["wtype"]
            if (mods.super) args.push("-M", "logo")
            if (mods.alt) args.push("-M", "alt")
            if (mods.ctrl) args.push("-M", "ctrl")
            if (mods.shift) args.push("-M", "shift")
            if (keyName === " ") args.push(" ")
            else if (keyName.length === 1) args.push(keyName)
            else args.push("-k", keyName.toLowerCase())
            if (mods.shift) args.push("-m", "shift")
            if (mods.ctrl) args.push("-m", "ctrl")
            if (mods.alt) args.push("-m", "alt")
            if (mods.super) args.push("-m", "logo")
        } else if (toolProbe.ydotool) {
            // Best-effort: type or key — limited mapping
            args = ["ydotool", "key", keyName]
        } else if (toolProbe.dotool) {
            args = ["dotool"]
        } else {
            root.lastWarning = "No wtype/ydotool/dotool found; key inject no-op"
            console.warn("[harataku.companion]", root.lastWarning)
            if (root.mockMode === false)
                root.setState(Model.sendKey(root.state, keyName, mods))
            return "no-injector"
        }
        injectProcess.command = args
        injectProcess.running = true
        return "ok"
    }

    function injectPointerMove(nx, ny) {
        // Absolute normalized → best-effort relative via ydotool/dotool; often unavailable
        root.lastWarning = root.lastWarning
        if (toolProbe.ydotool) {
            // ydotool mousemove -- absolute needs display size; skip absolute, log only
            console.log("[harataku.companion] pointer move", nx, ny)
        }
    }

    function injectClick() {
        if (toolProbe.ydotool) {
            injectProcess.command = ["ydotool", "click", "0xC0"]
            injectProcess.running = true
            return
        }
        if (toolProbe.wtype) {
            // wtype cannot click
            root.lastWarning = "wtype cannot inject pointer click"
        }
    }

    function injectScroll(dy) {
        if (toolProbe.ydotool) {
            injectProcess.command = ["ydotool", "mousemove", "-w", "-x", "0", "-y", String(Math.round(dy))]
            injectProcess.running = true
        }
    }

    function openPanel() {
        root.panelOpen = true
        try {
            if (root.shell && typeof root.shell.summon === "function") {
                root.shell.summon("harataku.companion", "{}")
                return "ok"
            }
        } catch (e) {
            root.lastWarning = "summon failed: " + e
        }
        return "no-shell"
    }

    function applyGesture(gestureType, windowId) {
        var result = Model.applyStageGesture(root.state, gestureType, windowId)
        root.setState(result.state)
        for (var i = 0; i < result.commands.length; i++) {
            var c = result.commands[i]
            if (c.op === "focusWorkspace") root.focusWorkspace(c.id)
            else if (c.op === "toggleFloat") { if (!root.mockMode) root.toggleFloat() }
            else if (c.op === "toggleFullscreen") { if (!root.mockMode) root.toggleFullscreen() }
            else if (c.op === "spawn" && !root.mockMode) {
                var spawnMap = {
                    Terminal: "kitty",
                    Browser: "chromium",
                    Editor: "code",
                    Files: "nautilus",
                    Music: "spotify",
                    Chat: "discord",
                    Settings: "omarchy-menu"
                }
                root.spawn(spawnMap[c.app] || c.app.toLowerCase())
            }
        }
        return "ok"
    }

    function setSystem(kind, value) {
        if (kind === "volume") {
            root.setState(Model.setVolume(root.state, Number(value)))
            volumeProcess.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", (Number(value) / 100).toFixed(2)]
            volumeProcess.running = true
        } else if (kind === "brightness") {
            root.setState(Model.setBrightness(root.state, Number(value)))
            brightnessProcess.command = ["brightnessctl", "set", Math.round(Number(value)) + "%"]
            brightnessProcess.running = true
        } else if (kind === "wifi") {
            root.setState(Model.setWifi(root.state, !!value))
        } else if (kind === "bluetooth") {
            root.setState(Model.setBluetooth(root.state, !!value))
        }
        return "ok"
    }

    // --- tool presence probe (best-effort, once) ---
    QtObject {
        id: toolProbe
        property bool wtype: false
        property bool ydotool: false
        property bool dotool: false
    }

    Process {
        id: whichProcess
        command: ["sh", "-c", "command -v wtype; command -v ydotool; command -v dotool"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var t = this.text || ""
                toolProbe.wtype = t.indexOf("wtype") >= 0
                toolProbe.ydotool = t.indexOf("ydotool") >= 0
                toolProbe.dotool = t.indexOf("dotool") >= 0
            }
        }
    }

    Process { id: hyprProcess; running: false }
    Process { id: spawnProcess; running: false }
    Process { id: injectProcess; running: false }
    Process { id: volumeProcess; running: false }
    Process { id: brightnessProcess; running: false }
    Process { id: bridgeKillProcess; running: false }

    Timer {
        id: bridgeStartFallback
        interval: 1600
        repeat: false
        onTriggered: {
            if (root.pendingBridgeStart)
                root.launchBridgeProcess()
        }
    }

    Process {
        id: lanIpProcess
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var ip = String(this.text || "").trim().split(/\s+/)[0]
                if (ip) {
                    root.advertiseIp = ip
                    if (root.bridgeToken)
                        root.bridgeUrl = Model.buildPairUrl(ip, root.bridgePort, root.bridgeToken)
                }
                if (root.pendingBridgeStart)
                    root.launchBridgeProcess()
            }
        }
    }

    Process {
        id: bridgeProcess
        running: false
        stdout: SplitParser {
            onRead: function(line) {
                var s = String(line || "")
                if (s.indexOf("READY ") === 0) {
                    try {
                        var info = JSON.parse(s.slice(6))
                        if (info.port) root.bridgePort = Number(info.port)
                        if (info.token) root.bridgeToken = String(info.token)
                        if (info.url) root.bridgeUrl = String(info.url)
                        root.bridgeRunning = true
                    } catch (e) {}
                } else if (s.indexOf("STATUS ") === 0) {
                    try {
                        root.applyBridgeStatus(s.slice(7))
                    } catch (e2) {}
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (this.text)
                    console.warn("[harataku.companion] bridge stderr", this.text)
            }
        }
    }

    Process {
        id: pairLoadProcess
        running: false
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(exitCode) {
            try {
                var raw = String(stdout.text || "{}")
                var info = JSON.parse(raw)
                if (info.token && String(info.token).length >= 8) {
                    if (!root.bridgeToken)
                        root.bridgeToken = String(info.token)
                }
                if (info.port) root.bridgePort = Number(info.port)
                console.log("[harataku.companion] loaded pair-state token=…" + (root.bridgeToken || "").slice(-4))
                // Token ready — resume bridge so phone can reconnect without rescanning
                resumeBridgeTimer.restart()
            } catch (e) {}
        }
    }

    Process {
        id: pairSaveProcess
        running: false
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
    }

    Timer {
        id: resumeBridgeTimer
        interval: 600
        repeat: false
        onTriggered: {
            // After status read: if bridge not running, start with persisted token
            if (root.bridgeRunning || root.pendingBridgeStart) return
            if (!root.bridgeToken || root.bridgeToken.length < 8) return
            console.log("[harataku.companion] auto-resume bridge with persisted token")
            root.startBridge()
        }
    }

    Process {
        id: statusReadProcess
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.applyBridgeStatus(this.text)
        }
    }

    Timer {
        id: statusPoll
        interval: 1000
        running: false
        repeat: true
        onTriggered: {
            if (root.bridgeRunning) root.refreshBridgeStatus()
            else statusPoll.running = false
        }
    }

    IpcHandler {
        target: "harataku.companion"

        function ping(): string { return "ok" }

        function status(): string { return root.snapshotJson() }

        function openPanel(): string { return root.openPanel() }

        function focusWorkspace(id: string): string { return root.focusWorkspace(id) }

        function closeFocused(): string { return root.closeFocused() }

        function toggleFloat(): string { return root.toggleFloat() }

        function toggleFullscreen(): string { return root.toggleFullscreen() }

        function resize(dx: string, dy: string): string { return root.resize(dx, dy) }

        function spawn(cmd: string): string { return root.spawn(cmd) }

        function key(spec: string): string { return root.key(spec) }

        function pointer(action: string, x: string, y: string): string {
            return root.pointer(action, x, y)
        }

        function startBridge(): string { return root.startBridge() }

        function stopBridge(): string { return root.stopBridge() }

        function pairInfo(): string { return root.pairInfo() }

        function refreshBridgeStatus(): string { return root.refreshBridgeStatus() }

        function keycombo(spec: string): string { return root.keycombo(spec) }

        function text(payload: string): string { return root.text(payload) }

        function shortcut(id: string): string { return root.shortcut(id) }

        function pointerRelative(dx: string, dy: string): string {
            return root.pointerRelative(dx, dy)
        }
    }
}
