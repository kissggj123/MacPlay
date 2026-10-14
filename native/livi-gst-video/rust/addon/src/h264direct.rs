//! Direct H.264 NAL forwarder (no GStreamer).
//!
//! When `MACPLAY_NO_DECODE` is set (zero-transcode/headless mode), video NAL
//! units from the iPhone are forwarded directly to TCP clients on
//! `MACPLAY_H264_PORT` (default 18083), bypassing GStreamer entirely.
//! The Node webserver connects here and relays to browsers via WebSocket.
//!
//! Protocol: each NAL unit is length-prefixed with a 4-byte big-endian u32,
//! matching the existing h264tap protocol. NAL units use Annex B start codes.

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const START_CODE: [u8; 4] = [0, 0, 0, 1];

struct Forwarder {
    clients: Vec<TcpStream>,
    /// Cached SPS/PPS as Annex B NAL units, sent to each new client first.
    codec_config: Vec<Vec<u8>>,
}

impl Forwarder {
    fn new() -> Self {
        Self { clients: Vec::new(), codec_config: Vec::new() }
    }

    fn set_codec_config(&mut self, sps_pps: Vec<Vec<u8>>) {
        self.codec_config = sps_pps;
    }

    fn send_nal(client: &mut TcpStream, nal: &[u8]) -> bool {
        let len = (nal.len() as u32).to_be_bytes();
        client.write_all(&len).is_ok() && client.write_all(nal).is_ok()
    }

    fn add_client(&mut self, mut stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        // Send cached SPS/PPS first so the browser can configure its decoder
        for nal in &self.codec_config {
            if !Self::send_nal(&mut stream, nal) {
                return; // client died, don't add
            }
        }
        eprintln!("[h264direct] client connected (sent {} config NALs)", self.codec_config.len());
        self.clients.push(stream);
    }

    fn broadcast(&mut self, nal: &[u8]) {
        if self.clients.is_empty() || nal.is_empty() {
            return;
        }
        // Ensure Annex B start code prefix
        let payload: Vec<u8> = if has_start_code(nal) {
            nal.to_vec()
        } else {
            let mut v = Vec::with_capacity(4 + nal.len());
            v.extend_from_slice(&START_CODE);
            v.extend_from_slice(nal);
            v
        };
        let mut dead = Vec::new();
        for (i, client) in self.clients.iter_mut().enumerate() {
            if !Self::send_nal(client, &payload) {
                dead.push(i);
            }
        }
        for i in dead.iter().rev() {
            self.clients.remove(*i);
        }
    }
}

fn has_start_code(nal: &[u8]) -> bool {
    nal.len() >= 3
        && nal[0] == 0 && nal[1] == 0
        && (nal[2] == 1 || (nal.len() >= 4 && nal[2] == 0 && nal[3] == 1))
}

static FORWARDER: OnceLock<Arc<Mutex<Forwarder>>> = OnceLock::new();

fn forwarder() -> Arc<Mutex<Forwarder>> {
    FORWARDER
        .get_or_init(|| Arc::new(Mutex::new(Forwarder::new())))
        .clone()
}

/// Parse avcC atom and extract SPS/PPS as Annex B NAL units.
fn parse_avcc(atom: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    // avcC: [1][profile][compat][level][lenSize-1][numSPS][spsLen(2)][sps]...[numPPS][ppsLen(2)][pps]...
    if atom.len() < 7 || atom[0] != 1 {
        return out;
    }
    let mut pos = 5;
    let num_sps = (atom[pos] & 0x1F) as usize;
    pos += 1;
    for _ in 0..num_sps {
        if pos + 2 > atom.len() { break; }
        let len = ((atom[pos] as usize) << 8) | atom[pos + 1] as usize;
        pos += 2;
        if pos + len > atom.len() { break; }
        let mut nal = Vec::with_capacity(4 + len);
        nal.extend_from_slice(&START_CODE);
        nal.extend_from_slice(&atom[pos..pos + len]);
        out.push(nal);
        pos += len;
    }
    if pos >= atom.len() { return out; }
    let num_pps = atom[pos] as usize;
    pos += 1;
    for _ in 0..num_pps {
        if pos + 2 > atom.len() { break; }
        let len = ((atom[pos] as usize) << 8) | atom[pos + 1] as usize;
        pos += 2;
        if pos + len > atom.len() { break; }
        let mut nal = Vec::with_capacity(4 + len);
        nal.extend_from_slice(&START_CODE);
        nal.extend_from_slice(&atom[pos..pos + len]);
        out.push(nal);
        pos += len;
    }
    out
}

/// Cache SPS/PPS from the avcC codec atom. Called when the iPhone sends
/// its video configuration. New TCP clients receive these first.
pub fn set_codec_data(atom: &[u8]) {
    if std::env::var_os("MACPLAY_NO_DECODE").is_none() {
        return;
    }
    let sps_pps = parse_avcc(atom);
    if sps_pps.is_empty() {
        return;
    }
    eprintln!("[h264direct] cached {} SPS/PPS NALs from avcC", sps_pps.len());
    let fw = forwarder();
    if let Ok(mut f) = fw.lock() {
        f.set_codec_config(sps_pps);
    }
}

/// Start the direct H.264 TCP server. No-op unless `MACPLAY_NO_DECODE` is set.
/// Call once at startup.
pub fn maybe_start() {
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
