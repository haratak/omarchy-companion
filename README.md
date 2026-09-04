# Omarchy Companion

Phone-paired remote for Omarchy Quattro. Pair a phone on the same LAN, then drive the desktop with **Pad · Switch · Keys · Type**. The in-shell panel still exposes Stage / Input / Menu for on-device touch.

Plugin ID: `harataku.companion` (`omarchy.` prefix is reserved).

## Phone pairing (v0.2)

1. Open the Companion panel (bar **Pad** button or `omarchy-shell shell summon harataku.companion '{}'`).
2. Default tab is **Pair** — tap **Start bridge**.
3. Open the shown LAN URL on your phone (same Wi‑Fi). Token is in the query string.
4. Use the phone UI:
   - **Pad** — relative pointer / click / scroll
   - **Switch** — workspaces & window cycle shortcuts
   - **Keys** — keycombos (default **VoiceBox** = `SUPER+SHIFT+V`; edit to match your bind)
   - **Type** — text injection via `wtype` / `ydotool`

Bridge IPC (from a shell):

```sh
omarchy-shell shell call harataku.companion startBridge
omarchy-shell shell call harataku.companion pairInfo
omarchy-shell shell call harataku.companion stopBridge
```

Status JSON is written to `/tmp/omarchy-companion-bridge.json` while the bridge runs. The bar widget turns teal when `clients > 0`.

### Dry-run (no Hyprland / injectors required)

```sh
cd /workspace/omarchy-companion-plugin   # or ~/.config/omarchy/plugins/harataku.companion
python3 bridge/server.py --dry-run --token testtoken --port 17832 \
  --phone-dir ./phone --status-file /tmp/omarchy-companion-bridge.json \
  --advertise-ip 127.0.0.1
```

In another terminal:

```sh
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:17832/?token=testtoken"
# expect 200
curl -s "http://127.0.0.1:17832/api/status?token=testtoken" | head
node test/model-test.js
```

`--dry-run` accepts WebSocket commands and ACKs them without calling `wtype` / `hyprctl` / `ydotool`.

## Features

| Surface | What it does |
|---------|----------------|
| Phone Pad | Relative pointer, click, scroll |
| Phone Switch | `workspace:N`, next/prev window, menu |
| Phone Keys | Configurable combos; VoiceBox default `SUPER+SHIFT+V` |
| Phone Type | UTF-8 text via wtype/ydotool |
| Panel Stage | Window thumbnails, workspace swipe / hold gestures |
| Panel Input | On-shell QWERTY + trackpad deck |
| Panel Menu | Launch / workspace / session actions |
| Control Centre | Volume / brightness (wpctl / brightnessctl) |

## Dependencies

**Required**

- Omarchy Quattro (`omarchy-shell` / Quickshell)
- Python 3 (stdlib only) for `bridge/server.py`

**For live inject / window control**

- Hyprland (`hyprctl`)
- `wtype` and/or `ydotool` / `dotool`
- Optional: `wpctl`, `brightnessctl`, `qrencode` (QR for `/qr.svg`)

## Install

```sh
omarchy plugin add <git-url> --enable
# or
mkdir -p ~/.config/omarchy/plugins
cp -a /path/to/omarchy-companion-plugin ~/.config/omarchy/plugins/harataku.companion
omarchy-shell shell rescanPlugins
omarchy plugin enable harataku.companion
omarchy bar put harataku.companion --section right
```

`pluginDir` resolves from `Qt.resolvedUrl(".")`. For manual overrides, set Service `pluginDir` to:

- `~/.config/omarchy/plugins/harataku.companion` (install)
- `/workspace/omarchy-companion-plugin` (dev)

The bridge is **not** auto-started on service load.

## Tests / validate

```sh
omarchy plugin validate .
node test/model-test.js
```

## Architecture

```
manifest.json          plugin contract (v0.2.0)
Service.qml            Hyprland snapshot + bridge lifecycle + IpcHandler
BarWidget.qml          Pad button; teal when phone connected
Panel.qml              Pair / Stage / Input / Menu (+ Control Centre)
CompanionModel.js      pure JS state + pairing helpers (testable)
bridge/server.py       stdlib HTTP + WebSocket phone bridge
phone/                 mobile UI (index.html, app.js, app.css)
test/model-test.js     Node unit tests
```

## Security

The bridge binds `0.0.0.0` and requires the pair token on HTTP/WS. Anyone on your LAN with the URL can inject input — stop the bridge when not in use. Omarchy plugins are **not sandboxed**; review third-party repos before enabling.

## License

MIT — see `LICENSE`.

## GitHub / Cursor

- Repo: https://github.com/haratak/omarchy-companion
- This plugin directory **is** the git working tree (`~/.config/omarchy/plugins/harataku.companion`).
- Develop via Cursor cloud agents on that repo; after merge:

```bash
cd ~/.config/omarchy/plugins/harataku.companion && git pull --ff-only
```

- `state/` (pairing token) is gitignored and stays local only.
