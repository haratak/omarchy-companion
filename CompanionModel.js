/**
 * CompanionModel.js — pure JS state + gesture/command mapping for Omarchy Companion.
 * Usable from QML (via .import) and from Node unit tests (CommonJS export).
 */


var APP_PALETTE = {
  Terminal: "#22c55e",
  Browser: "#3b82f6",
  Editor: "#a855f7",
  Files: "#eab308",
  Music: "#ec4899",
  Chat: "#06b6d4",
  Settings: "#94a3b8"
};

var MENU_ITEMS = [
  { id: "terminal", label: "Terminal", icon: "⌘", hint: "New shell", spawn: "kitty" },
  { id: "browser", label: "Browser", icon: "🌐", hint: "New tab", spawn: "chromium" },
  { id: "editor", label: "Editor", icon: "✎", hint: "Open file", spawn: "code" },
  { id: "files", label: "Files", icon: "📁", hint: "File manager", spawn: "nautilus" },
  { id: "workspace-1", label: "Workspace 1", icon: "1", hint: "Switch", workspace: 1 },
  { id: "workspace-2", label: "Workspace 2", icon: "2", hint: "Switch", workspace: 2 },
  { id: "workspace-3", label: "Workspace 3", icon: "3", hint: "Switch", workspace: 3 },
  { id: "workspace-4", label: "Workspace 4", icon: "4", hint: "Switch", workspace: 4 },
  { id: "settings", label: "Settings", icon: "⚙", hint: "System", spawn: "omarchy-menu" },
  { id: "lock", label: "Lock Screen", icon: "🔒", hint: "Lock", action: "lock" },
  { id: "logout", label: "Log Out", icon: "↩", hint: "Session", action: "logout" }
];

var HOLD_MS = 280;
var SWIPE_THRESHOLD = 48;
var HOLD_MOVE_CANCEL = 12;

var _nextId = 10;

function appColor(app) {
  return APP_PALETTE[app] || "#64748b";
}

function createInitialState() {
  return {
    workspaces: [
      { id: 1, name: "1" },
      { id: 2, name: "2" },
      { id: 3, name: "3" },
      { id: 4, name: "4" }
    ],
    activeWorkspaceId: 1,
    windows: [
      {
        id: "w1",
        title: "zsh — ~/projects",
        app: "Terminal",
        className: "kitty",
        color: APP_PALETTE.Terminal,
        workspaceId: 1,
        mode: "tiled",
        floating: false,
        fullscreen: false,
        rect: { x: 0, y: 0, w: 0.5, h: 1 },
        content: "$ omarchy status\n● hyprland running\n● companion mock ready\n",
        scrollY: 0
      },
      {
        id: "w2",
        title: "Omarchy Docs",
        app: "Browser",
        className: "chromium",
        color: APP_PALETTE.Browser,
        workspaceId: 1,
        mode: "tiled",
        floating: false,
        fullscreen: false,
        rect: { x: 0.5, y: 0, w: 0.5, h: 0.55 },
        content: "# Omarchy\nTiling desktop companion demo.\nSwipe · Hold · Drag.",
        scrollY: 0
      },
      {
        id: "w3",
        title: "main.tsx",
        app: "Editor",
        className: "code",
        color: APP_PALETTE.Editor,
        workspaceId: 1,
        mode: "tiled",
        floating: false,
        fullscreen: false,
        rect: { x: 0.5, y: 0.55, w: 0.5, h: 0.45 },
        content: "export function App() {\n  return <Companion />\n}\n",
        scrollY: 0
      },
      {
        id: "w4",
        title: "Downloads",
        app: "Files",
        className: "nautilus",
        color: APP_PALETTE.Files,
        workspaceId: 2,
        mode: "tiled",
        floating: false,
        fullscreen: false,
        rect: { x: 0, y: 0, w: 1, h: 1 },
        content: "📁 photos/\n📁 projects/\n📄 README.md\n",
        scrollY: 0
      },
      {
        id: "w5",
        title: "Now Playing",
        app: "Music",
        className: "spotify",
        color: APP_PALETTE.Music,
        workspaceId: 3,
        mode: "tiled",
        floating: false,
        fullscreen: false,
        rect: { x: 0, y: 0, w: 1, h: 1 },
        content: "♪ Ambient Desk Loop\n━━●──────── 1:24",
        scrollY: 0
      }
    ],
    focusedWindowId: "w1",
    pointer: { x: 0.45, y: 0.4, visible: true },
    system: {
      volume: 62,
      brightness: 78,
      wifi: true,
      bluetooth: false
    },
    menuOpen: false,
    lastAction: "Mock host ready",
    mockMode: true,
    panelOpen: false,
    activeTab: "pairing"
  };
}

function cloneState(state) {
  return JSON.parse(JSON.stringify(state));
}

function windowsOnWorkspace(state, workspaceId) {
  var out = [];
  for (var i = 0; i < state.windows.length; i++) {
    if (state.windows[i].workspaceId === workspaceId) out.push(state.windows[i]);
  }
  return out;
}

function retileWorkspace(windows, workspaceId) {
  var tiled = [];
  for (var i = 0; i < windows.length; i++) {
    var w = windows[i];
    if (w.workspaceId === workspaceId && w.mode === "tiled") tiled.push(w);
  }
  if (tiled.length === 0) return windows;

  var n = tiled.length;
  var layout = [];
  if (n === 1) {
    layout.push({ x: 0, y: 0, w: 1, h: 1 });
  } else if (n === 2) {
    layout.push({ x: 0, y: 0, w: 0.5, h: 1 }, { x: 0.5, y: 0, w: 0.5, h: 1 });
  } else if (n === 3) {
    layout.push(
      { x: 0, y: 0, w: 0.5, h: 1 },
      { x: 0.5, y: 0, w: 0.5, h: 0.5 },
      { x: 0.5, y: 0.5, w: 0.5, h: 0.5 }
    );
  } else {
    var cols = Math.ceil(Math.sqrt(n));
    var rows = Math.ceil(n / cols);
    var cw = 1 / cols;
    var rh = 1 / rows;
    for (var i = 0; i < n; i++) {
      var c = i % cols;
      var r = Math.floor(i / cols);
      layout.push({ x: c * cw, y: r * rh, w: cw, h: rh });
    }
  }

  var byId = {};
  for (var i = 0; i < tiled.length; i++) byId[tiled[i].id] = layout[i];

  return windows.map(function (w) {
    var rect = byId[w.id];
    return rect ? Object.assign({}, w, { rect: rect }) : w;
  });
}

/** Map raw pointer gesture to a named action (pure). */
function classifyGesture(dx, dy, dt, held, alreadyFired, opts) {
  opts = opts || {};
  var threshold = opts.swipeThreshold != null ? opts.swipeThreshold : SWIPE_THRESHOLD;
  var holdMoveCancel = opts.holdMoveCancel != null ? opts.holdMoveCancel : HOLD_MOVE_CANCEL;

  if (alreadyFired) return { type: "none" };

  if (held) {
    if (Math.abs(dx) > threshold || Math.abs(dy) > threshold) {
      if (Math.abs(dx) > Math.abs(dy)) {
        if (dx > 0) return { type: "holdSlideRight" };
        return { type: "holdSlideLeft" };
      }
      if (dy < 0) return { type: "holdSlideUp" };
      return { type: "holdSlideDown" };
    }
    return { type: "none" };
  }

  if (dt < 500) {
    if (Math.abs(dx) > threshold || Math.abs(dy) > threshold) {
      if (Math.abs(dx) > Math.abs(dy)) {
        return dx < 0 ? { type: "swipeLeft" } : { type: "swipeRight" };
      }
      return dy < 0 ? { type: "swipeUp" } : { type: "swipeDown" };
    }
    return { type: "tap" };
  }
  return { type: "none" };
}

/** Whether movement should cancel pending hold timer. */
function shouldCancelHold(dx, dy, opts) {
  opts = opts || {};
  var holdMoveCancel = opts.holdMoveCancel != null ? opts.holdMoveCancel : HOLD_MOVE_CANCEL;
  return Math.hypot(dx, dy) > holdMoveCancel;
}

function nextWorkspaceId(state, dir) {
  var ids = state.workspaces.map(function (w) { return w.id; });
  var idx = ids.indexOf(state.activeWorkspaceId);
  if (idx < 0) return state.activeWorkspaceId;
  return ids[(idx + dir + ids.length) % ids.length];
}

function setActiveWorkspace(state, id) {
  var next = cloneState(state);
  next.activeWorkspaceId = id;
  next.menuOpen = false;
  next.lastAction = "Workspace → " + id;
  return next;
}

function focusWindow(state, id) {
  var next = cloneState(state);
  next.focusedWindowId = id;
  next.lastAction = "Focus " + id;
  return next;
}

function spawnWindow(state, app, fromWindowId) {
  var next = cloneState(state);
  var src = null;
  if (fromWindowId) {
    for (var i = 0; i < next.windows.length; i++) {
      if (next.windows[i].id === fromWindowId) {
        src = next.windows[i];
        break;
      }
    }
  }
  var ws = src ? src.workspaceId : next.activeWorkspaceId;
  var id = "w" + (_nextId++);
  var win = {
    id: id,
    title: app + " — new",
    app: app,
    className: (app || "").toLowerCase(),
    color: appColor(app),
    workspaceId: ws,
    mode: "tiled",
    floating: false,
    fullscreen: false,
    rect: { x: 0, y: 0, w: 1, h: 1 },
    content: app + " window opened from companion.\n",
    scrollY: 0
  };
  next.windows.push(win);
  next.windows = retileWorkspace(next.windows, ws);
  next.focusedWindowId = id;
  next.lastAction = "Spawn " + app;
  return next;
}

function closeFocused(state) {
  var next = cloneState(state);
  if (!next.focusedWindowId) return next;
  var closing = null;
  for (var i = 0; i < next.windows.length; i++) {
    if (next.windows[i].id === next.focusedWindowId) {
      closing = next.windows[i];
      break;
    }
  }
  next.windows = next.windows.filter(function (w) {
    return w.id !== next.focusedWindowId;
  });
  if (closing) next.windows = retileWorkspace(next.windows, closing.workspaceId);
  var remaining = windowsOnWorkspace(next, next.activeWorkspaceId);
  next.focusedWindowId = remaining.length ? remaining[0].id : null;
  next.lastAction = "Close focused";
  return next;
}

function resizeWindow(state, id, rect) {
  var next = cloneState(state);
  var target = null;
  for (var i = 0; i < next.windows.length; i++) {
    if (next.windows[i].id === id) {
      target = next.windows[i];
      break;
    }
  }
  if (!target) return next;

  if (target.mode !== "tiled") {
    next.windows = next.windows.map(function (w) {
      return w.id === id ? Object.assign({}, w, { rect: rect }) : w;
    });
    next.lastAction = "Resize " + id;
    return next;
  }

  var others = next.windows.filter(function (w) {
    return w.id !== id && w.workspaceId === target.workspaceId && w.mode === "tiled";
  });

  var dx = rect.w - target.rect.w;
  var dy = rect.h - target.rect.h;
  next.windows = next.windows.map(function (w) {
    return w.id === id ? Object.assign({}, w, { rect: rect }) : w;
  });

  if (Math.abs(dx) >= Math.abs(dy) && others.length) {
    var rightEdge = target.rect.x + target.rect.w;
    var neighbor = null;
    for (var j = 0; j < others.length; j++) {
      if (Math.abs(others[j].rect.x - rightEdge) < 0.05) {
        neighbor = others[j];
        break;
      }
    }
    if (neighbor) {
      var newX = rect.x + rect.w;
      var newW = Math.max(0.15, neighbor.rect.w - dx);
      next.windows = next.windows.map(function (w) {
        return w.id === neighbor.id
          ? Object.assign({}, w, { rect: Object.assign({}, w.rect, { x: newX, w: newW }) })
          : w;
      });
    }
  } else if (others.length) {
    var bottomEdge = target.rect.y + target.rect.h;
    var neighbor2 = null;
    for (var k = 0; k < others.length; k++) {
      if (Math.abs(others[k].rect.y - bottomEdge) < 0.05) {
        neighbor2 = others[k];
        break;
      }
    }
    if (neighbor2) {
      var newY = rect.y + rect.h;
      var newH = Math.max(0.15, neighbor2.rect.h - dy);
      next.windows = next.windows.map(function (w) {
        return w.id === neighbor2.id
          ? Object.assign({}, w, { rect: Object.assign({}, w.rect, { y: newY, h: newH }) })
          : w;
      });
    }
  }

  next.lastAction = "Resize " + id;
  return next;
}

function setWindowMode(state, id, mode) {
  var next = cloneState(state);
  var win = null;
  next.windows = next.windows.map(function (w) {
    if (w.id !== id) return w;
    win = w;
    if (mode === "floating") {
      return Object.assign({}, w, {
        mode: mode,
        floating: true,
        fullscreen: false,
        rect: { x: 0.15, y: 0.15, w: 0.7, h: 0.7 }
      });
    }
    if (mode === "fullscreen") {
      return Object.assign({}, w, {
        mode: mode,
        floating: false,
        fullscreen: true,
        rect: { x: 0, y: 0, w: 1, h: 1 }
      });
    }
    return Object.assign({}, w, {
      mode: "tiled",
      floating: false,
      fullscreen: false
    });
  });
  if (win) next.windows = retileWorkspace(next.windows, win.workspaceId);
  next.focusedWindowId = id;
  next.lastAction = mode + " " + id;
  return next;
}

function movePointer(state, x, y) {
  var next = cloneState(state);
  next.pointer = {
    x: Math.min(1, Math.max(0, x)),
    y: Math.min(1, Math.max(0, y)),
    visible: true
  };
  return next;
}

function clickAtPointer(state) {
  var next = cloneState(state);
  var x = next.pointer.x;
  var y = next.pointer.y;
  var hit = null;
  for (var i = 0; i < next.windows.length; i++) {
    var w = next.windows[i];
    if (w.workspaceId !== next.activeWorkspaceId) continue;
    if (
      x >= w.rect.x &&
      x <= w.rect.x + w.rect.w &&
      y >= w.rect.y &&
      y <= w.rect.y + w.rect.h
    ) {
      hit = w;
      break;
    }
  }
  if (hit) next.focusedWindowId = hit.id;
  next.lastAction = "Click";
  return next;
}

function scrollFocused(state, dy) {
  var next = cloneState(state);
  if (!next.focusedWindowId) return next;
  next.windows = next.windows.map(function (w) {
    return w.id === next.focusedWindowId
      ? Object.assign({}, w, { scrollY: Math.max(0, w.scrollY + dy) })
      : w;
  });
  return next;
}

function typeText(state, text) {
  var next = cloneState(state);
  if (!next.focusedWindowId) return next;
  next.windows = next.windows.map(function (w) {
    return w.id === next.focusedWindowId
      ? Object.assign({}, w, { content: w.content + text })
      : w;
  });
  next.lastAction = 'Type "' + text + '"';
  return next;
}

function sendKey(state, key, mods) {
  mods = mods || {};
  var next = cloneState(state);
  next.lastAction =
    "Key " + (mods.super ? "Super+" : "") + key;

  if (mods.super && (key === " " || key === "Space")) {
    next.menuOpen = true;
    next.activeTab = "menu";
    return next;
  }
  if (mods.super && (key === "w" || key === "W")) {
    return closeFocused(next);
  }
  if (key === "Backspace" && next.focusedWindowId) {
    next.windows = next.windows.map(function (w) {
      return w.id === next.focusedWindowId
        ? Object.assign({}, w, { content: w.content.slice(0, -1) })
        : w;
    });
    return next;
  }
  if (key === "Enter" && next.focusedWindowId) {
    return typeText(next, "\n");
  }
  if (key === "Tab" && next.focusedWindowId) {
    return typeText(next, "\t");
  }
  if (key === "Escape") {
    next.menuOpen = false;
    return next;
  }
  return next;
}

function setVolume(state, v) {
  var next = cloneState(state);
  next.system.volume = Math.min(100, Math.max(0, v));
  next.lastAction = "Volume " + Math.round(next.system.volume) + "%";
  return next;
}

function setBrightness(state, v) {
  var next = cloneState(state);
  next.system.brightness = Math.min(100, Math.max(0, v));
  next.lastAction = "Brightness " + Math.round(next.system.brightness) + "%";
  return next;
}

function setWifi(state, on) {
  var next = cloneState(state);
  next.system.wifi = !!on;
  next.lastAction = "Wi-Fi " + (on ? "on" : "off");
  return next;
}

function setBluetooth(state, on) {
  var next = cloneState(state);
  next.system.bluetooth = !!on;
  next.lastAction = "Bluetooth " + (on ? "on" : "off");
  return next;
}

function runMenuAction(state, id) {
  var next = cloneState(state);
  next.lastAction = "Menu: " + id;

  if (id === "terminal" || id === "browser" || id === "editor" || id === "files") {
    var appMap = { terminal: "Terminal", browser: "Browser", editor: "Editor", files: "Files" };
    next = spawnWindow(next, appMap[id]);
    next.menuOpen = false;
    next.activeTab = "stage";
    return next;
  }

  if (id.indexOf("workspace-") === 0) {
    var ws = Number(id.split("-")[1]);
    next.activeWorkspaceId = ws;
    next.menuOpen = false;
    next.activeTab = "stage";
    return next;
  }

  next.menuOpen = false;
  return next;
}

/**
 * Apply a Stage gesture against a window or empty stage.
 * Returns { state, commands } where commands are Hyprland/service intents.
 */
function applyStageGesture(state, gestureType, windowId) {
  var commands = [];
  var next = cloneState(state);

  if (gestureType === "swipeLeft") {
    var nid = nextWorkspaceId(next, 1);
    next = setActiveWorkspace(next, nid);
    commands.push({ op: "focusWorkspace", id: nid });
    return { state: next, commands: commands };
  }
  if (gestureType === "swipeRight") {
    var pid = nextWorkspaceId(next, -1);
    next = setActiveWorkspace(next, pid);
    commands.push({ op: "focusWorkspace", id: pid });
    return { state: next, commands: commands };
  }
  if (gestureType === "tap" && windowId) {
    next = focusWindow(next, windowId);
    commands.push({ op: "focusWindow", id: windowId });
    return { state: next, commands: commands };
  }
  if (gestureType === "holdSlideRight" && windowId) {
    var win = null;
    for (var i = 0; i < next.windows.length; i++) {
      if (next.windows[i].id === windowId) {
        win = next.windows[i];
        break;
      }
    }
    var app = win ? win.app : "Terminal";
    next = spawnWindow(next, app, windowId);
    commands.push({ op: "spawn", app: app, relatedTo: windowId });
    return { state: next, commands: commands };
  }
  if (gestureType === "holdSlideUp" && windowId) {
    next = setWindowMode(next, windowId, "floating");
    commands.push({ op: "toggleFloat", id: windowId });
    return { state: next, commands: commands };
  }
  if (gestureType === "holdSlideDown" && windowId) {
    next = setWindowMode(next, windowId, "fullscreen");
    commands.push({ op: "toggleFullscreen", id: windowId });
    return { state: next, commands: commands };
  }
  return { state: next, commands: commands };
}

/** Build JSON-serializable snapshot for IPC status(). */
function toSnapshot(state) {
  return {
    mockMode: !!state.mockMode,
    panelOpen: !!state.panelOpen,
    activeTab: state.activeTab || "stage",
    activeWorkspaceId: state.activeWorkspaceId,
    focusedWindowId: state.focusedWindowId,
    workspaces: state.workspaces,
    windows: state.windows.map(function (w) {
      return {
        id: w.id,
        title: w.title,
        class: w.className || w.app,
        app: w.app,
        workspace: w.workspaceId,
        floating: !!w.floating || w.mode === "floating",
        fullscreen: !!w.fullscreen || w.mode === "fullscreen",
        mode: w.mode,
        rect: w.rect
      };
    }),
    pointer: state.pointer,
    system: state.system,
    menuOpen: !!state.menuOpen,
    lastAction: state.lastAction || ""
  };
}

/**
 * Merge Hyprland live data into state. If empty, keep/enable mock.
 * hypr: { workspaces: [{id,name}], toplevels: [{id,title,class,workspace,floating,fullscreen}], focusedId }
 */
function mergeHyprland(state, hypr) {
  var next = cloneState(state);
  var empty =
    !hypr ||
    ((!hypr.workspaces || hypr.workspaces.length === 0) &&
      (!hypr.toplevels || hypr.toplevels.length === 0));

  if (empty) {
    if (!next.windows || next.windows.length === 0) {
      next = createInitialState();
    }
    next.mockMode = true;
    return next;
  }

  next.mockMode = false;
  if (hypr.workspaces && hypr.workspaces.length) {
    next.workspaces = hypr.workspaces.map(function (w) {
      return { id: w.id, name: String(w.name != null ? w.name : w.id) };
    });
  }
  if (hypr.toplevels) {
    next.windows = hypr.toplevels.map(function (t, idx) {
      var mode = t.fullscreen ? "fullscreen" : t.floating ? "floating" : "tiled";
      return {
        id: String(t.id),
        title: t.title || "",
        app: t.class || t.app || "App",
        className: t.class || "",
        color: appColor(t.class || t.app || "App"),
        workspaceId: t.workspace != null ? t.workspace : 1,
        mode: mode,
        floating: !!t.floating,
        fullscreen: !!t.fullscreen,
        rect: t.rect || { x: 0, y: 0, w: 1, h: 1 },
        content: "",
        scrollY: 0
      };
    });
    // Simple retile for missing rects
    var wsIds = {};
    for (var i = 0; i < next.windows.length; i++) wsIds[next.windows[i].workspaceId] = true;
    Object.keys(wsIds).forEach(function (ws) {
      next.windows = retileWorkspace(next.windows, Number(ws));
    });
  }
  if (hypr.focusedId != null) next.focusedWindowId = String(hypr.focusedId);
  if (hypr.activeWorkspaceId != null) next.activeWorkspaceId = hypr.activeWorkspaceId;
  return next;
}

/** Lua-style Omarchy 4 / Hyprland 0.55+ dispatcher strings. */
function hyprDispatchFocusWorkspace(id) {
  return 'hl.dsp.focus({ workspace = "' + id + '" })';
}

function hyprDispatchClose() {
  return "killactive";
}

function hyprDispatchToggleFloat() {
  return "togglefloating";
}

function hyprDispatchToggleFullscreen() {
  return "fullscreen";
}

function hyprDispatchResize(dx, dy) {
  return "resizeactive " + Math.round(dx) + " " + Math.round(dy);
}

function menuItems() {
  return MENU_ITEMS.slice();
}


// --- Phone pairing / keycombo helpers (v0.2) ---

var DEFAULT_VOICEBOX_COMBO = "SUPER+SHIFT+V";
var DEFAULT_BRIDGE_PORT = 17832;

var SHORTCUT_IDS = {
  "workspace:next": { kind: "workspace", dir: 1 },
  "workspace:prev": { kind: "workspace", dir: -1 },
  "window:next": { kind: "window", dir: 1 },
  "window:prev": { kind: "window", dir: -1 },
  "menu": { kind: "menu" },
  "launcher": { kind: "menu" }
};

/** Parse "SUPER+SHIFT+V" or "Super+Shift+v" into canonical key list. */
function parseKeycombo(spec) {
  if (Array.isArray(spec)) {
    return normalizeKeyList(spec);
  }
  var s = String(spec || "").trim();
  if (!s) return [];
  var parts = s.split(/[+\-]/);
  return normalizeKeyList(parts);
}

function normalizeKeyList(parts) {
  var mods = [];
  var key = null;
  var seen = { SUPER: false, ALT: false, CTRL: false, SHIFT: false };
  for (var i = 0; i < parts.length; i++) {
    var p = String(parts[i] || "").trim();
    if (!p) continue;
    var up = p.toUpperCase();
    if (up === "SUPER" || up === "META" || up === "MOD" || up === "LOGO" || up === "WIN" || up === "CMD") {
      if (!seen.SUPER) { mods.push("SUPER"); seen.SUPER = true; }
    } else if (up === "ALT" || up === "OPTION") {
      if (!seen.ALT) { mods.push("ALT"); seen.ALT = true; }
    } else if (up === "CTRL" || up === "CONTROL" || up === "CTL") {
      if (!seen.CTRL) { mods.push("CTRL"); seen.CTRL = true; }
    } else if (up === "SHIFT") {
      if (!seen.SHIFT) { mods.push("SHIFT"); seen.SHIFT = true; }
    } else {
      key = p.length === 1 ? p : p;
    }
  }
  if (key != null) mods.push(key);
  return mods;
}

/** Format key list back to SUPER+SHIFT+v style string. */
function formatKeycombo(keys) {
  var list = parseKeycombo(keys);
  return list.join("+");
}

/** Parse shortcut id like workspace:2, window:next, menu. */
function parseShortcutId(id) {
  var s = String(id || "").trim();
  if (!s) return { ok: false, error: "empty" };
  if (SHORTCUT_IDS[s]) {
    return Object.assign({ ok: true, id: s }, SHORTCUT_IDS[s]);
  }
  if (s.indexOf("workspace:") === 0) {
    var rest = s.slice("workspace:".length);
    if (/^\d+$/.test(rest)) {
      return { ok: true, id: s, kind: "workspace", workspaceId: Number(rest) };
    }
    if (rest === "next" || rest === "prev") {
      return { ok: true, id: s, kind: "workspace", dir: rest === "next" ? 1 : -1 };
    }
  }
  if (s.indexOf("window:") === 0) {
    var w = s.slice("window:".length);
    if (w === "next" || w === "prev") {
      return { ok: true, id: s, kind: "window", dir: w === "next" ? 1 : -1 };
    }
  }
  return { ok: false, error: "unknown shortcut", id: s };
}

/** Map shortcut id to hyprctl dispatch string (best-effort). */
function shortcutToHyprDispatch(id) {
  var p = parseShortcutId(id);
  if (!p.ok) return null;
  if (p.kind === "workspace" && p.workspaceId != null) return "workspace " + p.workspaceId;
  if (p.kind === "workspace" && p.dir === 1) return "workspace +1";
  if (p.kind === "workspace" && p.dir === -1) return "workspace -1";
  if (p.kind === "window" && p.dir === 1) return "cyclenext";
  if (p.kind === "window" && p.dir === -1) return "cycleprev";
  if (p.kind === "menu") return "exec omarchy-menu";
  return null;
}

/** Build wtype argv for a keycombo list (without binary name). */
function keycomboToWtypeArgs(keys) {
  var list = parseKeycombo(keys);
  var modMap = { SUPER: "logo", ALT: "alt", CTRL: "ctrl", SHIFT: "shift" };
  var args = [];
  var mods = [];
  var key = null;
  for (var i = 0; i < list.length; i++) {
    var k = list[i];
    var up = String(k).toUpperCase();
    if (modMap[up]) {
      mods.push(up);
      args.push("-M", modMap[up]);
    } else {
      key = k;
    }
  }
  if (key != null) {
    if (String(key).length === 1) args.push(String(key));
    else args.push("-k", String(key).toLowerCase());
  }
  for (var j = mods.length - 1; j >= 0; j--) {
    args.push("-m", modMap[mods[j]]);
  }
  return args;
}

/** Generate a URL-safe pair token (Node/QML-friendly). */
function generatePairToken(byteLength) {
  var n = byteLength != null ? byteLength : 16;
  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  var out = "";
  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    var buf = new Uint8Array(n);
    crypto.getRandomValues(buf);
    for (var i = 0; i < n; i++) out += alphabet[buf[i] % alphabet.length];
    return out;
  }
  // Fallback: Math.random (QML / older engines)
  for (var j = 0; j < n; j++) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return out;
}

/** Build pair URL from host IP, port, token. */
function buildPairUrl(hostIp, port, token) {
  var h = String(hostIp || "127.0.0.1");
  var p = port != null ? Number(port) : DEFAULT_BRIDGE_PORT;
  var t = encodeURIComponent(String(token || ""));
  return "http://" + h + ":" + p + "/?token=" + t;
}

function defaultCombos() {
  return [
    { id: "voicebox", label: "VoiceBox", keys: parseKeycombo(DEFAULT_VOICEBOX_COMBO), note: "Change to your VoiceBox bind" },
    { id: "terminal", label: "Terminal", keys: ["SUPER", "Return"] },
    { id: "close", label: "Close Win", keys: ["SUPER", "w"] },
    { id: "menu", label: "Menu", keys: ["SUPER", " "] }
  ];
}


// Node / CommonJS export for unit tests (ignored by QML .pragma library loaders that don't define module)
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    APP_PALETTE: APP_PALETTE,
    MENU_ITEMS: MENU_ITEMS,
    HOLD_MS: HOLD_MS,
    SWIPE_THRESHOLD: SWIPE_THRESHOLD,
    appColor: appColor,
    createInitialState: createInitialState,
    cloneState: cloneState,
    windowsOnWorkspace: windowsOnWorkspace,
    retileWorkspace: retileWorkspace,
    classifyGesture: classifyGesture,
    shouldCancelHold: shouldCancelHold,
    nextWorkspaceId: nextWorkspaceId,
    setActiveWorkspace: setActiveWorkspace,
    focusWindow: focusWindow,
    spawnWindow: spawnWindow,
    closeFocused: closeFocused,
    resizeWindow: resizeWindow,
    setWindowMode: setWindowMode,
    movePointer: movePointer,
    clickAtPointer: clickAtPointer,
    scrollFocused: scrollFocused,
    typeText: typeText,
    sendKey: sendKey,
    setVolume: setVolume,
    setBrightness: setBrightness,
    setWifi: setWifi,
    setBluetooth: setBluetooth,
    runMenuAction: runMenuAction,
    applyStageGesture: applyStageGesture,
    toSnapshot: toSnapshot,
    mergeHyprland: mergeHyprland,
    hyprDispatchFocusWorkspace: hyprDispatchFocusWorkspace,
    hyprDispatchClose: hyprDispatchClose,
    hyprDispatchToggleFloat: hyprDispatchToggleFloat,
    hyprDispatchToggleFullscreen: hyprDispatchToggleFullscreen,
    hyprDispatchResize: hyprDispatchResize,
    menuItems: menuItems,
    DEFAULT_VOICEBOX_COMBO: DEFAULT_VOICEBOX_COMBO,
    DEFAULT_BRIDGE_PORT: DEFAULT_BRIDGE_PORT,
    SHORTCUT_IDS: SHORTCUT_IDS,
    parseKeycombo: parseKeycombo,
    normalizeKeyList: normalizeKeyList,
    formatKeycombo: formatKeycombo,
    parseShortcutId: parseShortcutId,
    shortcutToHyprDispatch: shortcutToHyprDispatch,
    keycomboToWtypeArgs: keycomboToWtypeArgs,
    generatePairToken: generatePairToken,
    buildPairUrl: buildPairUrl,
    defaultCombos: defaultCombos
  };
}
