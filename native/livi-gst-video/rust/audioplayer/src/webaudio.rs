//! Optional web audio tap (fork addition).
//!
//! When the `MACPLAY_WEB_PORT` env var is set, every CarPlay audio pipeline
//! gets a tee branch `... ! appsink name=webaudio` carrying decoded PCM
//! (S16LE, 48 kHz, stereo — see `pipeline_desc` in `lib.rs`). This module
//! forwards each tap's PCM frames to the Node.js webserver over a TCP
//! socket on `127.0.0.1:$MACPLAY_WEB_AUDIO_PORT` (default 18082), which
//! relays them to the car browser over WebSocket.
//!
//! Frame format (borrowed from wheelplay's browser-audio protocol so the
//! browser client can be shared):
//!   u32 BE length N, then N bytes:
//!     u32 LE magic 0x31415057 ("WAP1"), i32 LE stream id, u32 LE rate,
//!     u16 LE channels, u16 LE flags (bit 0 = media stream), u32 LE sequence,
//!     Int16LE PCM samples (interleaved).
//!
//! The browser plays them with the Web Audio API (see webclient.html):
//! no Opus encoding on the Mac, ~300 ms media / ~60 ms voice latency.
//! Hand-rolled TCP: no new crates, std only.

use std::io::Write;
use std::net::TcpListener;
use std::sync::{
    atomic::{AtomicU32, Ordering},
    mpsc, Arc, Mutex, OnceLock,
};

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;

/// Magic from wheelplay's browser-audio protocol ("WAP1", little-endian).
const MAGIC: u32 = 0x31415057;
/// PCM format every tap produces (matches `pipeline_desc`).
const RATE: u32 = 48_000;
const CHANNELS: u16 = 2;
const HEADER_LEN: usize = 20;
/// Coalesce target: the pipeline emits small irregular chunks (~7 ms); WebKit
/// crackles when the browser schedules hundreds of tiny AudioBuffers per
/// second. Flush whole 20 ms blocks and keep the remainder buffered.
const TARGET_FRAME_BYTES: usize = 48_000 * 2 * 2 / 50;

static NEXT_ID: AtomicU32 = AtomicU32::new(1);

/// Sequence counters per tap (for the browser's ack / gap logic).
static SEQS: OnceLock<Mutex<std::collections::HashMap<u32, u32>>> = OnceLock::new();

fn seqs() -> &'static Mutex<std::collections::HashMap<u32, u32>> {
    SEQS.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

type ClientTx = mpsc::SyncSender<Vec<u8>>;

static CLIENTS: OnceLock<Arc<Mutex<Vec<ClientTx>>>> = OnceLock::new();

fn clients() -> &'static Arc<Mutex<Vec<ClientTx>>> {
    CLIENTS.get_or_init(|| Arc::new(Mutex::new(Vec::new())))
}

static SERVER_ONCE: OnceLock<()> = OnceLock::new();

fn audio_port() -> u16 {
    std::env::var("MACPLAY_WEB_AUDIO_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(18082)
}

/// Start the TCP relay server once. The Node webserver connects here and
/// forwards length-prefixed frames to browsers as WebSocket binary messages.
fn ensure_server() {
    SERVER_ONCE.get_or_init(|| {
        let port = audio_port();
        let _ = std::thread::Builder::new()
            .name("webaudio-tcp".into())
            .spawn(move || {
                let listener = match TcpListener::bind(("127.0.0.1", port)) {
                    Ok(l) => l,
                    Err(e) => {
                        eprintln!("[webaudio] cannot bind 127.0.0.1:{port}: {e}");
                        return;
                    }
                };
                eprintln!("[webaudio] PCM relay on 127.0.0.1:{port}");
                for stream in listener.incoming() {
                    let Ok(mut s) = stream else { continue };
                    // One channel per TCP client (the Node relay). Bounded;
                    // a slow relay drops frames rather than stalling taps.
                    let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(256);
                    if let Ok(mut c) = clients().lock() {
                        c.push(tx);
                    }
                    std::thread::spawn(move || {
                        for frame in rx {
                            let len = (frame.len() as u32).to_be_bytes();
                            if s.write_all(&len).is_err() || s.write_all(&frame).is_err() {
                                break;
                            }
                        }
                        // rx dropped here; broadcast retain() prunes us.
                    });
                }
            });
    });
}

fn broadcast(frame: Vec<u8>) {
    if let Ok(mut c) = clients().lock() {
        c.retain(|tx| match tx.try_send(frame.clone()) {
            Ok(()) => true,
            Err(mpsc::TrySendError::Disconnected(_)) => false,
            // Slow relay: drop the frame, keep the client.
            Err(mpsc::TrySendError::Full(_)) => true,
        });
    }
}

/// Attach to the pipeline's `webaudio` appsink. Returns the tap id for
/// `unregister`. No-op (None) unless web streaming is enabled and the appsink
/// exists. `media` should be true for the buffered media stream (audioType 3).
pub fn maybe_register(pipeline: &gst::Pipeline, media: bool) -> Option<u32> {
    if std::env::var_os("MACPLAY_WEB_PORT").is_none() {
        return None;
    }
    // Fork: start the browser mic input server (micinput.rs) when web mode is on.
    crate::micinput::start_mic_server();
    let appsink = pipeline
        .by_name("webaudio")
        .and_then(|e| e.downcast::<gst_app::AppSink>().ok())?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut s) = seqs().lock() {
        s.insert(id, 0);
    }
    ensure_server();
    let flags: u16 = if media { 1 } else { 0 };
    // Per-tap coalescing buffer (owned by the appsink callback, FnMut).
    let mut pending: Vec<u8> = Vec::with_capacity(TARGET_FRAME_BYTES * 2);
    appsink.set_callbacks(
        gst_app::AppSinkCallbacks::builder()
            .new_sample(move |sink| {
                let pcm: Vec<u8> = sink
                    .pull_sample()
                    .map_err(|_| gst::FlowError::Error)?
                    .buffer()
                    .and_then(|b| b.map_readable().ok().map(|m| m.to_vec()))
                    .unwrap_or_default();
                if pcm.is_empty() {
                    return Ok(gst::FlowSuccess::Ok);
                }
                pending.extend_from_slice(&pcm);
                // Flush whole 20 ms blocks; the remainder rides along with the
                // next chunk. A sub-block tail is dropped on unregister (stream end).
                if pending.len() < TARGET_FRAME_BYTES {
                    return Ok(gst::FlowSuccess::Ok);
                }
                let flush_len = pending.len() - pending.len() % TARGET_FRAME_BYTES;
                let pcm: Vec<u8> = pending.drain(..flush_len).collect();
                let seq = if let Ok(mut s) = seqs().lock() {
                    let e = s.entry(id).or_insert(0);
                    *e = e.wrapping_add(1);
                    *e
                } else {
                    0
                };
                let mut frame = Vec::with_capacity(HEADER_LEN + pcm.len());
                frame.extend_from_slice(&MAGIC.to_le_bytes());
                frame.extend_from_slice(&(id as i32).to_le_bytes());
                frame.extend_from_slice(&RATE.to_le_bytes());
                frame.extend_from_slice(&CHANNELS.to_le_bytes());
                frame.extend_from_slice(&flags.to_le_bytes());
                frame.extend_from_slice(&seq.to_le_bytes());
                frame.extend_from_slice(&pcm);
                broadcast(frame);
                Ok(gst::FlowSuccess::Ok)
            })
            .build(),
    );
    eprintln!("[webaudio] tap {id} registered (media={media})");
    Some(id)
}

/// Drop a tap when its audio pipeline stops.
pub fn unregister(id: u32) {
    if let Ok(mut s) = seqs().lock() {
        s.remove(&id);
    }
}
