//! Optional H.264 passthrough tap (fork addition).
//!
//! When the `MACPLAY_H264_PORT` env var is set, the video pipeline gets a tee
//! right after the H.264 parser (before decoding) with an appsink named
//! `h264sink` (see `livi_video_codec::pipeline_desc`). This module pulls raw
//! H.264 NAL units (Annex B byte-stream) from that appsink and serves them
//! length-prefixed over TCP on `127.0.0.1:$MACPLAY_H264_PORT`:
//!
//!   frame = u32 BE length + NAL bytes (one or more NAL units, Annex B)
//!
//! The Node.js side (`native/Engine/webserver.ts`) forwards each frame as a
//! WebSocket binary message on `/h264`. The browser decodes with WebCodecs —
//! zero server-side re-encode, full resolution/framerate. Hand-rolled TCP:
//! no new crates, std only.

use std::io::Write;
use std::net::TcpListener;
use std::sync::mpsc::sync_channel;
use std::time::Duration;

use gstreamer::prelude::*;

/// The configured H.264 tap port, if enabled.
pub fn h264_port() -> Option<u16> {
    std::env::var("MACPLAY_H264_PORT").ok()?.parse().ok()
}

/// Codec config NALs (Annex B, e.g. VPS/SPS/PPS converted from hvcC) to emit
/// before any stream NALs. The iPhone carries these in hvcC (not in-band), so
/// without this the browser never sees them and cannot configure its decoder.
static PENDING_CONFIG: std::sync::Mutex<Vec<Vec<u8>>> = std::sync::Mutex::new(Vec::new());

/// Stash config NALs to be sent ahead of the stream. Safe to call at any
/// time (before or after `maybe_start`).
pub fn stash_config(nals: Vec<Vec<u8>>) {
    if nals.is_empty() {
        return;
    }
    if let Ok(mut q) = PENDING_CONFIG.lock() {
        eprintln!("[h264tap] stashed {} config NAL(s)", nals.len());
        q.extend(nals);
    }
}

/// Attach to the pipeline's `h264sink` appsink and start serving. No-op
/// unless `MACPLAY_H264_PORT` is set and the appsink exists.
pub fn maybe_start(pipeline: &gstreamer::Pipeline) {
    if std::env::var_os("MACPLAY_NO_DECODE").is_some() {
        return;
    }
    let port = match h264_port() {
        Some(p) => p,
        None => return,
    };
    let appsink = match pipeline
        .by_name("h264sink")
        .and_then(|e| e.downcast::<gstreamer_app::AppSink>().ok())
    {
        Some(s) => s,
        None => {
            eprintln!("[h264tap] h264sink not in pipeline, H.264 passthrough disabled");
            return;
        }
    };

    // Bounded channel: latest NAL units, drop old if the forwarder lags.
    let (tx, rx) = sync_channel::<Vec<u8>>(60);

    // Pull thread: blocking pull keeps the appsink drained.
    {
        let _ = std::thread::Builder::new()
            .name("h264tap-pull".into())
            .spawn(move || {
                // emit-signals=false is already set on the appsink element in
                // the pipeline description; pull mode needs no signals.
                loop {
                    // Config NALs first (iPhone keeps VPS/SPS/PPS in hvcC).
                    if let Ok(mut q) = PENDING_CONFIG.lock() {
                        for nal in std::mem::take(&mut *q) {
                            let _ = tx.try_send(nal);
                        }
                    }
                    match appsink.try_pull_sample(gstreamer::ClockTime::from_seconds(2)) {
                        Some(sample) => {
                            let nal = sample
                                .buffer()
                                .and_then(|b| b.map_readable().ok().map(|m| m.to_vec()))
                                .unwrap_or_default();
                            if !nal.is_empty() {
                                // If the forwarder is gone/slow, drop instead of blocking.
                                let _ = tx.try_send(nal);
                            }
                        }
                        None => std::thread::sleep(Duration::from_millis(200)),
                    }
                }
            });
    }

    // TCP server thread.
    let _ = std::thread::Builder::new()
        .name("h264tap-tcp".into())
        .spawn(move || serve(port, rx));
    eprintln!("[h264tap] H.264 passthrough ready on 127.0.0.1:{port}");
}

fn serve(port: u16, rx: std::sync::mpsc::Receiver<Vec<u8>>) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[h264tap] cannot bind 127.0.0.1:{port}: {e}");
            return;
        }
    };
    // Single forwarder (Node.js); extra connections just block on recv.
    for stream in listener.incoming() {
        let Ok(s) = stream else { continue };
        handle_client(s, &rx);
    }
}

fn handle_client(mut s: std::net::TcpStream, rx: &std::sync::mpsc::Receiver<Vec<u8>>) {
    let _ = s.set_write_timeout(Some(Duration::from_secs(10)));
    // Optional one-line handshake: Node sends "HELLO\n", we ignore it.
    loop {
        let nal = match rx.recv() {
            Ok(n) => n,
            Err(_) => break,
        };
        let len = (nal.len() as u32).to_be_bytes();
        if s.write_all(&len).is_err() || s.write_all(&nal).is_err() {
            break; // client went away
        }
    }
}
