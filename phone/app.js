/**
 * Omarchy Companion phone client — Pad / Switch / Keys / Type
 * No build step. WebSocket JSON protocol against bridge/server.py
 */
(function () {
  "use strict";

  var STORAGE_KEY = "omarchy.companion.pair.v1";
  var COMBOS_KEY = "omarchy.companion.combos.v1";
  var DEFAULT_COMBOS = [
    { id: "voicebox", label: "VoiceBox", keys: ["SUPER", "SHIFT", "v"], note: "Set to your VoiceBox bind" },
    { id: "terminal", label: "Terminal", keys: ["SUPER", "Return"], action: "terminal" },
    { id: "close", label: "Close Win", keys: ["SUPER", "w"] },
    { id: "menu", label: "Menu", keys: ["SUPER", "SPACE"] }
  ];

  /** Stable app root. Tailscale Serve mounts us at /companion on :443 (no port). */
  function appBase() {
    var origin = location.origin;
    var path = location.pathname || "/";
    if (path === "/companion" || path.indexOf("/companion/") === 0) {
      return origin + "/companion";
    }
    // Direct bridge / legacy :port installs
    return origin;
  }

  var state = {
    host: "",
    token: "",
    ws: null,
    connected: false,
    reconnectAttempt: 0,
    reconnectTimer: null,
    ignoreClose: false,
    wsGen: 0,
    authFail: 0,
    hardFail: false,
    lastPongAt: 0,
    keepaliveTimer: null,
    watchdogTimer: null,
    suppressPadAction: false,
    workspaces: [],
    windows: [],
    focused: null,
    activeWorkspace: null,
    combos: loadCombos(),
    liveMode: false,
    sheetMode: "add" // add | settings
  };

  // --- storage ---
  function loadPair() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
    } catch (e) {
      return null;
    }
  }
  function savePair(host, token) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ host: host, token: token }));
  }
  function clearPair() {
    localStorage.removeItem(STORAGE_KEY);
  }
  function loadCombos() {
    try {
      var raw = JSON.parse(localStorage.getItem(COMBOS_KEY) || "null");
      if (Array.isArray(raw) && raw.length) return raw;
    } catch (e) {}
    return DEFAULT_COMBOS.map(function (c) { return Object.assign({}, c, { keys: c.keys.slice() }); });
  }
  function saveCombos() {
    localStorage.setItem(COMBOS_KEY, JSON.stringify(state.combos));
  }

  // --- URL bootstrap ---
  function parseBootstrap() {
    var u = new URL(location.href);
    var token = u.searchParams.get("token") || "";
    var host = appBase();
    // Always prefer live URL credentials over stale localStorage
    if (token) {
      state.host = host;
      state.token = token;
      savePair(host, token);
      return true;
    }
    var saved = loadPair();
    if (saved && saved.token) {
      // PWA / reopen without ?token= — reuse saved pairing on stable /companion URL
      if (location.protocol.indexOf("http") === 0) {
        state.host = host;
      } else {
        state.host = saved.host || host;
      }
      // Migrate old :17833 / raw 100.x hosts to current stable base
      if (state.host && state.host.indexOf(":17833") >= 0) {
        state.host = host;
      }
      if (state.host && /https?:\/\/100\.\d+\.\d+\.\d+/.test(state.host)) {
        state.host = host;
      }
      state.token = saved.token;
      savePair(state.host, state.token);
      return true;
    }
    return false;
  }

  // --- DOM ---
  var $ = function (id) { return document.getElementById(id); };
  var pairScreen = $("pair-screen");
  var mainScreen = $("main-screen");
  var connPill = $("conn-pill");
  var trackpad = $("trackpad");
  var comboGrid = $("combo-grid");
  var wsGrid = $("ws-grid");
  var winList = $("win-list");
  var sheet = $("sheet");

  function showPair() {
    pairScreen.classList.remove("hidden");
    mainScreen.classList.add("hidden");
  }
  function showMain() {
    pairScreen.classList.add("hidden");
    mainScreen.classList.remove("hidden");
  }
  function setConn(status, detail) {
    connPill.className = "pill " + status;
    connPill.textContent =
      status === "online" ? "Online" :
      status === "connecting" ? "Connecting" :
      status === "error" ? "Error" : "Offline";
    var wsInd = document.getElementById("ws-indicator");
    if (wsInd) {
      wsInd.textContent =
        status === "online" ? "WS OK" :
        status === "connecting" ? "WS..." :
        status === "error" ? "WS ERR" : "WS -";
    }
    var d = document.getElementById("conn-detail");
    if (d) {
      if (detail) d.textContent = detail;
      else if (status === "online") d.textContent = "Linked to PC";
      else if (status === "connecting") d.textContent = "Linking to PC...";
      else d.textContent = "Not linked to PC yet - check Tailscale / rescan QR";
    }
    var banner = document.getElementById("conn-banner");
    if (banner) {
      if (status === "error" && detail) {
        banner.classList.remove("hidden");
        banner.innerHTML = "";
        var span = document.createElement("div");
        span.textContent = detail;
        banner.appendChild(span);
        var btn = document.createElement("button");
        btn.type = "button";
        btn.textContent = "再接続";
        btn.addEventListener("click", function () {
          state.hardFail = false;
          state.authFail = 0;
          state.reconnectAttempt = 0;
          connect();
        });
        banner.appendChild(btn);
      } else if (status === "online" || status === "connecting") {
        banner.classList.add("hidden");
        banner.textContent = "";
      } else if (detail && status === "offline") {
        banner.classList.remove("hidden");
        banner.textContent = detail;
      }
    }
  }

  function clearKeepalive() {
    if (state.keepaliveTimer) {
      clearInterval(state.keepaliveTimer);
      state.keepaliveTimer = null;
    }
    if (state.watchdogTimer) {
      clearInterval(state.watchdogTimer);
      state.watchdogTimer = null;
    }
  }

  function armKeepalive(gen) {
    clearKeepalive();
    state.lastPongAt = Date.now();
    state.keepaliveTimer = setInterval(function () {
      if (gen !== state.wsGen) return;
      if (!state.ws || state.ws.readyState !== 1) return;
      try {
        state.ws.send(JSON.stringify({ type: "ping", t: Date.now() }));
      } catch (e) {
        failLink("送信失敗 — 接続を切断しました", gen);
      }
    }, 10000);
    state.watchdogTimer = setInterval(function () {
      if (gen !== state.wsGen) return;
      if (!state.connected) return;
      if (Date.now() - state.lastPongAt > 25000) {
        failLink("Keep-alive 切れ — PC応答なし（Tailscale / ブリッジを確認）", gen);
      }
    }, 4000);
  }

  function failLink(msg, gen) {
    if (gen != null && gen !== state.wsGen) return;
    state.hardFail = true;
    state.connected = false;
    clearKeepalive();
    if (state.reconnectTimer) {
      clearTimeout(state.reconnectTimer);
      state.reconnectTimer = null;
    }
    if (state.ws) {
      state.ignoreClose = true;
      try { state.ws.close(); } catch (e) {}
      state.ws = null;
      state.ignoreClose = false;
    }
    setConn("error", msg);
  }

  // --- WebSocket ---
  function wsUrl() {
    var base = state.host.replace(/^http/, "ws");
    return base.replace(/\/$/, "") + "/ws?token=" + encodeURIComponent(state.token);
  }

  function connect() {
    if (!state.host || !state.token) return;
    if (state.hardFail) return;
    // Single-flight: avoid connect storms / Online↔Offline flap
    if (state.ws && (state.ws.readyState === 0 || state.ws.readyState === 1)) {
      return;
    }
    if (state.reconnectTimer) {
      clearTimeout(state.reconnectTimer);
      state.reconnectTimer = null;
    }
    setConn("connecting");
    try {
      if (state.ws) {
        state.ignoreClose = true;
        try { state.ws.close(); } catch (e) {}
        state.ws = null;
        state.ignoreClose = false;
      }
      clearKeepalive();
      var ws = new WebSocket(wsUrl());
      state.ws = ws;
      var gen = ++state.wsGen;
      var opened = false;
      ws.onopen = function () {
        if (gen !== state.wsGen) return;
        opened = true;
        state.connected = true;
        state.reconnectAttempt = 0;
        state.authFail = 0;
        state.hardFail = false;
        setConn("online");
        armKeepalive(gen);
        send({ type: "state" });
        send({ type: "ping", t: Date.now() });
      };
      ws.onclose = function (ev) {
        if (gen !== state.wsGen) return;
        if (state.ignoreClose) return;
        state.connected = false;
        clearKeepalive();
        if (state.hardFail) return;
        if (state.authFail >= 3) {
          failLink("トークン無効 — PCのQRを再スキャン", gen);
          return;
        }
        if (!opened) {
          scheduleReconnect("接続失敗 — 再試行中…");
          return;
        }
        scheduleReconnect("切断されました — 再接続中…");
      };
      ws.onerror = function () {
        if (gen !== state.wsGen) return;
        if (!opened) {
          setConn("connecting", "接続できません…");
        }
      };
      ws.onmessage = function (ev) {
        if (gen !== state.wsGen) return;
        try {
          var msg = JSON.parse(ev.data);
          onMessage(msg);
        } catch (e) {}
      };
    } catch (e) {
      scheduleReconnect("接続エラー");
    }
  }

  function scheduleReconnect(detail) {
    if (state.hardFail) return;
    if (state.authFail >= 5) {
      failLink("認証失敗が続きました — QRを再スキャン");
      return;
    }
    if (state.reconnectAttempt >= 4) {
      failLink("PCに届きません — Tailscale がオンか、PCのブリッジを確認");
      return;
    }
    if (state.reconnectTimer) clearTimeout(state.reconnectTimer);
    var attempt = state.reconnectAttempt++;
    var ms = Math.min(12000, 800 * Math.pow(1.6, attempt));
    setConn("offline", detail || ("再接続待ち… (" + (attempt + 1) + "/4)"));
    state.reconnectTimer = setTimeout(function () {
      state.reconnectTimer = null;
      connect();
    }, ms);
  }

  function send(obj) {
    if (!state.ws || state.ws.readyState !== 1) {
      if (!state.hardFail) {
        setConn("offline", "未接続 — Online になるまで操作できません");
      }
      return false;
    }
    state.ws.send(JSON.stringify(obj));
    return true;
  }

  function onMessage(msg) {
    if (!msg || !msg.type) return;
    if (msg.type === "pong" || (msg.type === "ack" && msg.pong)) {
      state.lastPongAt = Date.now();
      return;
    }
    if (msg.type === "error" && String(msg.error || "").indexOf("unauthorized") >= 0) {
      state.authFail = 99;
      clearPair();
      failLink("トークン不一致 — 新しいQRを開いてください");
      showPair();
      return;
    }
    if (msg.type === "hello") {
      state.authFail = 0;
      state.lastPongAt = Date.now();
      setConn("online");
    }
    if (msg.type === "state") {
      state.lastPongAt = Date.now();
      state.workspaces = msg.workspaces || [];
      state.windows = msg.windows || [];
      state.focused = msg.focused || null;
      state.activeWorkspace = msg.activeWorkspace != null ? msg.activeWorkspace : state.activeWorkspace;
      renderSwitch();
    }
    if (msg.type === "error") {
      console.warn("bridge error", msg);
      if (String(msg.error || "").indexOf("unauthorized") >= 0) {
        failLink("トークン不一致 — PCのQRを再スキャン");
      }
    }
  }

  // --- Tabs ---
  function setTab(id) {
    // Single-screen: tabs removed. "type"/"keys" open the keyboard drawer.
    if (id === "type" || id === "keys") openKeyboard();
    if (id === "switch") send({ type: "state" });
  }


  // --- Trackpad ---
  // tap = left · double-tap = right · double-tap-hold = scroll while finger down
  (function setupPad() {
    var pointers = new Map();
    var moved = false;
    var SENS = 1.35;
    var SCROLL_SENS = 0.55;
    var TAP_MS = 260;
    var DOUBLE_MS = 340;
    var HOLD_MS = 400;
    var phase = "idle"; // idle | wait2 | second
    var lastTapUp = 0;
    var leftTimer = null;
    var holdTimer = null;
    var scrollMode = false;
    var badge = document.getElementById("scroll-badge");

    function clearLeft() {
      if (leftTimer) { clearTimeout(leftTimer); leftTimer = null; }
    }
    function clearHold() {
      if (holdTimer) { clearTimeout(holdTimer); holdTimer = null; }
    }
    function setScrollMode(on) {
      scrollMode = !!on;
      if (badge) badge.classList.toggle("hidden", !scrollMode);
      trackpad.classList.toggle("scroll-mode", scrollMode);
    }

    trackpad.addEventListener("pointerdown", function (e) {
      trackpad.setPointerCapture(e.pointerId);
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      moved = false;
      clearHold();
      var now = Date.now();
      if (phase === "wait2" && (now - lastTapUp) <= DOUBLE_MS) {
        // second tap of a double-tap
        clearLeft();
        phase = "second";
        holdTimer = setTimeout(function () {
          if (pointers.has(e.pointerId) && !moved) {
            setScrollMode(true);
          }
        }, HOLD_MS);
      }
      e.preventDefault();
    });

    trackpad.addEventListener("pointermove", function (e) {
      if (!pointers.has(e.pointerId)) return;
      var prev = pointers.get(e.pointerId);
      var dx = e.clientX - prev.x;
      var dy = e.clientY - prev.y;
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (Math.abs(dx) + Math.abs(dy) > 2) {
        moved = true;
        clearHold();
      }
      if (scrollMode) {
        var sdx = Math.round(dx * SCROLL_SENS);
        var sdy = Math.round(dy * SCROLL_SENS);
        if (sdx || sdy) send({ type: "scroll", dx: sdx, dy: sdy });
        e.preventDefault();
        return;
      }
      // dragging during second-tap cancels right-click / scroll-hold → just move cursor
      if (phase === "second" && moved) {
        phase = "idle";
      }
      var rdx = Math.round(dx * SENS);
      var rdy = Math.round(dy * SENS);
      if (rdx || rdy) send({ type: "pointer", dx: rdx, dy: rdy });
      e.preventDefault();
    });

    function endPointer(e) {
      if (!pointers.has(e.pointerId)) return;
      pointers.delete(e.pointerId);
      clearHold();
      var now = Date.now();
      if (scrollMode) {
        setScrollMode(false);
        phase = "idle";
        return;
      }
      if (pointers.size > 0) return;
      if (state.suppressPadAction) {
        state.suppressPadAction = false;
        phase = "idle";
        clearLeft();
        return;
      }
      if (moved) {
        phase = "idle";
        clearLeft();
        return;
      }
      if (phase === "second") {
        // quick second tap → right click
        phase = "idle";
        send({ type: "click", button: "right" });
        return;
      }
      // first tap → wait for possible second
      phase = "wait2";
      lastTapUp = now;
      clearLeft();
      leftTimer = setTimeout(function () {
        leftTimer = null;
        if (phase === "wait2") {
          phase = "idle";
          send({ type: "click", button: "left" });
        }
      }, TAP_MS);
    }
    trackpad.addEventListener("pointerup", endPointer);
    trackpad.addEventListener("pointercancel", endPointer);

    var backBtn = document.getElementById("nav-back");
    var fwdBtn = document.getElementById("nav-forward");
    if (backBtn) backBtn.addEventListener("click", function () {
      send({ type: "click", button: "back" });
    });
    if (fwdBtn) fwdBtn.addEventListener("click", function () {
      send({ type: "click", button: "forward" });
    });
  })();


  // --- Edge swipe (workspace) + keyboard drawer ---
  (function setupSurfaceGestures() {
    var EDGE = 28; // px from left/right
    var SWIPE = 56;
    var stage = document.getElementById("pad-stage");
    var toast = document.getElementById("gesture-toast");
    var toastTimer = null;
    var edge = null; // left | right | null
    var startX = 0, startY = 0, armed = false;

    function flash(side) {
      if (!stage) return;
      stage.classList.remove("edge-flash-left", "edge-flash-right");
      stage.classList.add(side === "left" ? "edge-flash-left" : "edge-flash-right");
      setTimeout(function () {
        stage.classList.remove("edge-flash-left", "edge-flash-right");
      }, 280);
    }
    function showToast(text) {
      if (!toast) return;
      toast.textContent = text;
      toast.classList.remove("hidden");
      if (toastTimer) clearTimeout(toastTimer);
      toastTimer = setTimeout(function () { toast.classList.add("hidden"); }, 700);
    }

    trackpad.addEventListener("pointerdown", function (e) {
      var rect = trackpad.getBoundingClientRect();
      var x = e.clientX - rect.left;
      edge = null;
      armed = false;
      if (x <= EDGE) { edge = "left"; armed = true; }
      else if (x >= rect.width - EDGE) { edge = "right"; armed = true; }
      startX = e.clientX;
      startY = e.clientY;
    }, true);

    trackpad.addEventListener("pointerup", function (e) {
      if (!armed || !edge) return;
      var dx = e.clientX - startX;
      var dy = e.clientY - startY;
      armed = false;
      if (Math.abs(dy) > Math.abs(dx) * 0.85) return; // mostly vertical → ignore
      if (edge === "left" && dx >= SWIPE) {
        state.suppressPadAction = true;
        flash("left");
        showToast("Workspace ◀");
        send({ type: "shortcut", id: "workspace:prev" });
      } else if (edge === "right" && dx <= -SWIPE) {
        state.suppressPadAction = true;
        flash("right");
        showToast("Workspace ▶");
        send({ type: "shortcut", id: "workspace:next" });
      }
      edge = null;
    }, true);
    trackpad.addEventListener("pointercancel", function () { armed = false; edge = null; }, true);
  })();

  function openKeyboard() {
    var d = $("kb-drawer");
    if (!d) return;
    d.classList.remove("hidden");
    d.setAttribute("aria-hidden", "false");
    send({ type: "state" });
    setTimeout(function () {
      var ta = $("type-input");
      if (ta) ta.focus();
    }, 50);
  }
  function closeKeyboard() {
    var d = $("kb-drawer");
    if (!d) return;
    d.classList.add("hidden");
    d.setAttribute("aria-hidden", "true");
    var ta = $("type-input");
    if (ta) ta.blur();
  }
  var kbToggle = $("kb-toggle");
  if (kbToggle) kbToggle.addEventListener("click", function () {
    var d = $("kb-drawer");
    if (d && d.classList.contains("hidden")) openKeyboard();
    else closeKeyboard();
  });
  var kbClose = $("kb-close");
  if (kbClose) kbClose.addEventListener("click", closeKeyboard);

  // Long-press bottom of trackpad opens keyboard
  (function setupPadLongKb() {
    var t = null;
    trackpad.addEventListener("pointerdown", function (e) {
      var rect = trackpad.getBoundingClientRect();
      var y = e.clientY - rect.top;
      if (y < rect.height * 0.82) return;
      // avoid conflicting with edge swipe
      var x = e.clientX - rect.left;
      if (x <= 28 || x >= rect.width - 28) return;
      clearTimeout(t);
      t = setTimeout(function () { openKeyboard(); }, 520);
    });
    function clear() { if (t) { clearTimeout(t); t = null; } }
    trackpad.addEventListener("pointerup", clear);
    trackpad.addEventListener("pointercancel", clear);
    var sx = 0, sy = 0;
    trackpad.addEventListener("pointerdown", function (e) {
      sx = e.clientX; sy = e.clientY;
    });
    trackpad.addEventListener("pointermove", function (e) {
      if (!t) return;
      if (Math.abs(e.clientX - sx) + Math.abs(e.clientY - sy) > 12) clear();
    });
  })();


  // --- Switch ---
  function renderSwitch() {
    var ind = $("ws-indicator");
    if (ind) {
      var aw = state.activeWorkspace != null ? state.activeWorkspace : "—";
      ind.textContent = "WS " + aw;
    }
    var wss = state.workspaces.length
      ? state.workspaces
      : [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(function (i) { return { id: i, name: String(i) }; });
    if (!wsGrid) return;
    wsGrid.innerHTML = "";
    wss.slice(0, 10).forEach(function (ws) {
      var b = document.createElement("button");
      b.className = "ws-btn" + (state.activeWorkspace === ws.id ? " active" : "");
      b.textContent = ws.name || ws.id;
      b.addEventListener("click", function () {
        send({ type: "shortcut", id: "workspace:" + ws.id });
        state.activeWorkspace = ws.id;
        renderSwitch();
      });
      wsGrid.appendChild(b);
    });
    // fill up to 10 if fewer from host
    if (wss.length < 10 && state.workspaces.length) {
      for (var i = wss.length + 1; i <= 10; i++) {
        (function (n) {
          var b = document.createElement("button");
          b.className = "ws-btn";
          b.textContent = String(n);
          b.addEventListener("click", function () {
            send({ type: "shortcut", id: "workspace:" + n });
          });
          wsGrid.appendChild(b);
        })(i);
      }
    }

    if (!winList) return;
    winList.innerHTML = "";
    (state.windows || []).forEach(function (w) {
      var li = document.createElement("li");
      if (w.id === state.focused) li.className = "focused";
      li.innerHTML = '<div class="title"></div><div class="meta"></div>';
      li.querySelector(".title").textContent = w.title || w.class || w.id;
      li.querySelector(".meta").textContent = (w.class || "") + " · ws " + (w.workspace != null ? w.workspace : "?");
      li.addEventListener("click", function () {
        // focus via hyprctl address if possible — send as keycombo fallback not available;
        // request state refresh; best-effort: shortcut not defined for focus by id in v1
        send({ type: "shortcut", id: "workspace:" + (w.workspace || 1) });
      });
      winList.appendChild(li);
    });
    if (!state.windows || !state.windows.length) {
      winList.innerHTML = '<li><div class="title">No window list</div><div class="meta">Host will fill this when hyprctl is available</div></li>';
    }
  }

  $("ws-prev").addEventListener("click", function () { send({ type: "shortcut", id: "workspace:prev" }); });
  $("ws-next").addEventListener("click", function () { send({ type: "shortcut", id: "workspace:next" }); });
  $("win-prev").addEventListener("click", function () { send({ type: "shortcut", id: "window:prev" }); });
  $("win-next").addEventListener("click", function () { send({ type: "shortcut", id: "window:next" }); });
  $("menu-btn").addEventListener("click", function () { send({ type: "shortcut", id: "menu" }); });

  // --- Keys ---
  function renderCombos() {
    if (!comboGrid) return;
    comboGrid.innerHTML = "";
    state.combos.forEach(function (c, idx) {
      var b = document.createElement("button");
      b.className = "combo-btn";
      b.innerHTML = "<span></span><small></small>";
      b.querySelector("span").textContent = c.label;
      b.querySelector("small").textContent = (c.keys || []).join("+");
      b.addEventListener("click", function () {
        // Always send key events — shortcuts stay generic
        send({ type: "keycombo", keys: c.keys });
      });
      b.addEventListener("contextmenu", function (e) {
        e.preventDefault();
        openSheetEdit(idx);
      });
      comboGrid.appendChild(b);
    });
  }

  function openSheetAdd() {
    state.sheetMode = "add";
    $("sheet-title").textContent = "Add combo";
    $("sheet-label").value = "";
    $("sheet-key").value = "";
    sheet.querySelectorAll("[data-mod]").forEach(function (el) { el.checked = false; });
    $("sheet-forget").classList.add("hidden");
    sheet.classList.remove("hidden");
  }
  function openSheetEdit(idx) {
    state.sheetMode = "edit:" + idx;
    var c = state.combos[idx];
    $("sheet-title").textContent = "Edit combo";
    $("sheet-label").value = c.label || "";
    var mods = { SUPER: false, SHIFT: false, CTRL: false, ALT: false };
    var key = "";
    (c.keys || []).forEach(function (k) {
      var u = String(k).toUpperCase();
      if (u in mods) mods[u] = true;
      else key = k;
    });
    sheet.querySelectorAll("[data-mod]").forEach(function (el) {
      el.checked = !!mods[el.getAttribute("data-mod")];
    });
    $("sheet-key").value = key;
    $("sheet-forget").classList.add("hidden");
    sheet.classList.remove("hidden");
  }
  function openSettings() {
    state.sheetMode = "settings";
    $("sheet-title").textContent = "Settings";
    $("sheet-label").value = "";
    $("sheet-key").value = "";
    sheet.querySelectorAll("[data-mod]").forEach(function (el) { el.checked = false; });
    $("sheet-forget").classList.remove("hidden");
    sheet.classList.remove("hidden");
  }

  $("add-combo").addEventListener("click", openSheetAdd);
  $("edit-combos").addEventListener("click", openSettings);
  $("sheet-cancel").addEventListener("click", function () { sheet.classList.add("hidden"); });
  $("sheet-forget").addEventListener("click", function () {
    clearPair();
    if (state.ws) try { state.ws.close(); } catch (e) {}
    sheet.classList.add("hidden");
    showPair();
  });
  $("sheet-save").addEventListener("click", function () {
    if (state.sheetMode === "settings") {
      sheet.classList.add("hidden");
      return;
    }
    var label = $("sheet-label").value.trim() || "Combo";
    var key = $("sheet-key").value.trim() || "a";
    var keys = [];
    sheet.querySelectorAll("[data-mod]").forEach(function (el) {
      if (el.checked) keys.push(el.getAttribute("data-mod"));
    });
    keys.push(key.length === 1 ? key : key);
    if (String(state.sheetMode).indexOf("edit:") === 0) {
      var idx = Number(String(state.sheetMode).split(":")[1]);
      state.combos[idx] = { id: state.combos[idx].id || "c" + Date.now(), label: label, keys: keys };
    } else {
      state.combos.push({ id: "c" + Date.now(), label: label, keys: keys });
    }
    saveCombos();
    renderCombos();
    sheet.classList.add("hidden");
  });

  // --- Type ---
  var typeInput = $("type-input");
  var liveMode = $("live-mode");
  var lastLive = "";
  var composing = false;
  var capturedSend = null; // text snapped before IME blur steals the first char
  liveMode.addEventListener("change", function () {
    state.liveMode = !!liveMode.checked;
    lastLive = typeInput.value;
  });
  typeInput.addEventListener("compositionstart", function () { composing = true; });
  typeInput.addEventListener("compositionend", function () {
    composing = false;
    lastLive = typeInput.value;
  });
  typeInput.addEventListener("input", function (e) {
    if (!state.liveMode) return;
    // Never stream partial IME composition (Japanese etc.) — drops/garbles glyphs
    if (composing || (e && e.isComposing)) return;
    var v = typeInput.value;
    if (v.length > lastLive.length && v.slice(0, lastLive.length) === lastLive) {
      send({ type: "text", text: v.slice(lastLive.length) });
    } else if (v !== lastLive) {
      send({ type: "text", text: v.slice(-1) });
    }
    lastLive = v;
  });
  function sendTypeText(t) {
    if (!t) return;
    // Drop trailing blank lines from the textarea, keep real content
    t = String(t).replace(/\s+$/g, "");
    if (!t) return;
    send({ type: "text", text: t });
    typeInput.value = "";
    lastLive = "";
    capturedSend = null;
  }
  // Snapshot on press so IME blur cannot empty the field before click
  $("type-send").addEventListener("pointerdown", function () {
    capturedSend = typeInput.value;
  });
  $("type-send").addEventListener("click", function () {
    var now = typeInput.value || "";
    var cap = capturedSend || "";
    var t = cap.length >= now.length ? cap : now;
    sendTypeText(t);
  });
  $("type-enter").addEventListener("click", function () {
    send({ type: "keycombo", keys: ["Return"] });
  });

  // --- Pair form ---
  $("pair-connect").addEventListener("click", function () {
    var url = $("pair-url").value.trim().replace(/\/$/, "");
    var token = $("pair-token").value.trim();
    var err = $("pair-error");
    err.textContent = "";
    if (!url || !token) {
      err.textContent = "URL and token required";
      return;
    }
    try {
      var parsed = new URL(url);
      // Keep /companion path if present (PWA stable URL)
      var path = parsed.pathname || "/";
      if (path === "/companion" || path.indexOf("/companion/") === 0) {
        state.host = parsed.origin + "/companion";
      } else {
        state.host = parsed.origin;
      }
      state.token = token;
      savePair(state.host, state.token);
      showMain();
      renderCombos();
      renderSwitch();
      connect();
    } catch (e) {
      err.textContent = "Invalid URL";
    }
  });

  // --- boot ---
  (function hideBoot() {
    var el = document.getElementById("boot-fallback");
    if (el) el.style.display = "none";
  })();
  if (parseBootstrap()) {
    showMain();
    renderCombos();
    renderSwitch();
    connect();
  } else {
    var saved = loadPair();
    $("pair-url").value = (saved && saved.host) || (location.protocol.indexOf("http") === 0 ? appBase() : "");
    if (saved && saved.token) $("pair-token").value = saved.token;
    showPair();
  }

  // Manual re-pair / forget
  var forgetBtn = $("pair-forget");
  if (forgetBtn) {
    forgetBtn.addEventListener("click", function () {
      clearPair();
      state.host = "";
      state.token = "";
      if (state.ws) try { state.ws.close(); } catch (e) {}
      $("pair-token").value = "";
      showPair();
    });
  }
  var rebtn = $("pair-reconnect");
  if (rebtn) {
    rebtn.addEventListener("click", function () {
      if (parseBootstrap() || (loadPair() && loadPair().token)) {
        var s = loadPair();
        if (s) { state.host = s.host || location.origin; state.token = s.token; }
        showMain();
        connect();
      }
    });
  }


  // --- PWA ---
  var deferredInstall = null;
  var pwaBar = document.getElementById("pwaInstall");
  var pwaBtn = document.getElementById("pwaInstallBtn");
  var pwaDismiss = document.getElementById("pwaDismiss");

  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();
    deferredInstall = e;
    if (pwaBar && !window.matchMedia("(display-mode: standalone)").matches) {
      try {
        if (sessionStorage.getItem("pwaDismiss") === "1") return;
      } catch (err) {}
      pwaBar.hidden = false;
    }
  });
  window.addEventListener("appinstalled", function () {
    deferredInstall = null;
    if (pwaBar) pwaBar.hidden = true;
  });
  if (pwaBtn) {
    pwaBtn.addEventListener("click", function () {
      if (!deferredInstall) return;
      deferredInstall.prompt();
      deferredInstall.userChoice.then(function () {
        deferredInstall = null;
        if (pwaBar) pwaBar.hidden = true;
      });
    });
  }
  if (pwaDismiss) {
    pwaDismiss.addEventListener("click", function () {
      if (pwaBar) pwaBar.hidden = true;
      try { sessionStorage.setItem("pwaDismiss", "1"); } catch (err) {}
    });
  }
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("./sw.js", { scope: "./" }).catch(function (err) {
        console.warn("SW register failed (need HTTPS on Android):", err);
      });
    });
  }

  // Resume pairing when app/PWA comes back to foreground
  function retryLink() {
    if (!state.host || !state.token) return;
    state.hardFail = false;
    state.authFail = 0;
    state.reconnectAttempt = 0;
    connect();
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "visible" && state.host && state.token && !state.connected) {
      retryLink();
    }
  });
  window.addEventListener("pageshow", function () {
    if (state.host && state.token && !state.connected) {
      retryLink();
    }
  });
  window.addEventListener("online", function () {
    if (state.host && state.token && !state.connected) {
      retryLink();
    }
  });
  // Tap pill to retry after hard error
  if (connPill) {
    connPill.style.cursor = "pointer";
    connPill.title = "タップで再接続";
    connPill.addEventListener("click", function () {
      if (!state.connected) retryLink();
    });
  }
})();
