//! Direct video NAL forwarder (no GStreamer).
//!
//! When `MACPLAY_NO_DECODE` is set (zero-transcode/headless mode), video NAL
//! units from the iPhone are forwarded directly to TCP clients on
//! `MACPLAY_H264_PORT` (default 18083), bypassing GStreamer entirely.
//! The Node webserver connects here and relays to browsers via WebSocket.
//!
//! Supports both H.264 (AVC) and H.265 (HEVC). The codec is determined from
//! the configuration atom (avcC or hvcC) sent by the iPhone.
//!
//! Protocol: each NAL unit is length-prefixed with a 4-byte big-endian u32,
//! matching the existing h264tap protocol. NAL units use Annex B start codes.

use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const START_CODE: [u8; 4] = [0, 0, 0, 1];

/// Video codec in use
#[derive(Clone, Copy, PartialEq)]
pub enum VideoCodec {
    H264,
    H265,
}

struct Forwarder {
    clients: Vec<TcpStream>,
    /// Cached VPS/SPS/PPS as Annex B NAL units, sent to each new client first.
    codec_config: Vec<Vec<u8>>,
    codec: VideoCodec,
}

impl Forwarder {
    fn new() -> Self {
        Self { clients: Vec::new(), codec_config: Vec::new(), codec: VideoCodec::H264 }
    }

    fn set_codec_config(&mut self, config: Vec<Vec<u8>>, codec: VideoCodec) {
        self.codec_config = config;
        self.codec = codec;
    }

    fn send_nal(client: &mut TcpStream, nal: &[u8]) -> bool {
        let len = (nal.len() as u32).to_be_bytes();
        client.write_all(&len).is_ok() && client.write_all(nal).is_ok()
    }

    fn add_client(&mut self, mut stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
        // Send cached VPS/SPS/PPS first so the browser can configure its decoder.
        // Prepend a codec identifier: first message is 4-byte length + 1-byte codec
        // (0=H.264, 1=H.265), followed by config NALs.
        let codec_byte = match self.codec {
            VideoCodec::H264 => 0u8,
            VideoCodec::H265 => 1u8,
        };
        if !Self::send_nal(&mut stream, &[codec_byte]) {
            return;
        }
        for nal in &self.codec_config {
            if !Self::send_nal(&mut stream, nal) {
                return; // client died, don't add
            }
        }
        eprintln!("[h264direct] client connected (codec={:?}, sent {} config NALs)",
            match self.codec { VideoCodec::H264 => "h264", VideoCodec::H265 => "h265" },
            self.codec_config.len());
        self.clients.push(stream);
    }

    fn broadcast(&mut self, nal: &[u8]) {
        if self.clients.is_empty() || nal.is_empty() {
            return;
        }
        // The NAL from iPhone may be length-prefixed (4-byte BE length).
        // Strip it if present, then ensure Annex B start code.
        let raw_nal: &[u8] = if nal.len() > 4 && !has_start_code(nal) {
            let len = u32::from_be_bytes([nal[0], nal[1], nal[2], nal[3]]) as usize;
            if len == nal.len() - 4 {
                &nal[4..]
            } else {
                nal
            }
        } else {
            nal
        };
        let payload: Vec<u8> = if has_start_code(raw_nal) {
            raw_nal.to_vec()
        } else {
            let mut v = Vec::with_capacity(4 + raw_nal.len());
            v.extend_from_slice(&START_CODE);
            v.extend_from_slice(raw_nal);
            v
        };
        let len_bytes = (payload.len() as u32).to_be_bytes();
        self.clients.retain_mut(|client| {
            client.write_all(&len_bytes).is_ok() && client.write_all(&payload).is_ok()
        });
    }
}

fn has_start_code(nal: &[u8]) -> bool {
    nal.len() >= 3 && nal[0] == 0 && nal[1] == 0 &&
        (nal[2] == 1 || (nal.len() >= 4 && nal[2] == 0 && nal[3] == 1))
}

/// Parse avcC atom and extract SPS/PPS as Annex B NAL units.
fn parse_avcc(atom: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
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

/// Parse hvcC atom and extract VPS/SPS/PPS as Annex B NAL units.
fn parse_hvcc(atom: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    // hvcC: [0]=1, [1]=profile_space/tier/profile, [2..5]=compat_flags,
    // [6..11]=constraint_flags, [12]=level, [13..14]=min_spatial_seg,
    // [15]=parallelism, [16]=chroma, [17]=bitdepth_luma, [18]=bitdepth_chroma,
    // [19..20]=avgFrameRate, [21]=constFramerate/numLayers/nested/lengthSize,
    // [22]=numOfArrays, then arrays.
    if atom.len() < 23 || atom[0] != 1 {
        return out;
    }
    let num_arrays = atom[22] as usize;
    let mut pos = 23;
    for _ in 0..num_arrays {
        if pos + 3 > atom.len() { break; }
        // let nal_type = atom[pos] & 0x3F; // not needed, just extract all
        let num_nalus = ((atom[pos + 1] as usize) << 8) | atom[pos + 2] as usize;
        pos += 3;
        for _ in 0..num_nalus {
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
    }
    out
}

static FORWARDER: OnceLock<Arc<Mutex<Forwarder>>> = OnceLock::new();

fn forwarder() -> Arc<Mutex<Forwarder>> {
    FORWARDER.get_or_init(|| Arc::new(Mutex::new(Forwarder::new()))).clone()
}

/// Cache VPS/SPS/PPS from the codec atom. Called when the iPhone sends
/// its video configuration. New TCP clients receive these first.
/// `is_hevc`: true for H.265 (hvcC), false for H.264 (avcC).
pub fn set_codec_data(atom: &[u8], is_hevc: bool) {
    let (config, codec) = if is_hevc {
        (parse_hvcc(atom), VideoCodec::H265)
    } else {
        (parse_avcc(atom), VideoCodec::H264)
    };
    if config.is_empty() {
        return;
    }
    if std::env::var_os("MACPLAY_NO_DECODE").is_some() {
        eprintln!("[h264direct] cached {} config NALs from {}",
            config.len(), if is_hevc { "hvcC" } else { "avcC" });
        if let Ok(mut f) = forwarder().lock() {
            f.set_codec_config(config, codec);
        }
    } else {
        // Decode mode: the encoded-passthrough tap (WebCodecs route) also
        // needs the config NALs — the iPhone keeps VPS/SPS/PPS in hvcC and
        // never sends them in-band, so the parser stream alone can't configure
        // a browser decoder.
        livi_video_player::h264tap::stash_config(config);
    }
}

/// Push a video NAL unit to all connected TCP clients.
pub fn push_video_nal(nal: &[u8]) {
    if std::env::var_os("MACPLAY_NO_DECODE").is_none() {
        return;
    }
    if let Ok(mut f) = forwarder().lock() {
        f.broadcast(nal);
    }
}

/// Start the TCP listener if MACPLAY_NO_DECODE is set. Called once at startup.
pub fn maybe_start() {
    if std::env::var_os("MACPLAY_NO_DECODE").is_none() {
        return;
    }
    let port: u16 = std::env::var("MACPLAY_H264_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18083);
    start_server(port);
}

/// Start the TCP listener. Called once at startup when MACPLAY_NO_DECODE is set.
pub fn start_server(port: u16) {
    let fw = forwarder();
    std::thread::spawn(move || {
        let listener = match TcpListener::bind(("127.0.0.1", port)) {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[h264direct] bind failed on port {}: {}", port, e);
                return;
            }
        };
        eprintln!("[h264direct] listening on 127.0.0.1:{} (no GStreamer)", port);
        for stream in listener.incoming() {
            match stream {
                Ok(s) => {
                    if let Ok(mut f) = fw.lock() {
                        f.add_client(s);
                    }
                }
                Err(e) => {
                    eprintln!("[h264direct] accept error: {}", e);
                    break;
                }
            }
        }
    });
}
