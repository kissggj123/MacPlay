//! Optional web streaming tap (fork addition).
//!
//! When the `MACPLAY_WEB_PORT` env var is set, the video pipeline gets a tee
//! branch `... ! jpegenc ! appsink name=websink` (see
//! `livi_video_codec::pipeline_desc`). This module pulls JPEG frames from that
//! appsink and serves them as MJPEG over HTTP on `127.0.0.1:$MACPLAY_WEB_PORT`:
//!
//!   GET /mjpeg   multipart/x-mixed-replace JPEG stream (~15 fps)
//!   GET /health  {"video":"live"} readiness probe
//!
//! The Node.js side (`native/Engine/webserver.ts`) proxies `/mjpeg` to the LAN
//! and serves the touch-enabled browser client. Hand-rolled HTTP/1.0: no new
//! crates, std only.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gstreamer::prelude::*;

const BOUNDARY: &str = "macplaymjpeg";
const FRAME_INTERVAL: Duration = Duration::from_millis(66); // ~15 fps is plenty for a car browser
const IDLE_POLL: Duration = Duration::from_millis(200);

// Fork: lazy MJPEG. The branch `valve ! videoconvert ! videoscale ! avenc_mjpeg
// ! appsink` is pure software work (NV12->RGB convert + scale + JPEG encode at
// up to 60 fps) that ran at full speed even when nobody was watching the
// 8080/MJPEG route — a constant ~half a core on the receiver while the browser
// streamed over WebCodecs/WebRTC. The valve starts closed (drop=true), so the
// leaky queue ahead of it discards frames and the whole branch starves; it
// opens only while an HTTP client is actually streaming /mjpeg.
static MJPEG_VALVE: Mutex<Option<gstreamer::Element>> = Mutex::new(None);

fn set_valve_open(open: bool) {
    let valve = MJPEG_VALVE.lock().unwrap().clone();
    if let Some(v) = valve {
        v.set_property("drop", !open);
        eprintln!(
            "[webtap] MJPEG valve {}",
            if open { "open (viewer connected)" } else { "closed (idle)" }
        );
    }
}

/// RAII guard: one /mjpeg stream client. Opens the valve on first viewer,
/// closes it when the last one walks away (including on early returns).
static VIEWERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
struct ViewerGuard;
impl ViewerGuard {
    fn acquire() -> Self {
        if VIEWERS.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
            set_valve_open(true);
        }
        ViewerGuard
    }
}
impl Drop for ViewerGuard {
    fn drop(&mut self) {
        if VIEWERS.fetch_sub(1, std::sync::atomic::Ordering::SeqCst) == 1 {
            set_valve_open(false);
        }
    }
}

/// The configured web-tap port, if enabled.
pub fn web_port() -> Option<u16> {
    std::env::var("MACPLAY_WEB_PORT").ok()?.parse().ok()
}

/// Attach to the pipeline's `websink` appsink and start serving. No-op unless
/// `MACPLAY_WEB_PORT` is set and the appsink exists (e.g. the pipeline fell
/// back to the plain description).
pub fn maybe_start(pipeline: &gstreamer::Pipeline) {
    let port = match web_port() {
        Some(p) => p,
        None => return,
    };
    let appsink: gstreamer_app::AppSink = match pipeline
        .by_name("websink")
        .and_then(|e| e.downcast::<gstreamer_app::AppSink>().ok())
    {
        Some(s) => s,
        None => {
            eprintln!("[webtap] websink not in pipeline, web streaming disabled");
            return;
        }
    };
    // Fork: lazy branch control (see ViewerGuard). Absent when the pipeline
    // fell back to the no-MJPEG description — then this is a no-op.
    if let Some(v) = pipeline.by_name("mjpegvalve") {
        *MJPEG_VALVE.lock().unwrap() = Some(v);
    }

    let latest: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));

    // Frame pull thread: blocking pull with timeout keeps the appsink drained.
    {
        let latest = latest.clone();
        let _ = std::thread::Builder::new()
            .name("webtap-pull".into())
            .spawn(move || {
                // emit-signals=false is already set on the appsink element in
                // the pipeline description; pull mode needs no signals.
                loop {
                    match appsink.try_pull_sample(gstreamer::ClockTime::from_seconds(2)) {
                        Some(sample) => {
                            // No viewer: the valve is closed so samples stop
                            // arriving anyway, but between a viewer connecting
                            // and frames re-flowing this skips the map cost.
                            if VIEWERS.load(std::sync::atomic::Ordering::SeqCst) == 0 {
                                continue;
                            }
                            let jpeg = sample
                                .buffer()
                                .and_then(|b| b.map_readable().ok().map(|m| m.to_vec()))
                                .unwrap_or_default();
                            if !jpeg.is_empty() {
                                *latest.lock().unwrap() = jpeg;
                            }
                        }
                        // Timeout: pipeline idle (no CarPlay session yet). Keep
                        // serving the last frame; do not spin.
                        None => std::thread::sleep(IDLE_POLL),
                    }
                }
            });
    }

    // HTTP server thread.
    let _ = std::thread::Builder::new()
        .name("webtap-http".into())
        .spawn(move || serve(port, latest));
    eprintln!("[webtap] MJPEG ready on 127.0.0.1:{port}/mjpeg");
}

fn serve(port: u16, latest: Arc<Mutex<Vec<u8>>>) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[webtap] cannot bind 127.0.0.1:{port}: {e}");
            return;
        }
    };
    for stream in listener.incoming() {
        let Ok(s) = stream else { continue };
        let latest = latest.clone();
        std::thread::spawn(move || handle_client(s, &latest));
    }
}

fn handle_client(mut s: std::net::TcpStream, latest: &Arc<Mutex<Vec<u8>>>) {
    let mut head = [0u8; 1024];
    // Best effort: we serve the same MJPEG regardless of path, except /health.
    let _ = s.read(&mut head);
    if head.starts_with(b"GET /health") {
        let body = br#"{"video":"live"}"#;
        let _ = write!(
            s,
            "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = s.write_all(body);
        return;
    }
    let resp = format!(
        "HTTP/1.0 200 OK\r\n\
         Content-Type: multipart/x-mixed-replace; boundary={BOUNDARY}\r\n\
         Cache-Control: no-cache, no-store\r\n\
         Pragma: no-cache\r\n\
         Connection: close\r\n\r\n"
    );
    if s.write_all(resp.as_bytes()).is_err() {
        return;
    }
    let _ = s.set_write_timeout(Some(Duration::from_secs(10)));
    // Fork: streaming has begun — keep the MJPEG branch fed until we return.
    let _viewer = ViewerGuard::acquire();
    loop {
        let jpeg = latest.lock().unwrap().clone();
        if jpeg.is_empty() {
            std::thread::sleep(IDLE_POLL);
            continue;
        }
        let part = format!(
            "--{BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
            jpeg.len()
        );
        if s.write_all(part.as_bytes()).is_err()
            || s.write_all(&jpeg).is_err()
            || s.write_all(b"\r\n").is_err()
        {
            break; // client went away
        }
        std::thread::sleep(FRAME_INTERVAL);
    }
}
