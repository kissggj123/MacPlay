/**
 * webserver.ts — fork addition: browser re-stream for the car head-unit browser.
 *
 * HTTP on 0.0.0.0:<httpPort> (default 8080):
 *   GET /        touch-enabled MJPEG client page (native/Engine/webclient.html)
 *   GET /mjpeg   proxies the Rust video tap's MJPEG (127.0.0.1:<mjpegPort>/mjpeg)
 *   GET /health  JSON status for the car browser / debugging
 * WebSocket /touch:
 *   -> {t:'touch', touches:[{x,y,down,id}]}  (x/y normalised 0..1)
 *      forwarded to CpStack.sendTouches(); multi-touch up to 2 contacts
 *   -> {t:'ping'}  answered with {t:'pong'}
 *   <- binary wheelplay PCM audio frames (server->browser only),
 *      relayed from the Rust audio tap over TCP 127.0.0.1:<audioPort>,
 *      played by the browser with the Web Audio API (see webclient.html).
 *
 * No new npm dependencies: node:http + node:crypto only. WebSocket is
 * hand-rolled (server-side, RFC 6455 minimal subset: text frames, ping/pong,
 * close; client frames are masked as required).
 */
import http from 'node:http'
import https from 'node:https'
import tls from 'node:tls'
import crypto from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

export interface TouchContact { x: number; y: number; down: boolean; id: number }
export interface TouchStack {
  sendTouches(c: TouchContact[]): void
  sendKnob?(s: any): void
  setDisplay?(cfg: DisplayConfig): void
}
export interface DisplayConfig {
  width: number; height: number; fps: number
  codec: string; uiscale: number; matchWindow?: boolean
}
export interface WebServerOpts {
  httpPort: number
  httpsPort: number
  mjpegPort: number
  audioPort: number
  h264Port: number
  micPort: number
  certDir: string
  getStack: () => TouchStack | undefined
  isVideoReady: () => boolean
  // Fork: current video codec in use, so a display request without an explicit
  // codec (e.g. "匹配本窗口像素") keeps streaming codec unchanged.
  currentVideoCodec?: () => 'h264' | 'h265'
  // Fork: whether display switching can succeed at all (wireless only — wired
  // sessions veto it because the phone never reconnects after the drop).
  displaySwitchable?: () => boolean
  // Fork: a car browser connected/disconnected (/touch WS). Audio and mic
  // follow the display: while true the Mac local output is muted and the
  // browser mic takes over the CarPlay input when the browser opens one.
  onBrowserClients?: (connected: boolean) => void
  // Fork: /mjpeg proxies the Rust GStreamer websink (internal stream).
  // The pipeline taps decoded frames directly via MACPLAY_WEB_PORT.
}

const WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
const FALLBACK_PAGE =
  '<!doctype html><html><body style="background:#000;color:#fff;font-family:sans-serif">' +
  '<h1>webclient.html missing</h1><p>Rebuild with the fork patch applied.</p></body></html>'

function wsAccept(key: string): string {
  return crypto.createHash('sha1').update(key + WS_MAGIC).digest('base64')
}

/** Server -> client unmasked text frame. */
function wsSendText(socket: net.Socket, text: string): void {
  const payload = Buffer.from(text, 'utf8')
  let header: Buffer
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length])
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x81
    header[1] = 126
    header.writeUInt16BE(payload.length, 2)
  } else {
    return // touch messages are tiny; never happens
  }
  socket.write(Buffer.concat([header, payload]))
}

/** Fork: protocol-level ping (opcode 0x9). Browsers answer it in the network
 *  stack with a 0x8A pong even when the page's JS is frozen by Safari App Nap —
 *  a text {"t":"ping"} never survives that (frozen JS can't reply), which used
 *  to get the client kicked as dead and paused the music mid-play. */
function wsSendPing(socket: net.Socket): void {
  if ((socket as any).destroyed) return
  try { socket.write(Buffer.from([0x89, 0x00])) } catch { /* ignore */ }
}

/** Server -> client unmasked binary frame (wheelplay PCM audio). */
// Fork: backpressure guard — a stalled browser (car screen off, WiFi roaming)
// stops reading TCP; without a cap the kernel buffer grows for minutes and the
// stream "plays" far behind reality (looks like a freeze). Once a client has
// 8MB accepted-but-unsent, drop it; the browser reconnects in 2s and resumes
// cleanly from the next keyframe/config NALs.
const wsPending = new WeakMap<net.Socket, number>()
const WS_PENDING_LIMIT = 8 * 1024 * 1024
function wsTrackDrain(socket: net.Socket): void {
  socket.on('drain', () => wsPending.delete(socket))
}
function wsSendBinary(socket: net.Socket, data: Buffer): void {
  if ((socket as any).destroyed) return
  let header: Buffer
  if (data.length < 126) {
    header = Buffer.from([0x82, data.length])
  } else if (data.length < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x82
    header[1] = 126
    header.writeUInt16BE(data.length, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x82
    header[1] = 127
    header.writeBigUInt64BE(BigInt(data.length), 2)
  }
  const full = Buffer.concat([header, data])
  try {
    if (!socket.write(full)) {
      const pending = (wsPending.get(socket) ?? 0) + full.length
      if (pending > WS_PENDING_LIMIT) {
        console.log('[webserver] slow client dropped,', pending, 'bytes queued')
        wsPending.delete(socket)
        try { socket.destroy() } catch { /* ignore */ }
        return
      }
      wsPending.set(socket, pending)
    }
  } catch { /* ignore */ }
}

/** Minimal client-frame parser: masked text/binary, ping/pong, close. */
class WsParser {
  private buf = Buffer.alloc(0)
  readonly onClose: () => void
  constructor(
    private socket: net.Socket,
    private onMessage: (text: string) => void,
    private onBinary: (data: Buffer) => void,
    onClose: () => void,
  ) { this.onClose = onClose }
  feed(chunk: Buffer): void {
    this.buf = Buffer.concat([this.buf, chunk])
    for (;;) {
      if (this.buf.length < 2) return
      const opcode = this.buf[0] & 0x0f
      const masked = (this.buf[1] & 0x80) !== 0
      let len = this.buf[1] & 0x7f
      let off = 2
      if (len === 126) {
        if (this.buf.length < 4) return
        len = this.buf.readUInt16BE(2)
        off = 4
      } else if (len === 127) {
        if (this.buf.length < 10) return
        if (this.buf.readUInt32BE(2) !== 0) { this.socket.destroy(); return } // >4GB, no
        len = this.buf.readUInt32BE(6)
        off = 10
      }
      const maskLen = masked ? 4 : 0
      if (this.buf.length < off + maskLen + len) return
      let payload = this.buf.subarray(off + maskLen, off + maskLen + len)
      if (masked) {
        const mask = this.buf.subarray(off, off + 4)
        const u = Buffer.from(payload)
        for (let i = 0; i < u.length; i++) u[i] ^= mask[i % 4]
        payload = u
      }
      this.buf = this.buf.subarray(off + maskLen + len)
      if (opcode === 0x8) { this.onClose(); return }
      if (opcode === 0x9) { this.socket.write(Buffer.from([0x8a, 0x00])); continue } // pong
      if (opcode === 0x1) {
        try { this.onMessage(payload.toString('utf8')) } catch { /* ignore */ }
      }
      if (opcode === 0x2) {
        try { this.onBinary(Buffer.from(payload)) } catch { /* ignore */ }
      }
      // 0x0 continuation: not used by our client; ignore
    }
  }
}

let lastKeyframeAt = 0

function handleTouchMessage(raw: string, opts: WebServerOpts, sock: net.Socket): void {
  let msg: any
  try { msg = JSON.parse(raw) } catch { return }
  // Fork: PlayPort-style keyframe request from browser.
  // The browser asks for a keyframe when its decoder is stalled.
  // Throttled server-side: a stalled/looping client must not flood the phone's
  // control channel with forceKeyFrame commands (that stalled sessions).
  if (msg && msg.t === 'keyframe') {
    const now = Date.now()
    if (now - lastKeyframeAt < 800) return
    lastKeyframeAt = now
    const stack = opts.getStack()
    if (stack && typeof (stack as any).forceMainKeyframe === 'function') {
      try { (stack as any).forceMainKeyframe() } catch { /* ignore */ }
    } else {
      console.error('[webserver] keyframe requested but CpStack has no forceMainKeyframe()')
    }
    return
  }
  const stack = opts.getStack()
  if (!stack) return
  if (msg && msg.t === 'touch' && Array.isArray(msg.touches)) {
    const touches: TouchContact[] = msg.touches
      .filter((c: any) => c && Number.isFinite(c.x) && Number.isFinite(c.y))
      .slice(0, 2)
      .map((c: any, i: number) => ({
        x: Math.min(1, Math.max(0, Number(c.x))),
        y: Math.min(1, Math.max(0, Number(c.y))),
        down: !!c.down,
        id: (Number(c.id) || i) % 2,
      }))
    if (touches.length) stack.sendTouches(touches)
  }
  // Fork: rotary knob / keyboard control (PlayPort-style). The browser sends
  // {t:'knob', ...KnobState}; we forward to CpStack.sendKnob().
  if (msg && msg.t === 'knob' && typeof msg === 'object') {
    const state: any = {}
    if (msg.select !== undefined) state.select = !!msg.select
    if (msg.home !== undefined) state.home = !!msg.home
    if (msg.back !== undefined) state.back = !!msg.back
    if (msg.siri !== undefined) state.siri = !!msg.siri
    if (msg.playpause !== undefined) state.playpause = !!msg.playpause
    if (Number.isFinite(msg.x)) state.x = Math.max(-127, Math.min(127, Math.round(msg.x)))
    if (Number.isFinite(msg.y)) state.y = Math.max(-127, Math.min(127, Math.round(msg.y)))
    if (Number.isFinite(msg.wheel)) state.wheel = Math.max(-127, Math.min(127, Math.round(msg.wheel)))
    if (Object.keys(state).length) {
      const stackAny = stack as any
      if (typeof stackAny.sendKnob === 'function') stackAny.sendKnob(state)
    }
  }
  // Fork: display settings from browser (PlayPort-style). The browser sends
  // {t:'display', width, height, fps, codec, uiscale}; we forward to the
  // CarPlay stack to reconfigure (may trigger reconnect).
  // Fork: smart display probing. The browser asks whether display switching is
  // even possible before reporting its window size. Wired sessions veto every
  // switch (the phone never reconnects after the drop), so answering up front
  // keeps the browser from sending pointless display requests on USB.
  if (msg && msg.t === 'displayProbe' && typeof msg === 'object') {
    wsSendText(sock, JSON.stringify({ t: 'displayProbe', switchable: opts.displaySwitchable?.() ?? false }))
    return
  }
  if (msg && msg.t === 'display' && typeof msg === 'object') {
    const cfg: DisplayConfig = {
      width: Math.max(320, Math.min(3840, Math.round(Number(msg.width) || 1280))),
      height: Math.max(240, Math.min(2160, Math.round(Number(msg.height) || 720))),
      fps: msg.fps === 30 ? 30 : 60,
      codec: msg.codec === 'hevc' ? 'hevc'
        : msg.codec === 'h264' ? 'h264'
        : (opts.currentVideoCodec?.() === 'h265' ? 'hevc' : 'h264'),
      uiscale: [75, 85, 100, 115].includes(Number(msg.uiscale)) ? Number(msg.uiscale) : 100,
      matchWindow: !!msg.matchWindow,
    }
    const stackAny = stack as any
    if (typeof stackAny.setDisplay === 'function') {
      try { stackAny.setDisplay(cfg) } catch { /* ignore */ }
    } else {
      console.error(`[webserver] display config requested ${cfg.width}x${cfg.height}@${cfg.fps} ${cfg.codec}, no setDisplay on stack`)
    }
  }
}

export function startWebServer(opts: WebServerOpts): http.Server {
  const clientPath = path.join(__dirname, 'webclient.html')
  // Fork: expose the relay's live codec to message handlers; display requests
  // without an explicit codec keep whatever is streaming now.
  const optsWithCodec: WebServerOpts = { ...opts, currentVideoCodec: () => videoCodec }
  // Connected browser WebSockets; PCM audio frames are broadcast to all.
  const wsClients = new Set<net.Socket>()
  // Fork: audio/mic follow the display. A connected /touch client means the
  // car browser is the audience; the Mac local output is muted while true and
  // restored ~2s after the last client leaves (page refresh tolerance).
  let browserLinger: NodeJS.Timeout | null = null
  function notifyBrowserClients(): void {
    if (!opts.onBrowserClients) return
    if (wsClients.size > 0) {
      if (browserLinger) { clearTimeout(browserLinger); browserLinger = null }
      opts.onBrowserClients(true)
    } else if (!browserLinger) {
      browserLinger = setTimeout(() => {
        browserLinger = null
        if (wsClients.size === 0) opts.onBrowserClients?.(false)
      }, 2000)
    }
  }
  function broadcastAudio(frame: Buffer): void {
    for (const sock of wsClients) {
      if ((sock as any).destroyed) { wsClients.delete(sock); continue }
      wsSendBinary(sock, frame)
    }
  }
  // Fork: TCP relay from the Rust audio tap (webaudio.rs). Length-prefixed
  // wheelplay PCM frames -> WebSocket binary -> car browser (Web Audio API).
  // Replaces the earlier Ogg/Opus HTTP proxy: lower latency, no encoder.
  // Fork: the audio tap only listens once a CarPlay session opens. Before that,
  // every 2s retry logged connect ECONNREFUSED and flooded the live log — keep
  // the fast retry (audio picks up within 2s of the tap opening) but show the
  // error at most once per 30s until it connects.
  let audioRelayErrorAt = 0
  function startAudioRelay(): void {
    const sock = net.connect(opts.audioPort, '127.0.0.1')
    let buf = Buffer.alloc(0)
    // Fork: diagnostics for "browser gets no audio" — show whether the relay
    // ever connects and how many bytes/s flow from the Rust tap.
    let audioBytes = 0, audioLogAt = Date.now()
    const reconnect = () => { setTimeout(startAudioRelay, 2000).unref?.() };
    sock.on('connect', () => { audioRelayErrorAt = 0; buf = Buffer.alloc(0); console.log('[webserver] audio relay connected :' + opts.audioPort) })
    sock.on('data', (chunk: Buffer) => {
      audioBytes += chunk.length
      const now = Date.now()
      if (now - audioLogAt >= 10000) {
        console.log('[webserver] audio relay traffic', Math.round(audioBytes / ((now - audioLogAt) / 1000)), 'B/s')
        audioBytes = 0; audioLogAt = now
      }
      buf = Buffer.concat([buf, chunk])
      while (buf.length >= 4) {
        const len = buf.readUInt32BE(0)
        if (len > 4 * 1024 * 1024 || buf.length < 4 + len) break // sanity / wait
        broadcastAudio(buf.subarray(4, 4 + len))
        buf = buf.subarray(4 + len)
      }
    })
    sock.on('error', (e) => {
      const now = Date.now()
      if (now - audioRelayErrorAt >= 30000) { audioRelayErrorAt = now; console.log('[webserver] audio relay error:', (e as Error).message, '(audio tap not up yet — retrying)') }
    })
    sock.on('close', reconnect)
  }
  startAudioRelay()
  // Fork: H.264 passthrough for WebCodecs (PlayPort-style zero-reencode).
  // TCP relay from the Rust h264 tap (h264tap.rs): length-prefixed Annex B
  // NAL units -> WebSocket binary on /h264 -> browser VideoDecoder.
  const h264Clients = new Set<net.Socket>()
  // Fork: video codec in use (0=H.264, 1=H.265), set from Rust forwarder
  let videoCodec: 'h264' | 'h265' = 'h264'
  let codecReceived = false
  // Fork: cache VPS/SPS/PPS to send to new browser clients (they connect after
  // the Rust forwarder already sent config to Node)
  let cachedVps: Buffer | null = null
  let cachedSps: Buffer | null = null
  let cachedPps: Buffer | null = null
  function getNalType(nal: Buffer): number {
    if (nal.length <= 4) return -1
    let off = 0
    if (nal[0] === 0 && nal[1] === 0) {
      off = (nal[2] === 1) ? 3 : (nal[2] === 0 && nal[3] === 1 ? 4 : 0)
    }
    if (off === 0 || off >= nal.length) return -1
    if (videoCodec === 'h265') {
      // HEVC: 2-byte header, type = (byte0 >> 1) & 0x3F
      if (off + 1 >= nal.length) return -1
      return (nal[off] >> 1) & 0x3F
    } else {
      // H.264: 1-byte header, type = byte0 & 0x1F
      return nal[off] & 0x1F
    }
  }
  /** Fork: detect a start code followed by a run of 4-byte-BE-length-prefixed
   * NALs covering the buffer exactly — what an unfixed Rust forwarder emits for
   * a multi-NAL CarPlay access unit. Returns clean Annex B NALs (start code per
   * NAL) or null when the buffer is already a plain Annex B NAL. */
  function annexBFromLengthRun(buf: Buffer): Buffer[] | null {
    if (buf.length < 10) return null
    let off = 0
    if (buf[0] === 0 && buf[1] === 0 && buf[2] === 1) off = 3
    else if (buf[0] === 0 && buf[1] === 0 && buf[2] === 0 && buf[3] === 1) off = 4
    else return null
    const nals: Buffer[] = []
    while (off + 4 <= buf.length) {
      const len = buf.readUInt32BE(off)
      off += 4
      if (len === 0 || off + len > buf.length || len > buf.length) return null
      const nal = buf.subarray(off, off + len)
      if (nal.length < 2) return null
      // plausibility: a real NAL header at every boundary
      if (videoCodec === 'h265') { if (((nal[0] >> 1) & 0x3f) > 40) return null }
      else { const t = nal[0] & 0x1f; if (t < 1 || t > 23) return null }
      nals.push(Buffer.concat([Buffer.from([0, 0, 0, 1]), nal]))
      off += len
    }
    if (off !== buf.length || nals.length < 2) return null
    return nals
  }

  function sendNalToClients(nal: Buffer): void {
    for (const sock of h264Clients) {
      if ((sock as any).destroyed) { h264Clients.delete(sock); continue }
      wsSendBinary(sock, nal)
    }
  }

  // Fork (weak-network): WheelPlay-style dual-signal health. The server counts
  // NALs actually handed to clients and pushes {t:'video',frames:N} to the
  // /h264 socket every 2s. The browser's keyframe watchdog only fires when the
  // SOURCE is still advancing but nothing decodes — on a static CarPlay screen
  // (or a genuinely stalled uplink) it stays quiet, so throttled links are not
  // pummeled by force-keyframe I-frames (each one is a congestion collapse).
  let videoNalsSent = 0
  setInterval(() => {
    if (!h264Clients.size) return
    const msg = JSON.stringify({ t: 'video', frames: videoNalsSent })
    const payload = Buffer.from(msg, 'utf8')
    const header = Buffer.from([0x81, payload.length])
    for (const sock of h264Clients) {
      if ((sock as any).destroyed) { h264Clients.delete(sock); continue }
      try { sock.write(Buffer.concat([header, payload])) } catch { /* ignore */ }
    }
  }, 2000).unref?.()

  /** Fork: infer the codec from a config NAL header. H.264 SPS/PPS start with
   * type 7/8; HEVC VPS/SPS/PPS have a 2-byte header with type 32..34. HEVC
   * types are checked first: an HEVC IDR byte (0x28) collides with H.264 PPS
   * (type 8) via the 1-byte header mask. Streams always lead with config
   * NALs, so the first inferable NAL decides reliably. */
  function inferCodec(buf: Buffer): 'h264' | 'h265' | null {
    if (buf.length < 5) return null
    let off = 0
    if (buf[0] === 0 && buf[1] === 0) {
      off = buf[2] === 1 ? 3 : buf[2] === 0 && buf[3] === 1 ? 4 : 0
    }
    if (off === 0 || off + 1 >= buf.length) return null
    const b = buf[off]
    const t265 = (b >> 1) & 0x3f
    if (t265 >= 32 && t265 <= 34) return 'h265'
    const t264 = b & 0x1f
    if (t264 === 7 || t264 === 8) return 'h264'
    return null
  }

  function broadcastH264(nal: Buffer): void {
    // Codec signaling differs by source: h264direct (zero-transcode) prepends
    // a 1-byte codec identifier frame; h264tap (decode mode) streams plain
    // Annex B — infer the codec from the first config NAL instead.
    if (!codecReceived) {
      if (nal.length === 1) {
        videoCodec = nal[0] === 1 ? 'h265' : 'h264'
        codecReceived = true
        console.error(`[webserver] video codec: ${videoCodec} (identifier)`)
      } else {
        const inferred = inferCodec(nal)
        if (!inferred) return
        videoCodec = inferred
        codecReceived = true
        console.error(`[webserver] video codec: ${videoCodec} (config NAL)`)
      }
    }
    // Fork: an unfixed Rust forwarder may send one start code followed by a
    // length-prefixed NAL run (whole access unit) — reframe before relaying.
    if (nal.length > 4 && nal[0] === 0 && nal[1] === 0) {
      const reframed = annexBFromLengthRun(nal)
      if (reframed) {
        for (const n of reframed) broadcastH264(n)
        return
      }
    }
    // Detect VPS (32) / SPS (33,7) / PPS (34,8) from Annex B NAL
    const type = getNalType(nal)
    if (videoCodec === 'h265') {
      if (type === 32) cachedVps = nal
      else if (type === 33) cachedSps = nal
      else if (type === 34) cachedPps = nal
    } else {
      // Belt & braces: if the codec was misinferred from a slice NAL (the
      // iPhone keeps HEVC VPS/SPS/PPS in hvcC, so the tap may stream a slice
      // first — its 1-byte mask collides with H.264 types), a real HEVC
      // config NAL corrects it. Match the exact header bytes (VPS 0x40 /
      // SPS 0x42 / PPS 0x44 with tid=1 in the second byte) — the HEVC type
      // arithmetic alone would false-positive on H.264 slice 0x41 (=32).
      let hoff = 0
      if (nal[0] === 0 && nal[1] === 0) {
        hoff = nal[2] === 1 ? 3 : (nal[2] === 0 && nal[3] === 1 ? 4 : 0)
      }
      const hb = hoff > 0 ? nal[hoff] : nal[0]
      if (
        (hb === 0x40 || hb === 0x42 || hb === 0x44) &&
        hoff + 1 < nal.length && (nal[hoff + 1] & 0xf8) === 0x08
      ) {
        videoCodec = 'h265'
        cachedVps = cachedSps = cachedPps = null
        console.error('[webserver] video codec corrected: h265 (HEVC config NAL)')
        // Notify live clients so they rebuild their decoder for the new codec.
        try {
          const msg = JSON.stringify({ codec: 'h265' })
          const msgBuf = Buffer.from(msg, 'utf8')
          for (const s of [...h264Clients]) {
            s.write(Buffer.concat([Buffer.from([0x81, msgBuf.length]), msgBuf]))
          }
        } catch { /* ignore */ }
      }
      if (type === 7) cachedSps = nal
      else if (type === 8) cachedPps = nal
    }
    videoNalsSent++
    sendNalToClients(nal)
  }
  function sendCachedConfig(sock: net.Socket): void {
    // Send codec as text message first, then config NALs
    try {
      const msg = JSON.stringify({ codec: videoCodec })
      const msgBuf = Buffer.from(msg, 'utf8')
      const header = Buffer.from([0x81, msgBuf.length])
      sock.write(Buffer.concat([header, msgBuf]))
    } catch { /* ignore */ }
    if (cachedVps) wsSendBinary(sock, cachedVps)
    if (cachedSps) wsSendBinary(sock, cachedSps)
    if (cachedPps) wsSendBinary(sock, cachedPps)
  }
  function startH264Relay(): void {
    const sock = net.connect(opts.h264Port, '127.0.0.1')
    let buf = Buffer.alloc(0)
    const reconnect = () => { setTimeout(startH264Relay, 2000).unref?.() };
    sock.on('connect', () => { buf = Buffer.alloc(0) })
    sock.on('data', (chunk: Buffer) => {
      buf = Buffer.concat([buf, chunk])
      while (buf.length >= 4) {
        const len = buf.readUInt32BE(0)
        if (len > 8 * 1024 * 1024 || buf.length < 4 + len) break
        broadcastH264(buf.subarray(4, 4 + len))
        buf = buf.subarray(4 + len)
      }
    })
    sock.on('error', () => { /* reconnect below */ })
    sock.on('close', reconnect)
  }
  startH264Relay()
  // Fork: browser microphone uplink (PlayPort-style). The browser captures
  // mic via getUserMedia and sends wheelplay-format PCM frames (stream=-1)
  // as binary on /touch. We forward them via TCP to the Rust mic input
  // (micinput.rs) on 127.0.0.1:<micPort>, which feeds the phone's mic stream.
  let micSock: net.Socket | null = null
  function ensureMicSock(): net.Socket | null {
    if (micSock && !(micSock as any).destroyed) return micSock
    try {
      micSock = net.connect(opts.micPort, '127.0.0.1')
      micSock.on('error', () => { micSock = null })
      micSock.on('close', () => { micSock = null })
    } catch { micSock = null }
    return micSock
  }
  function forwardMic(frame: Buffer): void {
    // Validate wheelplay header: magic 0x31415057, stream=-1
    if (frame.length < 20) return
    if (frame.readUInt32LE(0) !== 0x31415057) return
    if (frame.readInt32LE(4) !== -1) return
    const sock = ensureMicSock()
    if (!sock) return
    const len = Buffer.alloc(4)
    len.writeUInt32BE(frame.length, 0)
    try { sock.write(Buffer.concat([len, frame])) } catch { /* ignore */ }
  }
  const server = http.createServer((req, res) => {
    const url = req.url || '/'
    if (url === '/' || url.startsWith('/?')) {
      let html: string
      try { html = fs.readFileSync(clientPath, 'utf8') } catch { html = FALLBACK_PAGE }
      // Fork: aggressive no-cache to ensure car browsers always get the latest page
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        'Pragma': 'no-cache',
        'Expires': '0',
      })
      res.end(html)
      return
    }
    if (url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({
        video: opts.isVideoReady() ? 'live' : 'waiting',
        mode: process.env.MACPLAY_NO_DECODE === '1' ? 'zero-transcode' : 'passthrough',
        codec: videoCodec,
        httpsPort: opts.httpsPort,
      }))
      return
    }
    if (url === '/mjpeg') {
      // Fork: proxy the Rust GStreamer websink (internal stream).
      // The pipeline taps decoded frames directly via MACPLAY_WEB_PORT,
      // no external screencapture needed.
      const proxy = http.get(
        { host: '127.0.0.1', port: opts.mjpegPort, path: '/mjpeg' },
        (pres) => {
          if (pres.statusCode !== 200) {
            res.writeHead(502); res.end('mjpeg upstream not ready'); pres.resume(); return
          }
          res.writeHead(200, {
            'Content-Type': pres.headers['content-type'] || 'multipart/x-mixed-replace; boundary=macplaymjpeg',
            'Cache-Control': 'no-cache',
            Connection: 'close',
          })
          pres.pipe(res)
        },
      )
      proxy.on('error', () => {
        if (!res.headersSent) { res.writeHead(503, { 'Retry-After': '2' }); res.end('video not ready, retrying') }
        else { try { res.end() } catch { /* ignore */ } }
      })
      return
    }
    res.writeHead(404); res.end('not found')
  })

  server.on('upgrade', (req, socket) => {
    const url = req.url || ''
    if (url !== '/touch' && url !== '/h264') { socket.destroy(); return }
    const key = req.headers['sec-websocket-key']
    if (typeof key !== 'string') { socket.destroy(); return }
    // The upgrade socket is a connected TCP socket at runtime.
    const sock = socket as unknown as net.Socket
    // Fork (weak-network): Nagle batching adds up to 40ms per small write;
    // touch and audio frames are latency-critical. Also applies to the video
    // relay's config/status text frames.
    sock.setNoDelay(true)
    sock.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${wsAccept(key)}\r\n\r\n`,
    )
    if (url === '/h264') {
      // Video-only: browser WebCodecs client. No input on this socket.
      h264Clients.add(sock)
      wsTrackDrain(sock)
      // Fork: send cached SPS/PPS to the new client so it can configure
      // its decoder immediately (it connected after the Rust forwarder
      // already sent config to Node).
      sendCachedConfig(sock)
      const remove = () => { h264Clients.delete(sock); try { sock.destroy() } catch { /* ignore */ } }
      sock.on('error', remove)
      sock.on('close', remove)
      // Drain any incoming data (client shouldn't send, but don't break).
      sock.on('data', () => {})
      return
    }
    wsClients.add(sock)
    notifyBrowserClients()
    wsTrackDrain(sock)
    // Fork: inbound-activity timestamp for the dead-connection sweeper below.
    ;(sock as any).lastSeen = Date.now()
    const remove = () => {
      if (!wsClients.delete(sock)) return
      try { sock.destroy() } catch { /* ignore */ }
      notifyBrowserClients()
    }
    const parser = new WsParser(
      sock,
      (text) => {
        ;(sock as any).lastSeen = Date.now()
        if (text.includes('"ping"')) { wsSendText(sock, JSON.stringify({ t: 'pong' })); return }
        handleTouchMessage(text, optsWithCodec, sock)
      },
      (bin) => { (sock as any).lastSeen = Date.now(); forwardMic(bin) },
      remove,
    )
    // Fork: any inbound byte counts as life — the auto-pong (0x8A) answers our
    // protocol ping without the page's JS ever running.
    sock.on('data', (c: Buffer) => { ;(sock as any).lastSeen = Date.now(); parser.feed(c) })
    sock.on('error', remove)
    sock.on('close', remove)
  })

  // Fork: dead-connection sweeper. A car browser that vanished without a TCP
  // close (screen off, WiFi drop) lingers in wsClients forever and keeps
  // browserClientCount()>0 — freezing the audio-follow/HID state. Probe every
  // 20s; a live client answers {t:'pong'} (refreshing lastSeen); 45s of
  // silence means the socket is a half-open zombie — destroy it. 90s because
  // Safari App Nap throttles background tabs well past 45s.
  setInterval(() => {
    for (const sock of [...wsClients]) {
      if ((sock as any).destroyed) { wsClients.delete(sock); continue }
      if (Date.now() - ((sock as any).lastSeen ?? 0) > 90000) {
        console.log('[webserver] stale touch client dropped (no pong)')
        try { sock.destroy() } catch { /* ignore */ }
        continue
      }
      wsSendPing(sock)
    }
  }, 20000).unref?.()

  // Fork: HTTPS for WebCodecs (requires secure context). Self-signed cert
  // generated once via openssl, stored in certDir. The car browser will show
  // a cert warning on first visit — accept it once.
  function ensureCert(): { key: Buffer; cert: Buffer } | null {
    const keyPath = path.join(opts.certDir, 'webserver.key')
    const certPath = path.join(opts.certDir, 'webserver.crt')
    try {
      if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
        return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) }
      }
      fs.mkdirSync(opts.certDir, { recursive: true })
      execFileSync('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', keyPath, '-out', certPath,
        '-days', '825', '-subj', '/CN=MacPlay-CarBrowser',
        '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
      ], { stdio: 'ignore' })
      return { key: fs.readFileSync(keyPath), cert: fs.readFileSync(certPath) }
    } catch (e) {
      console.error(`[webserver] HTTPS cert generation failed: ${e}`)
      return null
    }
  }

  const tlsCert = ensureCert()
  let httpsServer: https.Server | null = null
  if (tlsCert) {
    // Reuse the same request/upgrade handlers for HTTPS.
    httpsServer = https.createServer(
      { key: tlsCert.key, cert: tlsCert.cert },
      (req, res) => server.emit('request', req, res) as unknown as void,
    )
    httpsServer.on('upgrade', (req, socket, head) =>
      server.emit('upgrade', req, socket, head) as unknown as void,
    )
    httpsServer.on('clientError', (err: any, socket: net.Socket) => {
      socket.destroy(err)
    })
    httpsServer.listen(opts.httpsPort, '0.0.0.0', () => {
      console.error(
        `[webserver] WebCodecs (HTTPS) -> https://<mac-lan-ip>:${opts.httpsPort}/`,
      )
    })
  } else {
    console.error('[webserver] HTTPS disabled (no cert); WebCodecs mode unavailable')
  }

  server.on('clientError', (err: any, socket: net.Socket) => {
    socket.destroy(err)
  })
  server.listen(opts.httpPort, '0.0.0.0', () => {
    console.error(
      `[webserver] car browser (HTTP) -> http://<mac-lan-ip>:${opts.httpPort}/`,
    )
  })
  // Fork: let the host check how many browser clients are attached (used to
  // decide the audio session's initial state: no browser = paused).
  ;(server as unknown as { browserClientCount: () => number }).browserClientCount =
    () => wsClients.size
  return server
}
