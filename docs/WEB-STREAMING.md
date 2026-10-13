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
| `native/livi-gst-video/rust/codec/src/lib.rs` | `pipeline_desc()`: tee branch (`jpegenc` → `appsink name=websink`) when `MACPLAY_WEB_PORT` set |
| `native/livi-gst-video/rust/player/src/lib.rs` | `mod webtap`; hook in `Player::new`; parse fallback without tap |
| `native/livi-gst-video/rust/player/src/webtap.rs` | **new**: appsink pull → MJPEG HTTP on 127.0.0.1:$PORT |
| `native/Engine/webserver.ts` | **new**: HTTP :8080 + WS `/touch` → `sendTouches()` |
| `native/Engine/webclient.html` | **new**: browser client (copied to `build/engine/`) |
| `native/Engine/main.ts` | import + `MACPLAY_WEB_PORT` env for helper + `startWebServer()` |
| `scripts/build-macplay.sh` | copy `webclient.html` into `build/engine/` |

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
