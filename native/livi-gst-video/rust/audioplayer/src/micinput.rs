//! Browser microphone input (fork addition).
//!
//! When the car browser enables its microphone, PCM frames (16kHz mono S16LE)
//! arrive via WebSocket -> Node.js webserver -> TCP on
//! `127.0.0.1:$MACPLAY_MIC_PORT` (default 18083). This module listens on that
//! port and feeds the PCM into a GStreamer appsrc, which replaces osxaudiosrc
//! in the uplink pipeline when browser mic is active.
//!
//! Frame format (same wheelplay header as webaudio.rs, stream=-1 for mic):
//!   u32 BE length N, then N bytes:
//!     u32 LE magic 0x31415057, i32 LE stream (-1), u32 LE rate,
//!     u16 LE channels, u16 LE flags, u32 LE sequence,
//!     Int16LE PCM samples.

use std::io::Read;
use std::net::TcpListener;
use std::sync::{mpsc, Mutex, OnceLock};

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;

const MAGIC: u32 = 0x31415057;
const MIC_STREAM: i32 = -1;

fn mic_port() -> u16 {
    std::env::var("MACPLAY_MIC_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18084)
}

type PcmTx = mpsc::SyncSender<Vec<u8>>;

static PCM_TX: OnceLock<Mutex<Option<PcmTx>>> = OnceLock::new();
static SERVER_ONCE: OnceLock<()> = OnceLock::new();

fn set_tx(tx: PcmTx) {
    let mut guard = PCM_TX.get_or_init(|| Mutex::new(None)).lock().unwrap();
    *guard = Some(tx);
}

fn get_tx() -> Option<PcmTx> {
    PCM_TX.get()?.lock().unwrap().clone()
}

/// Start the TCP listener for browser mic PCM. Call once at startup.
pub fn start_mic_server() {
    SERVER_ONCE.get_or_init(|| {
        let port = mic_port();
        std::thread::spawn(move || {
            let listener = match TcpListener::bind(("127.0.0.1", port)) {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("[mic] bind 127.0.0.1:{port} failed: {e}");
                    return;
                }
            };
            eprintln!("[mic] listening on 127.0.0.1:{port} for browser mic PCM");
            for stream in listener.incoming() {
                let mut stream = match stream {
                    Ok(s) => s,
                    Err(_) => continue,
                };
                std::thread::spawn(move || {
                    let mut buf = vec![0u8; 4];
                    loop {
                        if stream.read_exact(&mut buf).is_err() { break; }
                        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
                        if len > 1024 * 1024 || len < 20 { break; }
                        let mut frame = vec![0u8; len];
                        if stream.read_exact(&mut frame).is_err() { break; }
                        // Validate header
                        if frame.len() < 20 { continue; }
                        let magic = u32::from_le_bytes([frame[0], frame[1], frame[2], frame[3]]);
                        let stream_id = i32::from_le_bytes([frame[4], frame[5], frame[6], frame[7]]);
                        if magic != MAGIC || stream_id != MIC_STREAM { continue; }
                        // PCM data starts at byte 20
                        if let Some(tx) = get_tx() {
                            let _ = tx.try_send(frame[20..].to_vec());
                        }
                    }
                });
            }
        });
    });
}

/// Create an appsrc that emits browser mic PCM (16kHz mono S16LE).
/// Use this instead of osxaudiosrc when browser mic is active.
pub fn browser_mic_src() -> Option<gst::Element> {
    let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(32);
    set_tx(tx);

    let src = gst::ElementFactory::make("appsrc")
        .name("browser-mic-src")
        .build()
        .ok()?;
    src.set_property("format", gst::Format::Time);
    src.set_property("is-live", true);

    let caps = gst::Caps::builder("audio/x-raw")
        .field("format", "S16LE")
        .field("layout", "interleaved")
        .field("rate", 16000i32)
        .field("channels", 1i32)
        .build();
    src.set_property("caps", &caps);

    let appsrc = src.clone().downcast::<gst_app::AppSrc>().ok()?;
    std::thread::spawn(move || {
        let mut pts: u64 = 0;
        // 16kHz mono S16LE: 32000 bytes/sec
        while let Ok(pcm) = rx.recv() {
            let mut buffer = gst::Buffer::from_mut_slice(pcm);
            {
                let buf_mut = buffer.get_mut().unwrap();
                let duration = (buf_mut.size() as u64) * 1_000_000_000 / 32000;
                buf_mut.set_pts(gst::ClockTime::from_nseconds(pts));
                buf_mut.set_duration(gst::ClockTime::from_nseconds(duration));
                pts += duration;
            }
            if appsrc.push_buffer(buffer).is_err() {
                break;
            }
        }
    });

    Some(src.upcast())
}
