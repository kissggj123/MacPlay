# MacPlay fork: browser re-stream (web streaming)

This fork adds a **browser client** to MacPlay: the CarPlay video is re-streamed
as MJPEG over HTTP, and browser touch is injected back as multitouch HID
reports. Target use case: open `http://<mac-lan-ip>:8080/` in the **car
head-unit browser** (e.g. NIO) while the Mac does the CarPlay hosting.

Upstream: [Roylyl/MacPlay](https://github.com/Roylyl/MacPlay) (GPL-3.0).
All CarPlay transports (USB via system usbmuxd, wireless via IOBluetooth +
shared WiFi), MFi auth and the Electron UI are untouched upstream code.

## Architecture

```
iPhone --CarPlay--> livi-helperd (Rust)
                        |
              GStreamer pipeline (decoded video)
               /                    \
   glimagesink (local window,      tee -> videoconvert -> videoscale(960w)
   unchanged)                       -> jpegenc -> appsink "websink"
                                              |
                                    webtap.rs: MJPEG on 127.0.0.1:18081/mjpeg
                                              |
MacPlay Engine (Node.js, main.ts) --spawns--> helper (env MACPLAY_WEB_PORT=18081)
   |
   webserver.ts: HTTP 0.0.0.0:8080
     GET /        webclient.html (MJPEG <img> + touch)
     GET /mjpeg   proxy -> 127.0.0.1:18081/mjpeg
     WS  /touch   -> CpStack.sendTouches() (existing HID injection path)
```

Design notes:

- **Rust change is additive and env-gated.** `MACPLAY_WEB_PORT` unset ⇒ the
  GStreamer pipeline description is byte-identical to upstream. If the web
  branch fails to parse (e.g. `jpegenc` missing from the bundled GStreamer),
  the player retries without the tap — the local window can never break.
- **Touch reuses the existing path.** `CpStack.sendTouches()` already takes
  normalised 0..1 coordinates and emits multitouch HID reports (2 contacts).
  The browser sends the same shape over WebSocket; no new protocol.
- **No new dependencies.** Rust: std only (hand-rolled HTTP/1.0 MJPEG).
  Node: `node:http` + `node:crypto` only (hand-rolled RFC 6455 server subset).

## Changed / added files

| File | Change |
|---|---|
| `native/livi-gst-video/rust/codec/src/lib.rs` | `pipeline_desc()`: tee branch (`jpegenc` → `appsink name=websink`) when `MACPLAY_WEB_PORT` set; `MACPLAY_HEADLESS=1` → `fakesink` instead of `glimagesink` |
| `native/livi-gst-video/rust/player/src/lib.rs` | `mod webtap`; hook in `Player::new`; parse fallback without tap |
| `native/livi-gst-video/rust/player/src/webtap.rs` | **new**: appsink pull → MJPEG HTTP on 127.0.0.1:$PORT |
| `native/livi-gst-video/rust/audioplayer/src/lib.rs` | `pipeline_desc()`: tee PCM → `appsink name=webaudio` when `MACPLAY_WEB_PORT` set (drops local `osxaudiosink`); `mod webaudio`; tap register/unregister |
| `native/livi-gst-video/rust/audioplayer/src/webaudio.rs` | **new**: PCM tap per stream → wheelplay-protocol frames → TCP relay on 127.0.0.1:$AUDIO_PORT for the Node WS relay |
| `native/Engine/webserver.ts` | **new**: HTTP :8080 + WS `/touch` → `sendTouches()`; `/audio` proxy |
| `native/Engine/webclient.html` | **new**: browser client (copied to `build/engine/`); fullscreen video by default; `<audio>` for CarPlay audio |
| `native/Engine/main.ts` | import + `MACPLAY_WEB_PORT`/`_AUDIO_PORT` env in Engine process + `startWebServer()`; **OEM homescreen icon removed** (`icons=[]`); no-sleep `caffeinate -s` while connected (setting); headless env sync |
| `native/Engine/media.ts` | headless: skip native window creation/presentation |
| `native/App/MacPlay.swift` | settings: "CarPlay连接时防止系统休眠" + "无头模式" toggles |
| `native/App/Localization.swift` | translations for the new toggles |
| `scripts/build-macplay.sh` | copy `webclient.html` into `build/engine/` |
| `scripts/car-mode.sh` | **new**: display-off + no-sleep toggle for in-car use |

## Apply (on your Mac)

```bash
# 1. fork Roylyl/MacPlay on github.com, then:
git clone https://github.com/<you>/MacPlay.git
cd MacPlay
git checkout -b web-streaming

# 2. unpack this package at the repo root and apply:
tar -xzf macplay-fork-webstream.tar.gz
./macplay-fork/apply.sh   # git apply patches + copy new files

git status   # review
git add -A && git commit -m "web streaming: MJPEG browser re-stream + touch"
```

`apply.sh` is idempotent-ish: it skips patches that already apply cleanly in
reverse (i.e. already applied).

## Build (on your Mac, Apple Silicon or Intel)

Prerequisites (same as upstream): Xcode Command Line Tools, Rust toolchain
(`rustup`), `pnpm`, GStreamer macOS framework (see upstream README/scripts).

```bash
pnpm install
bash scripts/build-macplay.sh
```

What to watch in the build log:

- `cargo` builds the Rust workspace including the new `webtap` module
  (compile errors here → paste them back).
- `tsc -p native/Engine/tsconfig.json` compiles `webserver.ts` (type errors
  → paste them back).
- `[webtap]` / `[webserver]` strings appear nowhere at build time; they log
  at runtime.

## Run & use with the car browser

1. Start MacPlay, connect the iPhone (wired or wireless) until the CarPlay
   window shows video.
2. On the Mac: `curl -s http://127.0.0.1:18081/health` → `{"video":"live"}`
   (proves the Rust tap is serving).
3. Join the Mac and the car head unit to the same LAN (e.g. the NIO hotspot).
4. In the **car browser**: open `http://<mac-lan-ip>:8080/`
   (find the Mac IP in System Settings → Wi-Fi → Details, or `ipconfig getifaddr en0`).
5. Touch the browser page → CarPlay responds. Two-finger touch supported.

### Car mode: display off, system awake (separate window)

Two-window workflow in the car:

- **Window 1 — configure & run**: build once (`bash scripts/build-macplay.sh`),
  launch MacPlay, connect the iPhone. This window is your setup/control plane.
- **Window 2 — car mode toggle**: `./scripts/car-mode.sh`. It does one thing:
  `caffeinate -i` (blocks idle system sleep; deliberately *not* `-d` so the
  display may sleep) + `pmset displaysleepnow` (display off immediately).
  Ctrl-C in that window exits car mode and wakes the display.

The video tap lives inside the GStreamer pipeline (not screen capture), so the
MJPEG stream to the car browser keeps flowing with the display off. Any
keypress wakes the display manually at any time.

### Finding the car-browser URL + firewall

MacPlay's settings (连接 → 应用 → **车机浏览器**) shows every LAN IPv4
address as `http://<ip>:8080` (copy button included, Wi-Fi first).

**Firewall** (macOS System Settings → Network → Firewall): the car browser
needs **TCP 8080** into the Mac. The listener is the `MacPlayReceiver`
binary (`MacPlay.app/Contents/Resources/runtime/.../MacPlayReceiver`).
The settings section shows the firewall state:
- off → nothing to do;
- on + already allowed → nothing to do;
- on + not allowed → **一键放行 MacPlayReceiver** (asks for an admin
  password once and runs `socketfilterfw --add`), or allow it manually —
  macOS also prompts automatically the first time the port is bound.

iPhone↔Mac CarPlay itself (USB via system usbmuxd, wireless via Bluetooth +
Wi-Fi) uses MacPlay's own channels and is unaffected by this.

### In-app options (MacPlay settings → 连接 → 应用)

- **CarPlay连接时防止系统休眠**: while a CarPlay session is active, the Engine
  holds a `caffeinate -s` assertion (`PreventSystemSleep`), so the Mac won't
  sleep — including with the **lid closed** (requires AC power; on battery the
  assertion is ignored by macOS). The display may still sleep normally.
  This largely replaces `scripts/car-mode.sh`.
- **无头模式（不在Mac上显示CarPlay画面）**: no native CarPlay window on the
  Mac at all — video decodes to `fakesink` and only the browser client shows
  it. Takes effect on the next connection.

### CarPlay audio in the car browser

When web streaming is on, every CarPlay audio stream (media, call, Siri,
alerts) is teed after decoding and its PCM frames are forwarded to the car
browser:

- Rust (`audioplayer/src/webaudio.rs`): each pipeline's `webaudio` appsink
  emits raw PCM (S16LE 48 kHz stereo) with a 20-byte header borrowed from
  [wheelplay](https://github.com/fython/wheelplay)'s browser-audio protocol
  (magic `0x31415057`, stream id, rate/channels, media flag, sequence).
  Frames go over TCP `127.0.0.1:18082` (`MACPLAY_WEB_AUDIO_PORT`) to Node,
  which relays them as WebSocket binary messages on `/touch`.
- Browser (`webclient.html`): plays them with the Web Audio API (ported from
  wheelplay's `browser-audio.js`, Apache-2.0) — ~300 ms buffering for media,
  ~60 ms for voice. No Opus encoding on the Mac, no `<audio>` streaming lag.
  Mute button top-right; playback starts after the first tap (browser
  autoplay policy).

**The Mac itself stays silent** — local `osxaudiosink` playback is dropped in
web mode; audio goes to the car browser instead.

Touch input also borrows from wheelplay: letterbox-aware coordinate mapping
(`mapPoint`, fixing edge touches when the video is pillarboxed), rAF
coalescing of move events, and finger release on blur/hide/pagehide so
touches never stick.

Env overrides (for debugging):

- `MACPLAY_WEB_PORT` — helper MJPEG port (default `18081`)
- `MACPLAY_WEB_HTTP_PORT` — Node HTTP port (default `8080`)

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `/mjpeg` 503 / curl health fails | Helper built without the patch, or `MACPLAY_WEB_PORT` not in helper env. Check helper stderr for `[webtap]`. |
| Local CarPlay window broken after fork | Should be impossible (fallback), but check helper stderr for `[gst_video]`. `LIVI_GST_DEBUG=1` for pipeline logs. |
| Browser shows page but no video | MJPEG proxy can't reach helper: `curl http://127.0.0.1:18081/mjpeg` on the Mac. |
| Touch does nothing | WS not connected (check devtools console on a desktop browser first), or no active CarPlay session (`active` undefined until video negotiates). |
| `jpegenc` missing | `gst-inspect-1.0 jpegenc` against the bundled GStreamer. The parse fallback keeps the window working; install the good-plugins set for the tap. |
| Choppy video in car browser | Expected at 960w/~15fps MJPEG. Tune `FRAME_INTERVAL` / `videoscale` width / `jpegenc quality` in the patch. |

## Upstream sync

To pull upstream updates: `git fetch upstream; git merge upstream/main`
(or rebase). Conflicts will most likely land in `main.ts` (small) and
`pipeline_desc` (mechanical). The new files (`webtap.rs`, `webserver.ts`,
`webclient.html`) are conflict-free by construction.
