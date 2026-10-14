//! Direct H.264 NAL forwarder (no GStreamer).
//!
//! When `MACPLAY_NO_DECODE` is set (zero-transcode/headless mode), video NAL
//! units from the iPhone are forwarded directly to TCP clients on
//! `MACPLAY_H264_PORT` (default 18083), bypassing GStreamer entirely.
//! The Node webserver connects here and relays to browsers via WebSocket.
//!
//! Protocol: each NAL unit is length-prefixed with a 4-byte big-endian u32,
//! matching the existing h264tap protocol.

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

struct Forwarder {
    clients: Vec<TcpStream>,
}

impl Forwarder {
    fn new() -> Self {
        Self { clients: Vec::new() }
    }

    fn add_client(&mut self, stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        self.clients.push(stream);
    }

    fn broadcast(&mut self, nal: &[u8]) {
        if self.clients.is_empty() || nal.is_empty() {
            return;
        }
        // Fork: ensure Annex B start code (0x00 0x00 0x00 0x01) prefix.
        // The NAL from the iPhone may not have it; browsers need it.
        const START_CODE: [u8; 4] = [0, 0, 0, 1];
        let has_start_code = nal.len() >= 4
            && ((nal[0] == 0 && nal[1] == 0 && nal[2] == 0 && nal[3] == 1)
                || (nal[0] == 0 && nal[1] == 0 && nal[2] == 1));
        let payload: Vec<u8> = if has_start_code {
            nal.to_vec()
        } else {
            let mut v = Vec::with_capacity(4 + nal.len());
            v.extend_from_slice(&START_CODE);
            v.extend_from_slice(nal);
            v
        };
        let len = (payload.len() as u32).to_be_bytes();
        let mut dead = Vec::new();
        for (i, client) in self.clients.iter_mut().enumerate() {
            let ok = client.write_all(&len).is_ok() && client.write_all(&payload).is_ok();
            if !ok {
                dead.push(i);
            }
        }
        // Remove dead clients (in reverse to keep indices valid)
        for i in dead.iter().rev() {
            self.clients.remove(*i);
        }
    }
}

static FORWARDER: OnceLock<Arc<Mutex<Forwarder>>> = OnceLock::new();

fn forwarder() -> Arc<Mutex<Forwarder>> {
    FORWARDER
        .get_or_init(|| Arc::new(Mutex::new(Forwarder::new())))
        .clone()
}

/// Start the direct H.264 TCP server. No-op unless `MACPLAY_NO_DECODE` is set
/// and `MACPLAY_H264_PORT` is configured. Call once at startup.
pub fn maybe_start() {
    // Only in zero-transcode mode (no GStreamer pipeline)
    if std::env::var_os("MACPLAY_NO_DECODE").is_none() {
        return;
    }
    let port: u16 = std::env::var("MACPLAY_H264_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18083);

    let fw = forwarder();
    std::thread::Builder::new()
        .name("h264direct".into())
        .spawn(move || {
            let listener = match TcpListener::bind(("127.0.0.1", port)) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("[h264direct] bind 127.0.0.1:{port} failed: {e}");
                    return;
                }
            };
            eprintln!("[h264direct] listening on 127.0.0.1:{port} (no GStreamer)");
            for stream in listener.incoming() {
                match stream {
                    Ok(s) => {
                        eprintln!("[h264direct] client connected");
                        if let Ok(mut f) = fw.lock() {
                            f.add_client(s);
                        }
                    }
                    Err(e) => {
                        eprintln!("[h264direct] accept error: {e}");
                    }
                }
            }
        })
        .ok();
}

/// Forward a NAL unit to all connected TCP clients. Called from `feed::push_video`.
pub fn push_nal(nal: &[u8]) {
    if std::env::var_os("MACPLAY_NO_DECODE").is_none() {
        return;
    }
    if let Some(fw) = FORWARDER.get() {
        if let Ok(mut f) = fw.lock() {
            f.broadcast(nal);
        }
    }
}
