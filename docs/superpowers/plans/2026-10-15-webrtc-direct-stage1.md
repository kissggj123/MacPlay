# WebRTC 直通 阶段 1（Homebrew 环境）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** H.264 经 addon 内 webrtcbin 打包 RTP 直推浏览器 `RTCPeerConnection`（零解码零编码），失败自动降级回现有 WS/WebCodecs。仅覆盖规格阶段 1（Homebrew 环境）。

**Architecture:** 两种视频模式（零转码 h264direct / 解码模式 h264tap）的 H.264 Annex B NAL 最终都汇聚在 Node 进程（webserver 的 `broadcastH264`），而 gst_video addon 以 NAPI in-process 形式挂在同一 Node 进程——因此 webrtcbin 管线放 addon 新模块 `rtc.rs`，由 `appsrc` 喂入（webserver 中继 NAL），信令经 NAPI 回调 ↔ `/rtc` WS 直达浏览器。单点集成、模式无关。信令采用浏览器先发 offer。

**Tech Stack:** Rust gstreamer-rs 0.24（gstreamer/gstreamer-app/gstreamer-video/gstreamer-webrtc/gstreamer-sdp，v1_24 features 与 player 一致）/ webserver.ts 手写 RFC6455 WS（沿用 WsParser/wsSendText）/ webclient.html 原生 RTCPeerConnection。

规格：`docs/superpowers/specs/2026-10-15-webrtc-direct-design.md`（本计划 = 阶段 1；阶段 2 捆绑插件、阶段 3 上车调参后续另写）

范围取舍（规格已定）：仅 H.264；仅局域网 host candidates（无 STUN/TURN）；不做 JPEG 兜底；音频不走 WebRTC。

测试说明：WebRTC 信令/媒体链路需真实浏览器 + GStreamer，无单测 harness。验证 = `cargo check`（Rust）→ `npm run build:engine`（tsc）→ 完整构建 → 上车手动验证（chrome://webrtc-internals、降级路径）。每任务一提交。

**既有事实（探查确认，勿重查）：**
- addon 经 [media.ts](file:///Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/Engine/media.ts) L61 `export const addon: any = require('livi-gst-video')` 暴露；[main.ts](file:///Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/Engine/main.ts) L11 已 import `addon`，L168 `startWebServer({...})`
- [webserver.ts](file:///Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/Engine/webserver.ts)：`broadcastH264(nal)` L441-506（NAL 编解码判定/缓存/转发唯一入口）；`startH264Relay` L519-536（TCP 18083）；upgrade 白名单 L614-616；WsParser 用法 L656-668；`wsSendText` L68-87；`wsTrackDrain` 已有
- [webclient.html](file:///Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/Engine/webclient.html)：入口 L668-693 `if(useWebCodecs){startWebCodecs()}else{...}`；`#v`(img)/`#c`(canvas) CSS L21-24；HTML L137-138；`videoSize()` L965-970；pointer 监听 L1004-1005/1015-1016/1027-1029/1030-1033/1037-1038；HUD `updateHud` L249-260
- addon Cargo（[addon/Cargo.toml](file:///Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/livi-gst-video/rust/addon/Cargo.toml)）现无直接 gstreamer 依赖；player 用 `gstreamer 0.24 features=["v1_24"]`
- Homebrew gst 已验证有 webrtcbin（用户前期确认）；捆绑包缺 nice/dtls 是阶段 2

---

## File Structure

| 文件 | 改动 |
|---|---|
| `native/livi-gst-video/rust/addon/src/rtc.rs` | 新建：webrtcbin 会话模块（appsrc 管线、offer/answer、ICE、NAL 喂入） |
| `native/livi-gst-video/rust/addon/Cargo.toml` | 加 5 个 gstreamer 依赖 |
| `native/livi-gst-video/rust/addon/src/lib.rs` | `mod rtc;` + 6 个 #[napi] 薄封装 |
| `native/Engine/webserver.ts` | `/rtc` WS 信令通道 + `rtcAddon` opt + `broadcastH264` 喂 NAL + `/health` 加 `rtc` |
| `native/Engine/main.ts` | `rtcAddon: () => addon` 传入 opts |
| `native/Engine/webclient.html` | `<video id="rv">`、startWebRTC/rtcDegrade、getStats 看门狗、HUD、videoSize/触控适配 |

---

### Task 1: Rust rtc.rs 模块 + NAPI surface

**Files:**
- Create: `native/livi-gst-video/rust/addon/src/rtc.rs`
- Modify: `native/livi-gst-video/rust/addon/Cargo.toml`
- Modify: `native/livi-gst-video/rust/addon/src/lib.rs`

- [ ] **Step 1: addon/Cargo.toml [dependencies] 追加**（与 player 同版本策略）

```toml
gstreamer = { version = "0.24", features = ["v1_24"] }
gstreamer-app = { version = "0.24", features = ["v1_24"] }
gstreamer-video = { version = "0.24", features = ["v1_24"] }
gstreamer-webrtc = { version = "0.24", features = ["v1_24"] }
gstreamer-sdp = { version = "0.24", features = ["v1_24"] }
```

- [ ] **Step 2: 新建 rtc.rs（完整文件）**

```rust
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

use gst::prelude::*;
use gst_app::AppSrc;
use gstreamer_webrtc::{WebRTCBundlePolicy, WebRTCPeerConnectionState, WebRTCSDPType, WebRTCSessionDescription};
use napi::bindgen_prelude::Buffer;
use napi::threadsafe_function::ThreadsafeFunction;
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
static EVENT_CB: OnceLock<Mutex<Option<ThreadsafeFunction<String>>>> = OnceLock::new();

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
    let tsfn: ThreadsafeFunction<String> = on_event
        .create_threadsafe_function(0, |ctx| Ok(vec![ctx.env.create_string(&ctx.value)?.into_unknown()]))
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

    // Local ICE candidates -> JS.
    webrtcbin.connect_on_ice_candidate(move |_bin, mline, candidate| {
        emit_event(format!(
            "{{\"t\":\"ice\",\"mline\":{mline},\"candidate\":\"{}\"}}",
            json_escape(candidate)
        ));
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
                emit_event(format!("{{\"t\":\"state\",\"state\":\"{}\"}}", json_escape(&format!("{state}"))));
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
            eprintln!("[rtc] set-remote-description: {e}");
            return;
        }
        let answer_promise = gst::Promise::with_change_func(move |reply| {
            match reply {
                Ok(Some(structure)) => match structure.value("answer").and_then(|v| v.get::<WebRTCSessionDescription>()) {
                    Ok(answer) => {
                        wb_for_local.emit_by_name::<()>("set-local-description", &[&answer, &gst::Promise::new()]);
                        let text = answer.sdp().as_text().unwrap_or_default();
                        emit_event(format!("{{\"t\":\"answer\",\"sdp\":\"{}\"}}", json_escape(&text)));
                    }
                    Err(e) => eprintln!("[rtc] create-answer reply: {e}"),
                },
                Ok(None) => eprintln!("[rtc] create-answer: no reply"),
                Err(e) => eprintln!("[rtc] create-answer: {e}"),
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
    let event = gst_video::event::UpstreamForceKeyUnit::builder().all_headers(true).build();
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
```

- [ ] **Step 3: lib.rs 挂模块 + NAPI 封装**（`mod feed;` 等声明之后加 `mod rtc;`；文件尾部追加）

```rust
mod rtc;

/// WebRTC passthrough availability (webrtcbin + dtls/nice present).
#[napi]
pub fn rtc_supported() -> bool { rtc::supported() }

/// Starts the webrtc pipeline. `on_event` receives JSON strings:
/// {t:"answer",sdp} | {t:"ice",mline,candidate} | {t:"connected"} | {t:"state",state}.
#[napi]
pub fn rtc_start(on_event: JsFunction) -> bool { rtc::start(on_event) }

/// Applies the browser's SDP offer; the answer arrives via the event callback.
#[napi]
pub fn rtc_set_offer(sdp: String) -> bool { rtc::set_offer(&sdp) }

/// Adds a browser ICE candidate.
#[napi]
pub fn rtc_add_ice(mline: u32, candidate: String) -> bool { rtc::add_ice(mline, &candidate) }

/// Asks the pipeline for a keyframe (best-effort upstream force-key-unit).
#[napi]
pub fn rtc_force_key() { rtc::force_key() }

/// Feeds one Annex B NAL unit (with start code). Dropped unless connected.
#[napi]
pub fn rtc_push_nal(nal: Buffer) -> bool { rtc::push_nal(nal.as_ref()) }

/// Tears the webrtc session down.
#[napi]
pub fn rtc_stop() { rtc::stop() }
```

注：`JsFunction` 已在 lib.rs 使用（`use napi::bindgen_prelude::{Buffer, External};` 在头部，`napi::JsFunction` 以全限定名使用于既有签名——新封装同样用 `JsFunction` 需确认解析，若报错改为 `napi::JsFunction`）。

- [ ] **Step 4: cargo check 通过**

Run: `cd /Users/yumikotoys/Downloads/MacPlay-CarBrowser/native/livi-gst-video/rust/addon && cargo check 2>&1 | tail -5`
Expected: `Finished` 无 error（warning 可接受）

- [ ] **Step 5: Commit**

```bash
git add native/livi-gst-video/rust/addon
git commit -m "feat(rtc): webrtcbin passthrough session module with NAPI signaling surface"
```

---

### Task 2: webserver.ts `/rtc` 信令通道 + NAL 喂入

**Files:**
- Modify: `native/Engine/webserver.ts`（WebServerOpts、broadcastH264、upgrade handler、/health）
- Modify: `native/Engine/main.ts:168-177`（opts 传 rtcAddon）

- [ ] **Step 1: WebServerOpts 增加字段**（`onBrowserClients?` 之后）

```ts
  // Fork: the gst_video addon for the /rtc WebRTC signaling channel (raw NAPI
  // surface). Omitted on hosts without webrtc support — /rtc then answers
  // {t:"unsupported"} and browsers take the WS/WebCodecs path.
  rtcAddon?: () => any
```

- [ ] **Step 2: `/rtc` 会话状态 + 事件桥**（插在 `startH264Relay()` 调用 L536 之后）

```ts
  // Fork: WebRTC direct passthrough (/rtc). Browser-offer-first signaling:
  // in  {t:"offer",sdp} | {t:"ice",mline,candidate} | {t:"pli"}
  // out {t:"answer",sdp} | {t:"ice",mline,candidate} | {t:"connected"} | {t:"state",state}
  // Single client like the h264 tap: a second join is rejected. NALs are fed
  // from broadcastH264 only while the peer connection is established.
  const rtc = opts.rtcAddon?.()
  const rtcOk = !!rtc && typeof rtc.rtcSupported === 'function' && rtc.rtcSupported() === true
  let rtcSock: net.Socket | null = null
  let rtcNalsActive = false
  function rtcEvent(json: string): void {
    try {
      const msg = JSON.parse(json)
      if (msg.t === 'connected') {
        rtcNalsActive = true
        if (videoCodec === 'h264') {
          try {
            if (cachedSps) rtc.rtcPushNal(cachedSps)
            if (cachedPps) rtc.rtcPushNal(cachedPps)
          } catch { /* ignore */ }
        }
      } else if (msg.t === 'state') {
        rtcNalsActive = false
      }
    } catch { /* ignore */ }
    if (rtcSock) wsSendText(rtcSock, json)
  }
  function rtcPushNal(nal: Buffer): void {
    if (!rtcNalsActive || videoCodec !== 'h264' || !rtc) return
    try { rtc.rtcPushNal(nal) } catch { /* ignore */ }
  }
```

- [ ] **Step 3: broadcastH264 末尾喂入**（`sendNalToClients(nal)` 之前或之后均可，放在 `videoNalsSent++` 旁）

```ts
    videoNalsSent++
    rtcPushNal(nal)
    sendNalToClients(nal)
```

- [ ] **Step 4: upgrade 白名单 + /rtc 分支**

L616 改为：

```ts
    if (url !== '/touch' && url !== '/h264' && url !== '/rtc') { socket.destroy(); return }
```

`/h264` 分支之后加：

```ts
    if (url === '/rtc') {
      if (!rtcOk) {
        // Complete the handshake, answer unsupported, then close: the page
        // treats this as "feature absent" and goes straight to WS/WebCodecs.
        try { wsSendText(sock, JSON.stringify({ t: 'unsupported' })) } catch { /* ignore */ }
        setTimeout(() => { try { sock.destroy() } catch { /* ignore */ } }, 300).unref?.()
        return
      }
      if (rtcSock) { try { sock.destroy() } catch { /* ignore */ } return }
      rtcSock = sock
      wsTrackDrain(sock)
      try { rtc.rtcStart(rtcEvent) } catch { /* ignore */ }
      const remove = () => {
        if (rtcSock === sock) { rtcSock = null; rtcNalsActive = false }
        try { rtc?.rtcStop() } catch { /* ignore */ }
        try { sock.destroy() } catch { /* ignore */ }
      }
      const parser = new WsParser(sock, (text) => {
        try {
          const msg = JSON.parse(text)
          if (msg.t === 'offer' && typeof msg.sdp === 'string') rtc.rtcSetOffer(msg.sdp)
          else if (msg.t === 'ice' && typeof msg.mline === 'number' && typeof msg.candidate === 'string') rtc.rtcAddIce(msg.mline, msg.candidate)
          else if (msg.t === 'pli') rtc.rtcForceKey()
        } catch { /* ignore */ }
      }, () => {}, remove)
      sock.on('data', (c: Buffer) => parser.feed(c))
      sock.on('error', remove)
      sock.on('close', remove)
      return
    }
```

- [ ] **Step 5: /health 加 rtc 字段**

`res.end(JSON.stringify({...}))` 对象内加一行：

```ts
        rtc: rtcOk,
```

- [ ] **Step 6: main.ts opts 传 addon**（`certDir` 行后）

```ts
  rtcAddon: () => addon,
```

- [ ] **Step 7: tsc 通过**

Run: `npm run build:engine`
Expected: exit 0

- [ ] **Step 8: Commit**

```bash
git add native/Engine/webserver.ts native/Engine/main.ts
git commit -m "feat(rtc): /rtc signaling channel relaying offers, ICE and H.264 NALs to the addon"
```

---

### Task 3: webclient.html WebRTC 优先 + 降级 + HUD + video 触控适配

**Files:**
- Modify: `native/Engine/webclient.html`（CSS L21-24、HTML L138、状态 L243-247、入口 L668-693、videoSize L965-970、pointer 监听 L1004-1038）

- [ ] **Step 1: CSS 加 #rv（紧跟 #c 规则后）**

```css
  #rv{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;
    touch-action:none;cursor:pointer;display:none}
```

- [ ] **Step 2: HTML 加 video 元素**（`<canvas id="c"></canvas>` 之后）

```html
<video id="rv" autoplay playsinline muted></video>
```

- [ ] **Step 3: 状态变量**（L244 `var h264ws=null,...` 行后）

```js
  var rv=document.getElementById('rv');
  var rtcws=null, rtcpc=null, rtcActive=false, rtcStatsTimer=null, rtcStatsSummary='';
```

- [ ] **Step 4: startWebRTC + rtcDegrade**（插在 `startMjpeg` 函数之后、入口 L668 之前）

```js
  /* ============ WebRTC direct passthrough (H.264, LAN host candidates) ============ */
  function rtcDegrade(reason){
    if(!rtcpc&&!rtcws) return;
    try{ sessionStorage.setItem('rtcBlocked','1'); }catch(e){}
    console.log('[rtc] degrade:',reason);
    if(rtcStatsTimer){ clearInterval(rtcStatsTimer); rtcStatsTimer=null; }
    try{ if(rtcpc){rtcpc.close();rtcpc=null;} }catch(e){}
    try{ if(rtcws){rtcws.close();rtcws=null;} }catch(e){}
    rtcActive=false;
    rv.style.display='none';
    startWebCodecs();
  }
  function startWebRTC(){
    canvas.style.display='none'; img.style.display='none'; rv.style.display='block';
    var proto=location.protocol==='https:'?'wss':'ws';
    var exchanged=false;
    rtcpc=new RTCPeerConnection();
    rtcpc.addTransceiver('video',{direction:'recvonly'});
    rtcpc.ontrack=function(ev){
      rv.srcObject=ev.streams[0];
      rtcActive=true;
      waiting.style.display='none';
    };
    rtcpc.onicecandidate=function(ev){
      if(ev.candidate&&rtcws&&rtcws.readyState===1)
        rtcws.send(JSON.stringify({t:'ice',mline:ev.candidate.sdpMLineIndex||0,candidate:ev.candidate.candidate}));
    };
    rtcpc.onconnectionstatechange=function(){
      if(rtcpc&&(rtcpc.connectionState==='failed'||rtcpc.connectionState==='disconnected'))
        rtcDegrade('ice '+rtcpc.connectionState);
    };
    rtcws=new WebSocket(proto+'://'+location.host+'/rtc');
    var sdpTimer=setTimeout(function(){ if(!exchanged) rtcDegrade('sdp timeout'); },3000);
    rtcws.onopen=function(){
      rtcpc.createOffer().then(function(offer){ return rtcpc.setLocalDescription(offer); })
        .then(function(){ if(rtcws&&rtcws.readyState===1) rtcws.send(JSON.stringify({t:'offer',sdp:rtcpc.localDescription.sdp})); })
        .catch(function(e){ clearTimeout(sdpTimer); rtcDegrade('offer: '+e); });
    };
    rtcws.onmessage=function(ev){
      var msg; try{ msg=JSON.parse(ev.data); }catch(e){ return; }
      if(msg.t==='unsupported'){ clearTimeout(sdpTimer); rtcDegrade('unsupported'); return; }
      if(msg.t==='answer'&&msg.sdp){
        exchanged=true; clearTimeout(sdpTimer);
        rtcpc.setRemoteDescription({type:'answer',sdp:msg.sdp}).catch(function(e){ rtcDegrade('answer: '+e); });
      } else if(msg.t==='ice'&&msg.candidate){
        rtcpc.addIceCandidate({candidate:msg.candidate,sdpMLineIndex:msg.mline||0}).catch(function(){ /* non-fatal */ });
      }
    };
    rtcws.onerror=function(){ try{rtcws.close();}catch(e){} };
    rtcws.onclose=function(){ if(!exchanged){ clearTimeout(sdpTimer); rtcDegrade('rtc ws closed'); } };
    // Health watchdog: 1s getStats. framesDecoded stalled 5s -> PLI, another
    // 5s -> degrade back to WS/WebCodecs for this session.
    var lastDecoded=-1, stallSince=0, pliAt=0;
    rtcStatsTimer=setInterval(function(){
      if(!rtcpc||rtcpc.connectionState!=='connected'){ return; }
      rtcpc.getStats().then(function(stats){
        var decoded=null, fps=null, lost=null, rtt=null;
        stats.forEach(function(s){
          if(s.type==='inbound-rtp'&&s.kind==='video'){
            if(typeof s.framesDecoded==='number') decoded=s.framesDecoded;
            if(typeof s.framesPerSecond==='number') fps=s.framesPerSecond;
            if(typeof s.packetsLost==='number') lost=s.packetsLost;
          }
          if(s.type==='candidate-pair'&&s.state==='succeeded'&&typeof s.currentRoundTripTime==='number')
            rtt=Math.round(s.currentRoundTripTime*1000);
        });
        rtcStatsSummary=(fps!==null?fps.toFixed(1)+' fps':'…')+(lost!==null?'  丢包'+lost:'')+(rtt!==null?'  '+rtt+'ms':'');
        if(decoded!==null){
          if(decoded>lastDecoded){ lastDecoded=decoded; stallSince=0; }
          else if(lastDecoded>=0){
            if(!stallSince) stallSince=Date.now();
            var stall=Date.now()-stallSince;
            if(stall>5000&&(!pliAt||Date.now()-pliAt>5000)){
              if(rtcws&&rtcws.readyState===1) rtcws.send(JSON.stringify({t:'pli'}));
              pliAt=Date.now();
            }
            if(stall>10000) rtcDegrade('stalled '+Math.round(stall/1000)+'s');
          }
        }
      }).catch(function(){});
    },1000);
    setInterval(function(){
      if(!rtcActive) return;
      hud.style.display='block';
      hud.textContent='WebRTC H.264\n'+rtcStatsSummary;
    },1000);
  }
```

- [ ] **Step 5: 入口改 WebRTC 优先**（L668-669 `if (useWebCodecs) { startWebCodecs(); } else {`）

```js
  var canRtc = useWebCodecs && window.RTCPeerConnection
    && !(function(){ try { return sessionStorage.getItem('rtcBlocked'); } catch(e) { return null; } })()
    && typeof health !== 'undefined' && health && health.rtc === true && health.codec !== 'h265';
  if (canRtc) {
    startWebRTC();
  } else if (useWebCodecs) {
    startWebCodecs();
  } else {
```

（`else {` 块内容不变）

- [ ] **Step 6: videoSize 适配 + 触控监听镜像**

`videoSize()`（L965-970）改为：

```js
  function videoSize(){
    if(rtcActive&&rv.videoWidth) return {w:rv.videoWidth,h:rv.videoHeight,el:rv};
    var el=useWebCodecs?canvas:img;
    var w=(useWebCodecs?canvas.width:img.naturalWidth)||960;
    var h=(useWebCodecs?canvas.height:img.naturalHeight)||Math.round(960*9/16);
    return {w:w,h:h,el:el};
  }
```

在 L1038（hint once 监听）之后加：

```js
  rv.addEventListener('pointerdown',onPointerDown);
  rv.addEventListener('pointermove',onPointerMove);
  ['pointerup','pointercancel','lostpointercapture'].forEach(function(ev){ rv.addEventListener(ev,release); });
  ['contextmenu'].forEach(function(ev){ rv.addEventListener(ev,function(e){e.preventDefault();}); });
  rv.addEventListener('pointerdown',function(){ hint.style.display='none'; },{once:true});
```

- [ ] **Step 7: tsc 通过**

Run: `npm run build:engine`
Expected: exit 0（webclient.html 为静态资源，构建仅拷贝；tsc 验证 webserver/main 改动无回归）

- [ ] **Step 8: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(rtc): WebRTC-first video path with stalled-frame watchdog and WS/WebCodecs fallback"
```

---

### Task 4: 构建与上车验证（阶段 1 验收）

**Files:** 无代码改动。

- [ ] **Step 1: 完整构建**

Run: `bash scripts/build-macplay.sh --arch=arm64`（后台，约 6 分钟）
Expected: exit 0，`dist/NIOPlay-1.2.2-arm64.dmg`

- [ ] **Step 2: 交付用户验证清单**

前置：开发机 = Homebrew GStreamer 环境（阶段 1 范围），浏览器 Chrome/Edge HTTPS 8443。
1. 连接 iPhone 后开浏览器：HUD 显示 `WebRTC H.264` + fps/丢包/RTT；`chrome://webrtc-internals` 确认 inbound-rtp framesDecoded 增长、活动监视器 CPU 无解码占用（对比 WebCodecs 模式）
2. 零转码模式（MACPLAY_NO_DECODE=1）下同样验证（两个来源都应可直通）
3. 降级路径 a：杀掉接收端/拔线 → ICE failed → 自动回 WS/WebCodecs 画面恢复
4. 降级路径 b：h265 模式 → /health codec=h265 → 直接走 WebCodecs，不试 WebRTC
5. 降级路径 c：`sessionStorage.rtcBlocked` 后刷新不自动重试 WebRTC；新标签页恢复尝试
6. 触控：WebRTC 模式下点按/拖动正常映射（video 元素 rect）

- [ ] **Step 3: 用户确认后推送**

```bash
git push origin web-streaming
```

之后进入阶段 2（捆绑包补 nice/dtls/srtp/rtpmanager/rtp 插件 + 构建自检）。

---

## Self-Review 记录

- 规格阶段 1 覆盖：Rust 管线分支（Task 1，appsrc 喂入版——规格"appsink 直出"的等价实现，因 webserver 已聚合两模式 NAL 且 webrtcbin 必须在 addon 进程）；浏览器先发 offer ✓；/rtc 单客户端 ✓；信令 JSON 格式 `{t:offer|answer|ice, sdp?, candidate?}` 落为 offer/answer/ice + mline ✓；webclient ontrack/降级/sessionStorage/HUD ✓；错误处理 3s 超时 ✓ unsupported ✓ ICE failed ✓
- 占位符：无。所有代码完整。
- 类型一致性：NAPI 名（rtcSupported/rtcStart/rtcSetOffer/rtcAddIce/rtcForceKey/rtcPushNal/rtcStop）与 webserver.ts 调用一致；事件 JSON 字段 Rust `format!` 与 JS 解析一致（mline/candidate/sdp/t）；`{t:"connected"}` 触发 webserver 推 cachedSps/cachedPps 与 rtc.rs 的 connected 门控对应。
- 已知偏差（有意）：信令 ice 带 mline 字段（规格 JSON 只写了 candidate——Safari/Chrome addIceCandidate 需要 mline，规格笔误）；`/health` 增加 `rtc` 字段（省一次注定失败的 WS 握手，h265 直接跳过）。
