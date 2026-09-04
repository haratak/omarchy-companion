#!/usr/bin/env python3
"""Omarchy Companion phone bridge — stdlib HTTP + WebSocket server.

Serves the phone/ UI and accepts JSON control messages over /ws.
Executes host actions via hyprctl / wtype / ydotool / dotool.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import ssl
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

DEFAULT_PORT = 17832
PLUGIN_ROOT = Path(__file__).resolve().parent.parent
PHONE_DIR = PLUGIN_ROOT / "phone"
STATUS_PATH = Path(os.environ.get("OMARCHY_COMPANION_STATUS", "/tmp/omarchy-companion-bridge.json"))

# ---------------------------------------------------------------------------
# Tool detection
# ---------------------------------------------------------------------------

def which(name: str) -> Optional[str]:
    return shutil.which(name)


TOOLS = {
    "hyprctl": which("hyprctl"),
    "wtype": which("wtype"),
    "ydotool": which("ydotool"),
    "dotool": which("dotool"),
    "qrencode": which("qrencode"),
}


def ensure_hyprland_env() -> None:
    """Quickshell/UWSM may start us with HYPRLAND_INSTANCE_SIGNATURE="" — hyprctl then fails.
    Fill from the newest instance under $XDG_RUNTIME_DIR/hypr when missing/empty."""
    sig = (os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or "").strip()
    if sig:
        return
    runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    hypr = Path(runtime) / "hypr"
    if not hypr.is_dir():
        return
    dirs = [p for p in hypr.iterdir() if p.is_dir()]
    if not dirs:
        return
    newest = max(dirs, key=lambda p: p.stat().st_mtime)
    os.environ["HYPRLAND_INSTANCE_SIGNATURE"] = newest.name
    if not os.environ.get("WAYLAND_DISPLAY"):
        os.environ["WAYLAND_DISPLAY"] = "wayland-1"
    print(
        f"[bridge] restored HYPRLAND_INSTANCE_SIGNATURE={newest.name}",
        file=sys.stderr,
    )


def run_cmd(argv: List[str], timeout: float = 3.0) -> Tuple[int, str, str]:
    if argv and Path(argv[0]).name == "hyprctl":
        ensure_hyprland_env()
    try:
        p = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return p.returncode, p.stdout or "", p.stderr or ""
    except FileNotFoundError:
        return 127, "", "not found"
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


# ---------------------------------------------------------------------------
# LAN IP + token helpers
# ---------------------------------------------------------------------------

def detect_tailscale_ip() -> str | None:
    for cmd in (
        ["/usr/bin/tailscale", "ip", "-4"],
        ["tailscale", "ip", "-4"],
    ):
        code, out, _ = run_cmd(cmd)
        if code == 0 and out.strip():
            ip = out.strip().split()[0]
            if ip.startswith("100."):
                return ip
    return None



def detect_tailscale_dns() -> str | None:
    """MagicDNS name e.g. haratarch.tailXXXX.ts.net (trusted HTTPS via Serve)."""
    for cmd in (
        ["/usr/bin/tailscale", "status", "--json"],
        ["tailscale", "status", "--json"],
    ):
        code, out, _ = run_cmd(cmd, timeout=5)
        if code != 0 or not out.strip():
            continue
        try:
            data = json.loads(out)
            name = (data.get("Self") or {}).get("DNSName") or ""
            name = name.rstrip(".")
            if name.endswith(".ts.net"):
                return name
        except Exception:  # noqa: BLE001
            continue
    return None


def detect_lan_ip() -> str:
    # Prefer Tailscale (works across AP client isolation / guest Wi-Fi)
    ts = detect_tailscale_ip()
    if ts:
        return ts
    # Prefer: ip route get 1.1.1.1
    code, out, _ = run_cmd(["ip", "-4", "route", "get", "1.1.1.1"])
    if code == 0 and out:
        parts = out.split()
        if "src" in parts:
            return parts[parts.index("src") + 1]
    code, out, _ = run_cmd(["hostname", "-I"])
    if code == 0 and out.strip():
        return out.strip().split()[0]
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("1.1.1.1", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:  # noqa: BLE001
        return "127.0.0.1"


def resolve_advertise_ip(forced: str | None) -> str:
    """Tailscale 100.x always wins over LAN / loopback advertise hints."""
    ts = detect_tailscale_ip()
    forced = (forced or "").strip()
    if ts:
        if not forced or forced.startswith(("192.168.", "10.", "172.")) or forced in ("127.0.0.1", "0.0.0.0"):
            if forced and forced != ts:
                print(f"[bridge] overriding advertise-ip {forced!r} -> Tailscale {ts}", file=sys.stderr)
            return ts
        if forced.startswith("100."):
            return forced
        return ts
    return forced or detect_lan_ip()



def default_pair_state_path() -> Path:
    return Path(__file__).resolve().parent.parent / "state" / "pair.json"


def load_persisted_token(path: Path | None = None) -> str | None:
    path = path or default_pair_state_path()
    try:
        if not path.is_file():
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        tok = str(data.get("token") or "").strip()
        return tok if len(tok) >= 8 else None
    except Exception:  # noqa: BLE001
        return None


def save_persisted_token(token: str, public_base: str | None = None, port: int | None = None, path: Path | None = None) -> None:
    path = path or default_pair_state_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, Any] = {}
        if path.is_file():
            try:
                data = json.loads(path.read_text(encoding="utf-8")) or {}
            except Exception:  # noqa: BLE001
                data = {}
        data["token"] = token
        if public_base:
            data["publicBase"] = public_base
        if port:
            data["port"] = int(port)
        path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    except Exception as e:  # noqa: BLE001
        print(f"[bridge] pair-state save failed: {e}", file=sys.stderr)


def generate_token(nbytes: int = 16) -> str:
    return secrets.token_urlsafe(nbytes)


# ---------------------------------------------------------------------------
# Host actions
# ---------------------------------------------------------------------------

MOD_MAP_WTYPE = {
    "SUPER": "logo",
    "META": "logo",
    "LOGO": "logo",
    "WIN": "logo",
    "ALT": "alt",
    "CTRL": "ctrl",
    "CONTROL": "ctrl",
    "SHIFT": "shift",
}

# Linux input-event-codes.h — ydotool speaks these (evdev), which Hyprland binds see.
# Prefer this over wtype virtual-keyboard (mods often mis-fire, e.g. Return→Escape).
YDOTOOL_KEYCODES = {
    "ESC": 1,
    "ESCAPE": 1,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
    "MINUS": 12, "-": 12,
    "EQUAL": 13, "=": 13,
    "BACKSPACE": 14, "BS": 14,
    "TAB": 15,
    "Q": 16, "W": 17, "E": 18, "R": 19, "T": 20, "Y": 21, "U": 22, "I": 23, "O": 24, "P": 25,
    "LEFTBRACE": 26, "[": 26,
    "RIGHTBRACE": 27, "]": 27,
    "ENTER": 28, "RETURN": 28, "RET": 28,
    "CTRL": 29, "CONTROL": 29, "LEFTCTRL": 29,
    "A": 30, "S": 31, "D": 32, "F": 33, "G": 34, "H": 35, "J": 36, "K": 37, "L": 38,
    "SEMICOLON": 39, ";": 39,
    "APOSTROPHE": 40, "'": 40,
    "GRAVE": 41, "`": 41,
    "SHIFT": 42, "LEFTSHIFT": 42,
    "BACKSLASH": 43, "\\": 43,
    "Z": 44, "X": 45, "C": 46, "V": 47, "B": 48, "N": 49, "M": 50,
    "COMMA": 51, ",": 51,
    "DOT": 52, ".": 52,
    "SLASH": 53, "/": 53,
    "RIGHTSHIFT": 54,
    "LEFTALT": 56, "ALT": 56,
    "SPACE": 57, " ": 57,
    "CAPSLOCK": 58,
    "F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64,
    "F7": 65, "F8": 66, "F9": 67, "F10": 68, "F11": 87, "F12": 88,
    "RIGHTCTRL": 97,
    "RIGHTALT": 100, "ALTGR": 100,
    "HOME": 102,
    "UP": 103,
    "PAGEUP": 104, "PAGE_UP": 104, "PGUP": 104,
    "LEFT": 105,
    "RIGHT": 106,
    "END": 107,
    "DOWN": 108,
    "PAGEDOWN": 109, "PAGE_DOWN": 109, "PGDN": 109,
    "INSERT": 110,
    "DELETE": 111, "DEL": 111,
    "SUPER": 125, "META": 125, "LOGO": 125, "WIN": 125, "LEFTMETA": 125,
    "RIGHTMETA": 126,
}

# libxkbcommon names for wtype fallback
WTYPE_KEY_NAMES = {
    "return": "Return",
    "enter": "Return",
    "ret": "Return",
    "escape": "Escape",
    "esc": "Escape",
    "tab": "Tab",
    "space": "space",
    "backspace": "BackSpace",
    "bs": "BackSpace",
    "delete": "Delete",
    "del": "Delete",
    "insert": "Insert",
    "home": "Home",
    "end": "End",
    "pageup": "Page_Up",
    "pagedown": "Page_Down",
    "pgup": "Page_Up",
    "pgdn": "Page_Down",
    "up": "Up",
    "down": "Down",
    "left": "Left",
    "right": "Right",
    "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4",
    "f5": "F5", "f6": "F6", "f7": "F7", "f8": "F8",
    "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
}

SHORTCUT_HYPR = {
    "workspace:next": "workspace +1",
    "workspace:prev": "workspace -1",
    "window:next": "cyclenext",
    "window:prev": "cycleprev",
    "menu": "exec omarchy-menu toggle",
    "launcher": "exec omarchy-menu toggle",
}


def normalize_keys(keys: List[str]) -> List[str]:
    out: List[str] = []
    for k in keys:
        if k is None:
            continue
        s = k if isinstance(k, str) else str(k)
        if s == " ":
            out.append("SPACE")
            continue
        s = s.strip()
        if not s:
            continue
        up = s.upper()
        if up in ("SUPER", "META", "LOGO", "WIN"):
            out.append("SUPER")
        elif up in ("CTRL", "CONTROL"):
            out.append("CTRL")
        elif up == "ALT":
            out.append("ALT")
        elif up == "SHIFT":
            out.append("SHIFT")
        elif up in ("SPACE", "SPC"):
            out.append("SPACE")
        else:
            out.append(s)
    return out


def resolve_ydotool_code(key: str) -> Optional[int]:
    if key is None:
        return None
    if key == " ":
        return YDOTOOL_KEYCODES["SPACE"]
    up = key.upper()
    if up in YDOTOOL_KEYCODES:
        return YDOTOOL_KEYCODES[up]
    if len(key) == 1:
        return YDOTOOL_KEYCODES.get(key.upper())
    return YDOTOOL_KEYCODES.get(key.upper().replace(" ", "_"))


def wtype_keysym(key: str) -> str:
    if not key:
        return key
    if key == "SPACE" or key == " ":
        return "space"
    if len(key) == 1:
        return key
    low = key.lower().replace(" ", "").replace("_", "")
    low2 = key.lower().replace(" ", "_")
    if low in WTYPE_KEY_NAMES:
        return WTYPE_KEY_NAMES[low]
    if low2 in WTYPE_KEY_NAMES:
        return WTYPE_KEY_NAMES[low2]
    if key[0].isupper():
        return key
    return key[:1].upper() + key[1:]


def inject_keycombo(keys: List[str]) -> Dict[str, Any]:
    """Send real key events (prefer ydotool/evdev). No app-specific exec special-cases."""
    keys = normalize_keys(keys)
    mods = [k for k in keys if k in ("SUPER", "ALT", "CTRL", "SHIFT")]
    mains = [k for k in keys if k not in ("SUPER", "ALT", "CTRL", "SHIFT")]
    key = mains[-1] if mains else ""
    if not key and not mods:
        return {"ok": False, "error": "empty keycombo"}

    # --- ydotool (evdev): what Hyprland keybinds actually listen to ---
    if TOOLS["ydotool"]:
        codes: List[int] = []
        missing: List[str] = []
        for m in mods:
            c = resolve_ydotool_code(m)
            if c is None:
                missing.append(m)
            else:
                codes.append(c)
        if key:
            c = resolve_ydotool_code(key)
            if c is None:
                missing.append(key)
            else:
                codes.append(c)
        if not missing and codes:
            # press mods+key in order, release reverse
            seq: List[str] = []
            for c in codes:
                seq.append(f"{c}:1")
            for c in reversed(codes):
                seq.append(f"{c}:0")
            argv = [TOOLS["ydotool"], "key", "-d", "20", *seq]
            print(f"[bridge] ydotool key keys={keys!r} seq={seq}", file=sys.stderr)
            code, _, err = run_cmd(argv, timeout=5)
            if code == 0:
                return {"ok": True, "via": "ydotool", "keys": keys, "seq": seq}
            print(f"[bridge] ydotool key failed: {err!r}", file=sys.stderr)
        elif missing:
            print(f"[bridge] ydotool missing keycodes for {missing!r}, falling back", file=sys.stderr)

    # --- wtype fallback (virtual-keyboard; less reliable with Hypr binds) ---
    if TOOLS["wtype"]:
        args = [TOOLS["wtype"]]
        for m in mods:
            args.extend(["-M", MOD_MAP_WTYPE[m]])
        if mods:
            args.extend(["-s", "40"])
        if key:
            if len(key) == 1 and key not in ("SPACE",):
                args.append(key)
            else:
                kn = wtype_keysym(key)
                args.extend(["-P", kn, "-p", kn])
        for m in reversed(mods):
            args.extend(["-m", MOD_MAP_WTYPE[m]])
        print(f"[bridge] wtype fallback argv={args!r}", file=sys.stderr)
        code, _, err = run_cmd(args)
        return {
            "ok": code == 0,
            "via": "wtype",
            "error": err if code else None,
            "keys": keys,
            "keysym": wtype_keysym(key) if key else None,
        }

    return {"ok": False, "error": "no ydotool/wtype", "dry_run": True, "keys": keys}


def inject_text(text: str) -> Dict[str, Any]:
    """Prefer clipboard paste (Ctrl+V). wtype drops leading glyphs for JP / VoiceBox-like flows."""
    if text is None:
        return {"ok": False, "error": "no text"}
    text = str(text).replace("\r\n", "\n").strip("\n")
    if not text:
        return {"ok": True, "skipped": True}

    print(f"[bridge] inject_text chars={len(text)} head={text[:12]!r}", file=sys.stderr)

    wl_copy = shutil.which("wl-copy")
    if wl_copy:
        try:
            # wl-copy without -f forks a clipboard daemon. capture_output=True hangs because
            # the child keeps stdout/stderr pipes open — always use DEVNULL.
            # Never use -f/-o here (blocks the WS thread until paste).
            proc = subprocess.run(
                [wl_copy, "-n"],
                input=text.encode("utf-8"),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=3,
            )
            if proc.returncode == 0:
                time.sleep(0.08)
                r = inject_keycombo(["CTRL", "v"])
                print(
                    f"[bridge] paste via=wl-copy+ctrl-v ok={r.get('ok')} err={r.get('error')!r}",
                    file=sys.stderr,
                )
                if r.get("ok"):
                    r["via"] = "wl-copy+ctrl-v"
                    r["chars"] = len(text)
                    return r
            else:
                print(f"[bridge] wl-copy exit={proc.returncode}", file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            print(f"[bridge] clipboard paste error: {e}", file=sys.stderr)

    if TOOLS["wtype"]:
        code, out, err = run_cmd([TOOLS["wtype"], "-d", "5", "--", text], timeout=60)
        print(f"[bridge] wtype fallback exit={code} err={err!r}", file=sys.stderr)
        return {"ok": code == 0, "via": "wtype", "error": err if code else None, "chars": len(text)}
    if TOOLS["ydotool"]:
        code, _, err = run_cmd([TOOLS["ydotool"], "type", "--", text], timeout=60)
        return {"ok": code == 0, "via": "ydotool", "error": err if code else None, "chars": len(text)}
    return {"ok": False, "error": "no wl-copy/wtype/ydotool", "dry_run": True, "text": text}


def inject_pointer(dx: float, dy: float) -> Dict[str, Any]:
    idx, idy = int(round(dx)), int(round(dy))
    if idx == 0 and idy == 0:
        return {"ok": True, "skipped": True}
    if TOOLS["ydotool"]:
        code, _, err = run_cmd([TOOLS["ydotool"], "mousemove", "-x", str(idx), "-y", str(idy)])
        return {"ok": code == 0, "via": "ydotool", "error": err if code else None}
    if TOOLS["dotool"]:
        try:
            p = subprocess.run(
                [TOOLS["dotool"]],
                input=f"mousemove {idx} {idy}\n",
                capture_output=True,
                text=True,
                timeout=2,
            )
            return {"ok": p.returncode == 0, "via": "dotool", "error": p.stderr if p.returncode else None}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e)}
    # Hyprland 0.56+ (Omarchy): relative move via absolute cursor.move
    if TOOLS["hyprctl"]:
        code, out, err = run_cmd([TOOLS["hyprctl"], "-j", "cursorpos"])
        if code == 0 and out.strip():
            try:
                pos = json.loads(out)
                nx = int(round(float(pos.get("x", 0)) + idx))
                ny = int(round(float(pos.get("y", 0)) + idy))
                lua = f"hl.dsp.cursor.move({{ x = {nx}, y = {ny} }})"
                c2, out2, err2 = run_cmd([TOOLS["hyprctl"], "dispatch", lua])
                return {
                    "ok": c2 == 0,
                    "via": "hyprctl",
                    "x": nx,
                    "y": ny,
                    "error": (err2 or out2) if c2 else None,
                }
            except Exception as e:  # noqa: BLE001
                return {"ok": False, "error": str(e)}
    return {"ok": False, "error": "no ydotool/dotool/hyprctl for pointer", "dry_run": True, "dx": idx, "dy": idy}


def inject_click(button: str = "left") -> Dict[str, Any]:
    b = (button or "left").lower()
    if TOOLS["ydotool"]:
        # 0xC0 left, 0xC1 right, 0xC2 middle (common ydotool codes)
        code_map = {"left": "0xC0", "right": "0xC1", "middle": "0xC2", "forward": "0xC5", "back": "0xC6", "side": "0xC3", "extra": "0xC4"}
        code, _, err = run_cmd([TOOLS["ydotool"], "click", code_map.get(b, "0xC0")])
        return {"ok": code == 0, "via": "ydotool", "error": err if code else None}
    if TOOLS["dotool"]:
        try:
            p = subprocess.run(
                [TOOLS["dotool"]],
                input=f"click {b}\n",
                capture_output=True,
                text=True,
                timeout=2,
            )
            return {"ok": p.returncode == 0, "via": "dotool"}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e)}
    return {"ok": False, "error": "no ydotool/dotool for click", "dry_run": True, "button": b}


def inject_scroll(dx: float, dy: float) -> Dict[str, Any]:
    idx, idy = int(round(dx)), int(round(dy))
    if TOOLS["ydotool"]:
        # wheel: ydotool mousemove --wheel
        args = [TOOLS["ydotool"], "mousemove", "--wheel", "-x", str(idx), "-y", str(idy)]
        code, _, err = run_cmd(args)
        if code != 0:
            # older ydotool: mousemove -w
            code, _, err = run_cmd([TOOLS["ydotool"], "mousemove", "-w", "-x", str(idx), "-y", str(idy)])
        return {"ok": code == 0, "via": "ydotool", "error": err if code else None}
    return {"ok": False, "error": "no ydotool for scroll", "dry_run": True, "dx": idx, "dy": idy}


def hypr_dispatch_lua(lua: str) -> Dict[str, Any]:
    """Hyprland 0.56+ / Omarchy: dispatchers are Lua hl.dsp.* expressions."""
    if not TOOLS["hyprctl"]:
        return {"ok": False, "error": "hyprctl not found", "dry_run": True, "lua": lua}
    code, out, err = run_cmd([TOOLS["hyprctl"], "dispatch", lua])
    return {"ok": code == 0, "via": "hyprctl", "out": (out or "").strip(), "error": (err or out) if code else None}


def hypr_dispatch(request: str) -> Dict[str, Any]:
    # Back-compat shim: map legacy strings to Lua dsp when possible
    req = (request or "").strip()
    if req.startswith("hl.dsp.") or req.startswith("hl.dispatch("):
        return hypr_dispatch_lua(req)
    parts = req.split()
    if not parts:
        return {"ok": False, "error": "empty dispatch"}
    head = parts[0]
    if head == "workspace" and len(parts) >= 2:
        arg = parts[1]
        if arg in ("+1", "e+1"):
            return hypr_dispatch_lua('hl.dsp.focus({ workspace = "e+1" })')
        if arg in ("-1", "e-1"):
            return hypr_dispatch_lua('hl.dsp.focus({ workspace = "e-1" })')
        return hypr_dispatch_lua(f'hl.dsp.focus({{ workspace = "{arg}" }})')
    if head == "cyclenext":
        return hypr_dispatch_lua('hl.dsp.focus({ direction = "r" })')
    if head == "cycleprev":
        return hypr_dispatch_lua('hl.dsp.focus({ direction = "l" })')
    if head == "exec" and len(parts) >= 2:
        cmd = " ".join(parts[1:]).replace("\\", "\\\\").replace('"', '\\"')
        return hypr_dispatch_lua(f'hl.dsp.exec_cmd("{cmd}")')
    # last resort: legacy (often broken on 0.56)
    if not TOOLS["hyprctl"]:
        return {"ok": False, "error": "hyprctl not found", "dry_run": True, "request": request}
    code, out, err = run_cmd([TOOLS["hyprctl"], "dispatch"] + parts)
    return {"ok": code == 0, "via": "hyprctl-legacy", "out": (out or "").strip(), "error": (err or out) if code else None}


def handle_shortcut(sid: str) -> Dict[str, Any]:
    sid = str(sid or "").strip()
    if sid.startswith("workspace:") and sid.split(":", 1)[1].isdigit():
        n = sid.split(":", 1)[1]
        return hypr_dispatch_lua(f'hl.dsp.focus({{ workspace = "{n}" }})')
    if sid == "workspace:next":
        return hypr_dispatch_lua('hl.dsp.focus({ workspace = "e+1" })')
    if sid == "workspace:prev":
        return hypr_dispatch_lua('hl.dsp.focus({ workspace = "e-1" })')
    if sid == "window:next":
        return hypr_dispatch_lua('hl.dsp.focus({ direction = "r" })')
    if sid == "window:prev":
        return hypr_dispatch_lua('hl.dsp.focus({ direction = "l" })')
    if sid in ("menu", "launcher"):
        # Real Super+Space key event (not bare omarchy-menu exec)
        r = inject_keycombo(["SUPER", "SPACE"])
        if r.get("ok"):
            return r
        return hypr_dispatch_lua('hl.dsp.exec_cmd("omarchy-menu toggle")')
    if sid == "terminal":
        return inject_keycombo(["SUPER", "Return"])
    if sid in SHORTCUT_HYPR:
        return hypr_dispatch(SHORTCUT_HYPR[sid])
    return {"ok": False, "error": f"unknown shortcut id: {sid}"}


def fetch_hypr_state() -> Dict[str, Any]:
    state: Dict[str, Any] = {"workspaces": [], "windows": [], "focused": None}
    if not TOOLS["hyprctl"]:
        return state
    code, out, _ = run_cmd([TOOLS["hyprctl"], "-j", "workspaces"])
    if code == 0 and out.strip():
        try:
            wss = json.loads(out)
            state["workspaces"] = [
                {"id": w.get("id"), "name": str(w.get("name", w.get("id"))), "windows": w.get("windows", 0)}
                for w in wss
            ]
        except json.JSONDecodeError:
            pass
    code, out, _ = run_cmd([TOOLS["hyprctl"], "-j", "clients"])
    if code == 0 and out.strip():
        try:
            clients = json.loads(out)
            wins = []
            for c in clients:
                wins.append({
                    "id": c.get("address") or str(c.get("id")),
                    "title": c.get("title") or "",
                    "class": c.get("class") or "",
                    "workspace": (c.get("workspace") or {}).get("id", 1),
                })
            state["windows"] = wins
        except json.JSONDecodeError:
            pass
    code, out, _ = run_cmd([TOOLS["hyprctl"], "-j", "activewindow"])
    if code == 0 and out.strip():
        try:
            aw = json.loads(out)
            state["focused"] = aw.get("address")
            state["activeWorkspace"] = (aw.get("workspace") or {}).get("id")
        except json.JSONDecodeError:
            pass
    return state


# ---------------------------------------------------------------------------
# WebSocket (RFC 6455, text frames)
# ---------------------------------------------------------------------------

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_accept_key(key: str) -> str:
    digest = hashlib.sha1((key + GUID).encode("utf-8")).digest()
    return base64.b64encode(digest).decode("ascii")


def ws_recv_frame(conn: socket.socket) -> Tuple[int, bytes]:
    hdr = _recv_exact(conn, 2)
    if not hdr:
        return -1, b""
    b1, b2 = hdr[0], hdr[1]
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F
    if length == 126:
        ext = _recv_exact(conn, 2)
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = _recv_exact(conn, 8)
        length = struct.unpack("!Q", ext)[0]
    mask = _recv_exact(conn, 4) if masked else b""
    payload = _recv_exact(conn, length) if length else b""
    if masked and payload:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def ws_send_frame(conn: socket.socket, payload: bytes, opcode: int = 0x1) -> None:
    header = bytearray()
    header.append(0x80 | (opcode & 0x0F))
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < (1 << 16):
        header.append(126)
        header.extend(struct.pack("!H", n))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", n))
    conn.sendall(header + payload)


def _recv_exact(conn: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            return bytes(buf)
        buf.extend(chunk)
    return bytes(buf)


# ---------------------------------------------------------------------------
# Bridge state
# ---------------------------------------------------------------------------

class BridgeState:
    def __init__(self, token: str, port: int, host_ip: str, dry_run: bool = False):
        self.token = token
        self.port = port
        self.host_ip = host_ip
        self.dry_run = dry_run
        self.clients = 0
        self.lock = threading.Lock()
        self.started_at = time.time()

    def pair_url(self) -> str:
        # Prefer Tailscale Serve (Let's Encrypt on *.ts.net) so Android can install the PWA.
        # Cache base once — flipping MagicDNS↔IP every status poll makes the panel QR flicker.
        if getattr(self, "_public_base", None):
            base = self._public_base
        else:
            base = (os.environ.get("COMPANION_PUBLIC_BASE") or "").rstrip("/")
            if not base:
                dns = detect_tailscale_dns()
                # Stable PWA origin: Tailscale Serve on :443 path /companion (no changing ports)
                override = (os.environ.get("COMPANION_SERVE_PORT") or "").strip()
                if dns and override:
                    base = f"https://{dns}:{override}"
                elif dns:
                    base = f"https://{dns}/companion"
            if not base:
                base = f"https://{self.host_ip}:{self.port}"
            self._public_base = base
        return f"{base}/?token={urllib.parse.quote(self.token)}"

    def info(self) -> Dict[str, Any]:
        return {
            "url": self.pair_url(),
            "token": self.token,
            "port": self.port,
            "host": self.host_ip,
            "clients": self.clients,
            "tools": {k: bool(v) for k, v in TOOLS.items()},
            "dryRun": self.dry_run,
            "phoneDir": str(PHONE_DIR),
            "uptimeSec": int(time.time() - self.started_at),
        }

    def write_status(self) -> None:
        info = self.info()
        try:
            STATUS_PATH.write_text(json.dumps(info, indent=2), encoding="utf-8")
        except Exception:  # noqa: BLE001
            pass
        # stdout line for Service.qml Process reader
        print("STATUS " + json.dumps(info, separators=(",", ":")), flush=True)

    def bump_clients(self, delta: int) -> None:
        with self.lock:
            self.clients = max(0, self.clients + delta)
        self.write_status()


STATE: Optional[BridgeState] = None


def handle_message(msg: Dict[str, Any]) -> Dict[str, Any]:
    assert STATE is not None
    mtype = msg.get("type")
    if mtype == "ping":
        return {"type": "pong", "t": time.time(), "pong": True}
    if mtype == "pointer":
        r = inject_pointer(float(msg.get("dx") or 0), float(msg.get("dy") or 0))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "pointer", **r}
    if mtype == "click":
        r = inject_click(str(msg.get("button") or "left"))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "click", **r}
    if mtype == "scroll":
        r = inject_scroll(float(msg.get("dx") or 0), float(msg.get("dy") or 0))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "scroll", **r}
    if mtype == "keycombo":
        keys = msg.get("keys") or []
        if isinstance(keys, str):
            keys = [p for p in keys.replace("-", "+").split("+") if p]
        r = inject_keycombo(list(keys))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "keycombo", **r}
    if mtype == "text":
        r = inject_text(str(msg.get("text") or ""))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "text", **r}
    if mtype == "shortcut":
        r = handle_shortcut(str(msg.get("id") or ""))
        if STATE.dry_run:
            r["dry_run"] = True
            r["ok"] = True
        return {"type": "ack" if r.get("ok") else "error", "op": "shortcut", **r}
    if mtype == "state":
        st = fetch_hypr_state()
        return {"type": "state", **st}
    return {"type": "error", "error": f"unknown type: {mtype}"}


def ws_session(conn: socket.socket, token_ok: bool) -> None:
    assert STATE is not None
    if not token_ok:
        try:
            ws_send_frame(conn, json.dumps({"type": "error", "error": "unauthorized"}).encode("utf-8"))
        finally:
            conn.close()
        return
    STATE.bump_clients(1)
    try:
        hello = {
            "type": "hello",
            "version": "0.2.0",
            "features": ["pointer", "click", "scroll", "keycombo", "text", "shortcut", "state"],
            "tools": {k: bool(v) for k, v in TOOLS.items()},
            "dryRun": STATE.dry_run,
        }
        ws_send_frame(conn, json.dumps(hello).encode("utf-8"))
        st = fetch_hypr_state()
        ws_send_frame(conn, json.dumps({"type": "state", **st}).encode("utf-8"))
        # App-level + protocol keepalive: drop dead sockets (e.g. Tailscale gone)
        # instead of leaving a zombie "connected" session.
        conn.settimeout(15)
        missed_pong = 0
        while True:
            try:
                opcode, payload = ws_recv_frame(conn)
                missed_pong = 0
            except socket.timeout:
                missed_pong += 1
                if missed_pong > 2:
                    sys.stderr.write("[bridge] ws keepalive timeout - closing\n")
                    break
                try:
                    ws_send_frame(conn, b"", opcode=0x9)
                    continue
                except Exception:  # noqa: BLE001
                    break
            except Exception:  # noqa: BLE001
                break
            if opcode in (-1, 0x8):
                break
            if opcode == 0x9:  # ping
                ws_send_frame(conn, payload, opcode=0xA)
                continue
            if opcode == 0xA:  # pong
                continue
            if opcode != 0x1:
                continue
            try:
                msg = json.loads(payload.decode("utf-8"))
            except Exception:  # noqa: BLE001
                ws_send_frame(conn, json.dumps({"type": "error", "error": "bad json"}).encode("utf-8"))
                continue
            if not isinstance(msg, dict):
                ws_send_frame(conn, json.dumps({"type": "error", "error": "expected object"}).encode("utf-8"))
                continue
            reply = handle_message(msg)
            ws_send_frame(conn, json.dumps(reply).encode("utf-8"))
    finally:
        STATE.bump_clients(-1)
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass



def ensure_tls_certs(cert_dir: Path, extra_ips: list[str] | None = None) -> tuple[Path, Path]:
    """Self-signed cert so Android can register a service worker / install PWA."""
    import subprocess

    cert_dir.mkdir(parents=True, exist_ok=True)
    cert = cert_dir / "cert.pem"
    key = cert_dir / "key.pem"
    ips: list[str] = ["127.0.0.1"]
    for cand in (extra_ips or []):
        if cand and cand not in ips:
            ips.append(cand)
    ts = detect_tailscale_ip()
    if ts and ts not in ips:
        ips.append(ts)
    lan = detect_lan_ip()
    if lan and lan not in ips:
        ips.append(lan)

    need = True
    if cert.is_file() and key.is_file():
        try:
            dump = subprocess.check_output(
                ["openssl", "x509", "-in", str(cert), "-noout", "-text"],
                text=True,
            )
            if all(ip in dump for ip in ips):
                need = False
        except Exception:  # noqa: BLE001
            need = True

    if not need:
        return cert, key

    alt_lines = ["DNS.1 = localhost"] + [f"IP.{i} = {ip}" for i, ip in enumerate(ips, start=1)]
    conf = cert_dir / "openssl.cnf"
    conf.write_text(
        "\n".join(
            [
                "[req]",
                "distinguished_name = req_distinguished_name",
                "x509_extensions = v3_req",
                "prompt = no",
                "[req_distinguished_name]",
                "CN = omarchy-companion",
                "[v3_req]",
                "keyUsage = digitalSignature, keyEncipherment",
                "extendedKeyUsage = serverAuth",
                "subjectAltName = @alt_names",
                "[alt_names]",
                *alt_lines,
                "",
            ]
        )
    )
    cmd = [
        "openssl",
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-keyout",
        str(key),
        "-out",
        str(cert),
        "-days",
        "825",
        "-nodes",
        "-config",
        str(conf),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    print(f"[bridge] generated TLS cert at {cert} SAN IPs={ips}", file=sys.stderr)
    return cert, key


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".json": "application/json",
    ".webmanifest": "application/manifest+json",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
    ".map": "application/json",
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[bridge] " + (fmt % args) + "\n")

    def _check_token_query(self) -> bool:
        assert STATE is not None
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        tok = (qs.get("token") or [None])[0]
        if tok and tok == STATE.token:
            return True
        auth = self.headers.get("Authorization") or ""
        if auth.lower().startswith("bearer ") and auth[7:].strip() == STATE.token:
            return True
        xt = self.headers.get("X-Companion-Token") or ""
        return xt == STATE.token

    def do_GET(self) -> None:  # noqa: N802
        assert STATE is not None
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path or "/"

        if path == "/ws":
            self._upgrade_ws()
            return

        if path in ("/api/pair", "/api/status"):
            body = json.dumps(STATE.info()).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
            return

        if path == "/qr.svg":
            self._serve_qr_svg()
            return
        if path == "/qr.png":
            self._serve_qr_png()
            return

        # static from phone/
        rel = path.lstrip("/")
        if not rel or rel == "/":
            rel = "index.html"
        # prevent path escape
        candidate = (PHONE_DIR / rel).resolve()
        if not str(candidate).startswith(str(PHONE_DIR.resolve())):
            self.send_error(403)
            return
        if not candidate.is_file():
            self.send_error(404)
            return
        data = candidate.read_bytes()
        ctype = MIME.get(candidate.suffix.lower(), "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Companion-Token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def _serve_qr_svg(self) -> None:
        assert STATE is not None
        url = STATE.pair_url()
        svg = None
        if TOOLS["qrencode"]:
            code, out, _ = run_cmd([TOOLS["qrencode"], "-t", "SVG", "-o", "-", url], timeout=5)
            if code == 0 and out.strip().startswith("<"):
                svg = out
        if not svg:
            # Minimal fallback: SVG with URL text (not a real QR)
            safe = (
                url.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
            )
            svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="320" height="320" viewBox="0 0 320 320">
  <rect width="320" height="320" fill="#12121a"/>
  <rect x="16" y="16" width="288" height="288" rx="16" fill="#1a1a26" stroke="#7c6cff" stroke-width="2"/>
  <text x="160" y="140" text-anchor="middle" fill="#e8e8f0" font-family="sans-serif" font-size="16" font-weight="bold">Scan / open URL</text>
  <foreignObject x="32" y="160" width="256" height="120">
    <div xmlns="http://www.w3.org/1999/xhtml" style="color:#4fd1c5;font:12px monospace;word-break:break-all;text-align:center">{safe}</div>
  </foreignObject>
</svg>'''
        data = svg.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "image/svg+xml")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def _serve_qr_png(self) -> None:
        url = STATE.get("url") or ""
        if not url:
            self.send_error(404, "no pair url")
            return
        if TOOLS.get("qrencode"):
            import tempfile
            path = "/tmp/omarchy-companion-qr-http.png"
            code, _, err = run_cmd([TOOLS["qrencode"], "-t", "PNG", "-s", "8", "-m", "2", "-o", path, url], timeout=5)
            if code == 0 and Path(path).is_file():
                data = Path(path).read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
        self.send_error(503, "qrencode unavailable")


    def _upgrade_ws(self) -> None:
        assert STATE is not None
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        tok = (qs.get("token") or [None])[0]
        auth = self.headers.get("Authorization") or ""
        if not tok and auth.lower().startswith("bearer "):
            tok = auth[7:].strip()
        if not tok:
            tok = self.headers.get("X-Companion-Token")
        token_ok = bool(tok) and tok == STATE.token

        # Reject BEFORE 101 so Tailscale Serve does not open a second WS that
        # knocks the good phone connection offline.
        if not token_ok:
            body = b'{"error":"unauthorized"}'
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            sys.stderr.write(f"[bridge] ws rejected bad token …{(tok or '')[-4:]}\n")
            return

        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "Missing Sec-WebSocket-Key")
            return
        accept = ws_accept_key(key)
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()

        conn = self.connection
        try:
            self.close_connection = True
            ws_session(conn, True)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"[bridge] ws error: {e}\n")


def find_free_port(start: int, host: str = "0.0.0.0") -> int:
    port = start
    for _ in range(30):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((host, port))
                return port
            except OSError:
                port += 1
    raise RuntimeError("no free port")


def main(argv: Optional[List[str]] = None) -> int:
    global STATE, PHONE_DIR, STATUS_PATH
    ap = argparse.ArgumentParser(
        description="Omarchy Companion phone bridge (HTTP + WebSocket)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    ap.add_argument("--host", default="0.0.0.0", help="bind address")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="preferred TCP port")
    ap.add_argument("--token", default=None, help="auth token (random if omitted)")
    ap.add_argument("--pair-state", default=None, help="JSON file to persist pairing token")
    ap.add_argument("--phone-dir", default=str(PHONE_DIR), help="static phone UI directory")
    ap.add_argument("--status-file", default=str(STATUS_PATH), help="JSON status file path")
    ap.add_argument("--dry-run", action="store_true", help="accept commands without injecting")
    ap.add_argument("--advertise-ip", default=None, help="LAN IP shown in pair URL")
    ap.add_argument("--http", action="store_true", help="plain HTTP (Tailscale Serve terminates TLS)")
    ap.add_argument("--https", action="store_true", help="self-signed HTTPS (legacy direct access)")
    args = ap.parse_args(argv)

    PHONE_DIR = Path(args.phone_dir).resolve()
    STATUS_PATH = Path(args.status_file)

    if not PHONE_DIR.is_dir():
        print(f"warning: phone dir missing: {PHONE_DIR}", file=sys.stderr)

    # Free preferred port only (do not kill unrelated healthy bridges on other ports)
    try:
        import signal
        from pathlib import Path as _P
        preferred = int(args.port)
        for proc in _P("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                parts = [x for x in (proc / "cmdline").read_bytes().split(b"\0") if x]
            except Exception:
                continue
            if not parts:
                continue
            base = _P(parts[0].decode("utf-8", "replace")).name
            if not base.startswith("python"):
                continue
            if not any(x.endswith(b"bridge/server.py") for x in parts):
                continue
            pid = int(proc.name)
            if pid == os.getpid():
                continue
            # Only kill siblings advertising the same --port
            try:
                idx = parts.index(b"--port")
                their_port = int(parts[idx + 1].decode())
            except Exception:
                their_port = preferred
            if their_port != preferred:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
                print(f"[bridge] stopped sibling pid={pid} on port {preferred}", file=sys.stderr)
            except Exception:
                pass
        time.sleep(0.35)
    except Exception as e:
        print(f"[bridge] sibling cleanup skipped: {e}", file=sys.stderr)

    port = find_free_port(args.port, args.host if args.host != "0.0.0.0" else "0.0.0.0")
    pair_state = Path(args.pair_state) if getattr(args, "pair_state", None) else default_pair_state_path()
    token = args.token or load_persisted_token(pair_state) or generate_token()
    host_ip = resolve_advertise_ip(args.advertise_ip)

    STATE = BridgeState(token=token, port=port, host_ip=host_ip, dry_run=args.dry_run)
    # Freeze + persist pair URL so phone can reconnect without rescanning
    _ = STATE.pair_url()
    save_persisted_token(token, public_base=getattr(STATE, "_public_base", None), port=port, path=pair_state)
    print(f"[bridge] pair-state {pair_state} token=…{token[-4:]}", file=sys.stderr)
    ensure_hyprland_env()

    server = ThreadingHTTPServer((args.host, port), Handler)
    use_tls = bool(args.https) and not bool(args.http)
    # Default: plain HTTP behind Tailscale Serve (stable WebSocket). Use --https for direct IP.
    if not args.https and not args.http:
        use_tls = False
    if use_tls:
        cert_path, key_path = ensure_tls_certs(Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "omarchy-companion-tls", [host_ip])
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(cert_path), str(key_path))
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    else:
        scheme = "http"
    print(
        f"READY {json.dumps({'port': port, 'url': STATE.pair_url(), 'token': token})}",
        flush=True,
    )
    STATE.write_status()
    print(f"[bridge] serving {PHONE_DIR} on {scheme}://{args.host}:{port}/", file=sys.stderr)
    print(f"[bridge] pair URL: {STATE.pair_url()}", file=sys.stderr)
    if use_tls:
        print("[bridge] self-signed TLS enabled", file=sys.stderr)
    else:
        print("[bridge] plain HTTP (use Tailscale Serve /companion for HTTPS+PWA)", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] stopping", file=sys.stderr)
    finally:
        server.server_close()
        try:
            if STATUS_PATH.exists():
                STATUS_PATH.unlink()
        except Exception:  # noqa: BLE001
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
