#!/usr/bin/env node
/**
 * Node-runnable unit tests for CompanionModel.js (no Qt required).
 * Run: node test/model-test.js
 */
"use strict";

const path = require("path");
const assert = require("assert");
const Model = require(path.join(__dirname, "..", "CompanionModel.js"));

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log("  ✓", name);
  } catch (err) {
    console.error("  ✗", name);
    console.error("   ", err.message);
    process.exitCode = 1;
  }
}

console.log("CompanionModel tests\n");

test("createInitialState has workspaces and windows", () => {
  const s = Model.createInitialState();
  assert.strictEqual(s.workspaces.length, 4);
  assert.ok(s.windows.length >= 3);
  assert.strictEqual(s.mockMode, true);
  assert.strictEqual(s.activeWorkspaceId, 1);
});

test("toSnapshot is JSON-serializable", () => {
  const snap = Model.toSnapshot(Model.createInitialState());
  const again = JSON.parse(JSON.stringify(snap));
  assert.strictEqual(again.windows[0].workspace, 1);
  assert.ok(Array.isArray(again.workspaces));
});

test("classifyGesture tap", () => {
  const g = Model.classifyGesture(2, 3, 100, false, false);
  assert.strictEqual(g.type, "tap");
});

test("classifyGesture swipe left/right", () => {
  assert.strictEqual(Model.classifyGesture(-60, 5, 120, false, false).type, "swipeLeft");
  assert.strictEqual(Model.classifyGesture(60, 5, 120, false, false).type, "swipeRight");
});

test("classifyGesture hold slides", () => {
  assert.strictEqual(Model.classifyGesture(70, 5, 400, true, false).type, "holdSlideRight");
  assert.strictEqual(Model.classifyGesture(5, -70, 400, true, false).type, "holdSlideUp");
  assert.strictEqual(Model.classifyGesture(5, 70, 400, true, false).type, "holdSlideDown");
});

test("shouldCancelHold", () => {
  assert.strictEqual(Model.shouldCancelHold(20, 0), true);
  assert.strictEqual(Model.shouldCancelHold(2, 2), false);
});

test("workspace swipe via applyStageGesture", () => {
  let s = Model.createInitialState();
  const r = Model.applyStageGesture(s, "swipeLeft", null);
  assert.strictEqual(r.state.activeWorkspaceId, 2);
  assert.strictEqual(r.commands[0].op, "focusWorkspace");
  assert.strictEqual(r.commands[0].id, 2);
});

test("holdSlideRight spawns related app", () => {
  let s = Model.createInitialState();
  const r = Model.applyStageGesture(s, "holdSlideRight", "w1");
  assert.ok(r.state.windows.length > s.windows.length);
  assert.strictEqual(r.commands[0].op, "spawn");
  assert.strictEqual(r.commands[0].app, "Terminal");
});

test("holdSlideUp / holdSlideDown set modes", () => {
  let s = Model.createInitialState();
  let r = Model.applyStageGesture(s, "holdSlideUp", "w1");
  assert.strictEqual(r.state.windows.find((w) => w.id === "w1").mode, "floating");
  r = Model.applyStageGesture(s, "holdSlideDown", "w1");
  assert.strictEqual(r.state.windows.find((w) => w.id === "w1").mode, "fullscreen");
});

test("closeFocused retires and retile", () => {
  let s = Model.createInitialState();
  const before = Model.windowsOnWorkspace(s, 1).length;
  s = Model.closeFocused(s);
  assert.strictEqual(Model.windowsOnWorkspace(s, 1).length, before - 1);
});

test("Super+Space opens menu; Super+W closes", () => {
  let s = Model.createInitialState();
  s = Model.sendKey(s, " ", { super: true });
  assert.strictEqual(s.menuOpen, true);
  assert.strictEqual(s.activeTab, "menu");
  s = Model.createInitialState();
  const n = s.windows.length;
  s = Model.sendKey(s, "w", { super: true });
  assert.strictEqual(s.windows.length, n - 1);
});

test("menuItems and runMenuAction", () => {
  assert.ok(Model.menuItems().length >= 8);
  let s = Model.createInitialState();
  s = Model.runMenuAction(s, "browser");
  assert.ok(s.windows.some((w) => w.app === "Browser" && w.title.indexOf("new") >= 0));
  s = Model.runMenuAction(s, "workspace-3");
  assert.strictEqual(s.activeWorkspaceId, 3);
});

test("system controls", () => {
  let s = Model.createInitialState();
  s = Model.setVolume(s, 40);
  s = Model.setBrightness(s, 90);
  s = Model.setWifi(s, false);
  s = Model.setBluetooth(s, true);
  assert.strictEqual(s.system.volume, 40);
  assert.strictEqual(s.system.brightness, 90);
  assert.strictEqual(s.system.wifi, false);
  assert.strictEqual(s.system.bluetooth, true);
});

test("mergeHyprland empty keeps mock", () => {
  const s = Model.mergeHyprland(Model.createInitialState(), { workspaces: [], toplevels: [] });
  assert.strictEqual(s.mockMode, true);
});

test("mergeHyprland live disables mock", () => {
  const s = Model.mergeHyprland(Model.createInitialState(), {
    workspaces: [{ id: 1, name: "1" }, { id: 2, name: "2" }],
    toplevels: [
      { id: "0x1", title: "vim", class: "kitty", workspace: 1, floating: false, fullscreen: false }
    ],
    focusedId: "0x1",
    activeWorkspaceId: 1
  });
  assert.strictEqual(s.mockMode, false);
  assert.strictEqual(s.windows[0].title, "vim");
  assert.strictEqual(s.focusedWindowId, "0x1");
});

test("hypr dispatch helpers", () => {
  assert.ok(Model.hyprDispatchFocusWorkspace(2).indexOf("workspace") >= 0);
  assert.strictEqual(Model.hyprDispatchClose(), "killactive");
  assert.strictEqual(Model.hyprDispatchToggleFloat(), "togglefloating");
});

test("pointer + click hit test", () => {
  let s = Model.createInitialState();
  s = Model.movePointer(s, 0.75, 0.2);
  s = Model.clickAtPointer(s);
  assert.strictEqual(s.focusedWindowId, "w2");
});

test("resizeWindow adjusts neighbor", () => {
  let s = Model.createInitialState();
  const w1 = s.windows.find((w) => w.id === "w1");
  s = Model.resizeWindow(s, "w1", { x: 0, y: 0, w: 0.6, h: 1 });
  const after = s.windows.find((w) => w.id === "w1");
  assert.ok(Math.abs(after.rect.w - 0.6) < 0.001);
  assert.notStrictEqual(w1.rect.w, after.rect.w);
});


test("parseKeycombo SUPER+SHIFT+V", () => {
  const keys = Model.parseKeycombo("SUPER+SHIFT+V");
  assert.deepStrictEqual(keys.slice(0, 2), ["SUPER", "SHIFT"]);
  assert.strictEqual(keys[2].toLowerCase(), "v");
  assert.strictEqual(Model.formatKeycombo(keys).indexOf("SUPER") >= 0, true);
});

test("parseKeycombo array + normalize", () => {
  const keys = Model.parseKeycombo(["meta", "shift", "v"]);
  assert.ok(keys.includes("SUPER"));
  assert.ok(keys.includes("SHIFT"));
});

test("parseShortcutId workspace and window", () => {
  assert.strictEqual(Model.parseShortcutId("workspace:3").workspaceId, 3);
  assert.strictEqual(Model.parseShortcutId("workspace:next").dir, 1);
  assert.strictEqual(Model.parseShortcutId("window:prev").dir, -1);
  assert.strictEqual(Model.parseShortcutId("menu").kind, "menu");
  assert.strictEqual(Model.parseShortcutId("nope").ok, false);
});

test("shortcutToHyprDispatch", () => {
  assert.strictEqual(Model.shortcutToHyprDispatch("workspace:2"), "workspace 2");
  assert.strictEqual(Model.shortcutToHyprDispatch("workspace:next"), "workspace +1");
  assert.strictEqual(Model.shortcutToHyprDispatch("window:next"), "cyclenext");
  assert.ok(Model.shortcutToHyprDispatch("menu").indexOf("omarchy-menu") >= 0);
});

test("keycomboToWtypeArgs VoiceBox default", () => {
  const args = Model.keycomboToWtypeArgs(Model.DEFAULT_VOICEBOX_COMBO);
  assert.ok(args.indexOf("logo") >= 0);
  assert.ok(args.indexOf("shift") >= 0);
  assert.ok(args.includes("v") || args.includes("V"));
});

test("generatePairToken and buildPairUrl", () => {
  const t = Model.generatePairToken(12);
  assert.strictEqual(t.length, 12);
  const url = Model.buildPairUrl("192.168.1.5", 17832, t);
  assert.ok(url.indexOf("http://192.168.1.5:17832/?token=") === 0);
  assert.ok(url.indexOf(encodeURIComponent(t)) >= 0 || url.indexOf(t) >= 0);
});

test("defaultCombos includes VoiceBox", () => {
  const combos = Model.defaultCombos();
  assert.ok(combos.some((c) => c.id === "voicebox"));
  assert.strictEqual(Model.DEFAULT_VOICEBOX_COMBO, "SUPER+SHIFT+V");
});

test("initial activeTab is pairing", () => {
  assert.strictEqual(Model.createInitialState().activeTab, "pairing");
});

if (process.exitCode) {
  console.error("\nSome tests failed.");
} else {
  console.log("\nAll", passed, "tests passed.");
}
