//! A CarPlay audio stream received in this process: livi-audio-stream receives, frames and
//! decrypts it, livi-audio-player plays it, the feed registry addresses it.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool,AtomicU64,Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use livi_audio_player::{Config as AudioConfig, Player as AudioPlayer};
use livi_audio_stream::receiver::AudioReceiver;
use livi_audio_stream::{AudioSink, AudioStream};

use crate::feed::{self, AudioOut};

/// Reports the stream's first sample, which the caller answers the phone's SETUP with.
pub type StartedCb = Box<dyn Fn(u32, u32) + Send + 'static>;

struct Sink {
    out: Arc<AudioOut>,
    retired: Arc<AtomicBool>,
    forwarded: Arc<AtomicU64>,
    rejected: Arc<AtomicU64>,
    on_started: StartedCb,
}

impl AudioSink for Sink {
    fn on_started(&mut self, first_sample: u32) {
        if self.retired.load(Ordering::Acquire){return}
        (self.on_started)(self.out.id, first_sample);
    }

    fn on_rtp(&mut self, rtp: &[u8], _sample: u32) {
        if self.retired.load(Ordering::Acquire){return}
        crate::AUDIO_ACTIVITY.fetch_add(1, Ordering::Relaxed);
        if self.out.active.load(Ordering::Relaxed) {
            if self.out.player.push_rtp(rtp){self.forwarded.fetch_add(1,Ordering::Relaxed);}else{self.rejected.fetch_add(1,Ordering::Relaxed);}
        }
    }
}

/// Only the ports belong here; everything about the stream itself lives in the feed registry.
struct Ear {
    _receiver: AudioReceiver,
    stats: Arc<livi_audio_stream::ReceiveStats>,
    retired: Arc<AtomicBool>,
    forwarded: Arc<AtomicU64>,
    rejected: Arc<AtomicU64>,
}
static EARS: OnceLock<Mutex<HashMap<u32, Ear>>> = OnceLock::new();

fn ears() -> &'static Mutex<HashMap<u32, Ear>> {
    EARS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Builds the pipeline for this stream and binds its two ports. Returns the id the caller
/// addresses it by, plus the data and control port for the SETUP reply.
pub fn open(cfg: &AudioConfig, key: [u8; 32], on_started: StartedCb) -> Option<(u32, u16, u16)> {
    let player = AudioPlayer::new(cfg)?;
    player.start();
    let out = feed::register_audio(player);

    let retired=Arc::new(AtomicBool::new(false));
    let forwarded=Arc::new(AtomicU64::new(0));
    let rejected=Arc::new(AtomicU64::new(0));
    let stream = AudioStream::new(key, Box::new(Sink { out: out.clone(), on_started,retired:retired.clone(),forwarded:forwarded.clone(),rejected:rejected.clone() }));
    let stats=stream.stats();
    let (recv, data_port, control_port) = match AudioReceiver::new(stream) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[cp_audio] cannot listen: {e}");
            out.player.stop();
            feed::unregister_audio(out.id);
            return None;
        }
    };
    ears().lock().unwrap_or_else(|e| e.into_inner()).insert(out.id, Ear{_receiver:recv,stats,retired,forwarded,rejected});
    eprintln!("[cp_audio] stream 0x{:x} open ({:?})", out.id, cfg.codec);
    eprintln!("[cp_audio] id={} rate={} channels={} dataPort={} controlPort={} latencyMs={}",out.id,cfg.clock_rate,cfg.channels,data_port,control_port,cfg.latency_ms);
    Some((out.id, data_port, control_port))
}

pub fn set_active(id: u32, on: bool) {
    if let Some(out) = feed::audio_out(id) {
        out.active.store(on, Ordering::Relaxed);
    }
}

pub fn set_volume(id: u32, level: f64, ramp_ms: u32) {
    if let Some(out) = feed::audio_out(id) {
        out.player.set_volume(level, u64::from(ramp_ms));
    }
}

pub fn close(id: u32) {
    eprintln!("[cp_audio] stream 0x{id:x} close");
    let ear=ears().lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    if let Some(ear)=ear {ear.retired.store(true,Ordering::Release);drop(ear);}
    if let Some(out) = feed::audio_out(id) {
        out.player.stop();
    }
    feed::unregister_audio(id);
}

pub fn statistics() -> String {
    let ears=ears().lock().unwrap_or_else(|e|e.into_inner());
    let rows:Vec<String>=ears.iter().map(|(id,ear)|{
        let s=&ear.stats;
        let (decoded,errors)=feed::audio_out(*id).map(|o|o.player.statistics()).unwrap_or_default();
        format!("{{\"id\":{id},\"packets\":{},\"bytes\":{},\"decrypted\":{},\"invalid\":{},\"authenticationErrors\":{},\"forwarded\":{},\"rejected\":{},\"decodedBuffers\":{decoded},\"pipelineErrors\":{errors},\"silenceMs\":{},\"seqGaps\":{},\"seqDups\":{},\"seqReorders\":{}}}",
            s.packets.load(Ordering::Relaxed),s.bytes.load(Ordering::Relaxed),s.decrypted.load(Ordering::Relaxed),s.invalid.load(Ordering::Relaxed),s.authentication_errors.load(Ordering::Relaxed),ear.forwarded.load(Ordering::Relaxed),ear.rejected.load(Ordering::Relaxed),s.silence_ms().map(|v|v.to_string()).unwrap_or("null".into()),s.seq_gaps.load(Ordering::Relaxed),s.seq_dups.load(Ordering::Relaxed),s.seq_reorders.load(Ordering::Relaxed))
    }).collect();
    format!("[{}]",rows.join(","))
}
