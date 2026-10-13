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

const BOUNDARY: &str = "macplaymjpeg";
const FRAME_INTERVAL: Duration = Duration::from_millis(66); // ~15 fps is plenty for a car browser
const IDLE_POLL: Duration = Duration::from_millis(200);

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
    let appsink = match pipeline
        .by_name("websink")
        .and_then(|e| e.downcast::<gstreamer_app::AppSink>().ok())
    {
        Some(s) => s,
        None => {
            eprintln!("[webtap] websink not in pipeline, web streaming disabled");
            return;
        }
    };

    let latest: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));

    // Frame pull thread: blocking pull with timeout keeps the appsink drained.
    {
        let latest = latest.clone();
        let _ = std::thread::Builder::new()
            .name("webtap-pull".into())
            .spawn(move || {
                appsink.set_emit_signals(false);
                loop {
                    match appsink.try_pull_sample(gstreamer::ClockTime::from_seconds(2)) {
                        Some(sample) => {
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
