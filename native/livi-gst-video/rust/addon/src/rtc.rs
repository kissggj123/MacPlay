//! WebRTC direct passthrough (H.264 only, LAN host candidates).
//!
//! The Node side already aggregates the H.264 Annex B NALs from BOTH video
//! sources (h264direct in zero-transcode mode, h264tap in decode mode), so it
//! relays them here over NAPI and this module only RTP-packetizes them:
//!
//!   appsrc (byte-stream/nal, do-timestamp) -> h264parse config-interval=-1
//!     -> rtph264pay config-interval=-1 -> capsfilter (application/x-rtp)
//!     -> webrtcbin (bundle-policy=max-bundle)
//!
//! Signaling is browser-offer-first: the page creates the RTCPeerConnection
//! and sends {t:"offer",sdp} over /rtc; Node calls rtc_set_offer; the answer
//! and local ICE candidates go back through the event callback as JSON:
//! {t:"answer",sdp} | {t:"ice",mline,candidate} | {t:"connected"} | {t:"state",state}.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use gstreamer as gst;
use gstreamer::prelude::*;
use gstreamer_app as gst_app;
use gstreamer_sdp as gst_sdp;
use gstreamer_video as gst_video;
use gst_app::AppSrc;
use gstreamer_webrtc::{WebRTCBundlePolicy, WebRTCPeerConnectionState, WebRTCSDPType, WebRTCSessionDescription};
use napi::threadsafe_function::{ErrorStrategy, ThreadsafeFunction};
use napi::JsFunction;

struct Session {
    pipeline: gst::Pipeline,
    webrtcbin: gst::Element,
    src: AppSrc,
    pay_src: gst::Pad,
    connected: AtomicBool,
    stopped: AtomicBool,
}

static SESSION: OnceLock<Mutex<Option<Arc<Session>>>> = OnceLock::new();
static EVENT_CB: OnceLock<Mutex<Option<ThreadsafeFunction<String, ErrorStrategy::Fatal>>>> = OnceLock::new();

fn session() -> &'static Mutex<Option<Arc<Session>>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

fn emit_event(json: String) {
    if let Some(cb) = EVENT_CB.get().and_then(|c| c.lock().ok().map(|m| m.clone())).flatten() {
        cb.call(json, napi::threadsafe_function::ThreadsafeFunctionCallMode::NonBlocking);
    }
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
        .replace('\n', "\\n").replace('\r', "\\r")
}

fn gst_ready() -> bool {
    // The player pipeline may have initialized GStreamer already; init() is idempotent.
    gst::init().is_ok() && gst::ElementFactory::make("webrtcbin").build().is_ok()
}

pub fn supported() -> bool {
    gst_ready()
}

pub fn start(on_event: JsFunction) -> bool {
    if !gst_ready() {
        eprintln!("[rtc] webrtcbin not available");
        return false;
    }
    stop();
    let tsfn: ThreadsafeFunction<String, ErrorStrategy::Fatal> = on_event
        .create_threadsafe_function(0, |ctx| {
            let value: String = ctx.value;
            let json = ctx.env.create_string(value.as_str())?;
            Ok(vec![json.into_unknown()])
        })
        .expect("rtc event tsfn");
    if let Ok(mut cb) = EVENT_CB.get_or_init(|| Mutex::new(None)).lock() {
        *cb = Some(tsfn);
    }

    let src = AppSrc::builder()
        .caps(&gst::Caps::builder("video/x-h264")
            .field("stream-format", "byte-stream")
            .field("alignment", "nal")
            .build())
        .is_live(true)
        .format(gst::Format::Time)
        .do_timestamp(true)
        .block(false)
        .max_bytes(4 * 1024 * 1024)
        .build();
    let parse = gst::ElementFactory::make("h264parse")
        .property("config-interval", -1i32)
        .build();
    let pay = gst::ElementFactory::make("rtph264pay")
        .property("config-interval", -1i32)
        .build();
    let capsfilter = gst::ElementFactory::make("capsfilter")
        .property("caps", gst::Caps::builder("application/x-rtp")
            .field("media", "video")
            .field("encoding-name", "H264")
            .field("payload", 96i32)
            .field("clock-rate", 90000i32)
            .build())
        .build();
    let webrtcbin = gst::ElementFactory::make("webrtcbin")
        .property("bundle-policy", WebRTCBundlePolicy::MaxBundle)
        .build();
    let (parse, pay, capsfilter, webrtcbin) = match (parse, pay, capsfilter, webrtcbin) {
        (Ok(a), Ok(b), Ok(c), Ok(d)) => (a, b, c, d),
        (err, ..) => {
            eprintln!("[rtc] pipeline elements missing: {err:?}");
            return false;
        }
    };

    let pipeline = gst::Pipeline::new();
    pipeline
        .add_many([&src.upcast_ref::<gst::Element>(), &parse, &pay, &capsfilter, &webrtcbin])
        .expect("rtc add");
    gst::Element::link_many([&src.upcast_ref::<gst::Element>(), &parse, &pay, &capsfilter])
        .expect("rtc link chain");
    let sink_pad = match webrtcbin.request_pad_simple("sink_%u") {
        Some(p) => p,
        None => {
            eprintln!("[rtc] webrtcbin sink pad request failed");
            return false;
        }
    };
    let pay_src = capsfilter.static_pad("src").expect("capsfilter src");
    if pay_src.link(&sink_pad).is_err() {
        eprintln!("[rtc] link capsfilter->webrtcbin failed");
        return false;
    }

    let sess = Arc::new(Session {
        pipeline: pipeline.clone(),
        webrtcbin: webrtcbin.clone(),
        src,
        pay_src,
        connected: AtomicBool::new(false),
        stopped: AtomicBool::new(false),
    });

    // Local ICE candidates -> JS. Generic signal connect: gstreamer-webrtc
    // 0.24 does not ship a typed WebRTCBin wrapper.
    webrtcbin.connect("on-ice-candidate", false, move |values: &[gst::glib::Value]| {
        let mline = values[1].get::<u32>().unwrap_or(0);
        let candidate = values[2].get::<String>().unwrap_or_default();
        emit_event(format!(
            "{{\"t\":\"ice\",\"mline\":{mline},\"candidate\":\"{}\"}}",
            json_escape(&candidate)
        ));
        None
    });
    // Peer connection state -> JS + feed gate.
    let state_sess = sess.clone();
    webrtcbin.connect_notify(Some("connection-state"), move |bin, _pspec| {
        let state = bin.property::<WebRTCPeerConnectionState>("connection-state");
        match state {
            WebRTCPeerConnectionState::Connected => {
                state_sess.connected.store(true, Ordering::Relaxed);
                emit_event("{\"t\":\"connected\"}".into());
            }
            WebRTCPeerConnectionState::Failed | WebRTCPeerConnectionState::Closed => {
                state_sess.connected.store(false, Ordering::Relaxed);
                emit_event(format!("{{\"t\":\"state\",\"state\":\"{}\"}}", json_escape(&format!("{state:?}"))));
            }
            _ => {}
        }
    });
    // Pipeline errors / EOS end the session (no glib MainLoop runs here — poll the bus).
    let bus = pipeline.bus().expect("rtc bus");
    let bus_sess = sess.clone();
    std::thread::spawn(move || loop {
        if bus_sess.stopped.load(Ordering::Relaxed) {
            break;
        }
        match bus.timed_pop_filtered(
            gst::ClockTime::from_mseconds(500),
            &[gst::MessageType::Error, gst::MessageType::Eos],
        ) {
            Some(msg) => {
                let detail = msg.structure().map(|s| s.to_string()).unwrap_or_default();
                eprintln!("[rtc] pipeline ended: {detail}");
                emit_event("{\"t\":\"state\",\"state\":\"ended\"}".into());
                stop();
                break;
            }
            None => continue,
        }
    });

    if let Ok(mut slot) = session().lock() {
        *slot = Some(sess);
    }
    if pipeline.set_state(gst::State::Playing).is_err() {
        eprintln!("[rtc] set_state Playing failed");
        stop();
        return false;
    }
    true
}

pub fn set_offer(sdp: &str) -> bool {
    let Some(sess) = session().lock().ok().and_then(|m| m.clone()) else { return false };
    let sdp_message = match gst_sdp::SDPMessage::parse_buffer(sdp.as_bytes()) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[rtc] bad offer: {e}");
            return false;
        }
    };
    let offer = WebRTCSessionDescription::new(WebRTCSDPType::Offer, sdp_message);
    let wb_for_answer = sess.webrtcbin.clone();
    let wb_for_local = sess.webrtcbin.clone();
    // set-remote-description, then create-answer, then set-local-description;
    // the answer goes back to the page through the event callback.
    let promise = gst::Promise::with_change_func(move |reply| {
        if let Err(e) = reply {
            eprintln!("[rtc] set-remote-description: {e:?}");
            return;
        }
        let answer_promise = gst::Promise::with_change_func(move |reply| {
            match reply {
                Ok(Some(structure)) => {
                    let answered = structure.value("answer").ok()
                        .and_then(|v| v.get::<WebRTCSessionDescription>().ok());
                    match answered {
                        Some(answer) => {
                            wb_for_local.emit_by_name::<()>("set-local-description", &[&answer, &gst::Promise::new()]);
                            let text = answer.sdp().as_text().unwrap_or_default();
                            emit_event(format!("{{\"t\":\"answer\",\"sdp\":\"{}\"}}", json_escape(&text)));
                        }
                        None => eprintln!("[rtc] create-answer: no answer value"),
                    }
                }
                Ok(None) => eprintln!("[rtc] create-answer: no reply"),
                Err(e) => eprintln!("[rtc] create-answer: {e:?}"),
            }
        });
        wb_for_answer.emit_by_name::<()>("create-answer", &[&None::<gst::Structure>, &answer_promise]);
    });
    sess.webrtcbin.emit_by_name::<()>("set-remote-description", &[&offer, &promise]);
    true
}

pub fn add_ice(mline: u32, candidate: &str) -> bool {
    let Some(sess) = session().lock().ok().and_then(|m| m.clone()) else { return false };
    sess.webrtcbin.emit_by_name::<()>("add-ice-candidate", &[&mline, &candidate]);
    true
}

pub fn force_key() {
    let Some(sess) = session().lock().ok().and_then(|m| m.clone()) else { return };
    // all_headers defaults to true in this builder.
    let event = gst_video::UpstreamForceKeyUnitEvent::builder().build();
    sess.pay_src.push_event(event);
}

pub fn push_nal(nal: &[u8]) -> bool {
    let Some(sess) = session().lock().ok().and_then(|m| m.clone()) else { return false };
    if !sess.connected.load(Ordering::Relaxed) {
        return false;
    }
    sess.src.push_buffer(gst::Buffer::from_slice(nal.to_vec())).is_ok()
}

pub fn stop() {
    let Some(sess) = session().lock().ok().and_then(|mut m| m.take()) else { return };
    sess.connected.store(false, Ordering::Relaxed);
    sess.stopped.store(true, Ordering::Relaxed);
    let _ = sess.pipeline.set_state(gst::State::Null);
}
