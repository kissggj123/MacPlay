/**
 * webserver.ts — fork addition: browser re-stream for the car head-unit browser.
 *
 * HTTP on 0.0.0.0:<httpPort> (default 8080):
 *   GET /        touch-enabled MJPEG client page (native/Engine/webclient.html)
 *   GET /mjpeg   proxies the Rust helper's MJPEG (127.0.0.1:<mjpegPort>/mjpeg)
 *   GET /health  JSON status for the car browser / debugging
 * WebSocket /touch:
 *   -> {t:'touch', touches:[{x,y,down,id}]}  (x/y normalised 0..1)
 *      forwarded to CpStack.sendTouches(); multi-touch up to 2 contacts
 *   -> {t:'ping'}  answered with {t:'pong'}
 *
 * No new npm dependencies: node:http + node:crypto only. WebSocket is
 * hand-rolled (server-side, RFC 6455 minimal subset: text frames, ping/pong,
 * close; client frames are masked as required).
 */
import http from 'node:http'
import crypto from 'node:crypto'
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'

export interface TouchContact { x: number; y: number; down: boolean; id: number }
export interface TouchStack { sendTouches(c: TouchContact[]): void }
export interface WebServerOpts {
  httpPort: number
  mjpegPort: number
  getStack: () => TouchStack | undefined
  isVideoReady: () => boolean
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

/** Minimal client-frame parser: masked text, ping/pong, close. */
class WsParser {
  private buf = Buffer.alloc(0)
  readonly onClose: () => void
  constructor(
    private socket: net.Socket,
    private onMessage: (text: string) => void,
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
      // 0x0 continuation / 0x2 binary: not used by our client; ignore
    }
  }
}

function handleTouchMessage(raw: string, opts: WebServerOpts): void {
  let msg: any
  try { msg = JSON.parse(raw) } catch { return }
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
}

export function startWebServer(opts: WebServerOpts): http.Server {
  const clientPath = path.join(__dirname, 'webclient.html')
  const server = http.createServer((req, res) => {
    const url = req.url || '/'
    if (url === '/' || url.startsWith('/?')) {
      let html: string
      try { html = fs.readFileSync(clientPath, 'utf8') } catch { html = FALLBACK_PAGE }
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' })
      res.end(html)
      return
    }
    if (url === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ video: opts.isVideoReady() ? 'live' : 'waiting' }))
      return
    }
    if (url === '/mjpeg') {
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
    if (req.url !== '/touch') { socket.destroy(); return }
    const key = req.headers['sec-websocket-key']
    if (typeof key !== 'string') { socket.destroy(); return }
    // The upgrade socket is a connected TCP socket at runtime.
    const sock = socket as unknown as net.Socket
    sock.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${wsAccept(key)}\r\n\r\n`,
    )
    const parser = new WsParser(
      sock,
      (text) => {
        if (text.includes('"ping"')) { wsSendText(sock, JSON.stringify({ t: 'pong' })); return }
        handleTouchMessage(text, opts)
      },
      () => { try { sock.destroy() } catch { /* ignore */ } },
    )
    sock.on('data', (c: Buffer) => parser.feed(c))
    sock.on('error', () => { /* ignore */ })
  })

  server.listen(opts.httpPort, '0.0.0.0', () => {
    console.error(
      `[webserver] car browser -> http://<mac-lan-ip>:${opts.httpPort}/ ` +
      `(mjpeg proxied from 127.0.0.1:${opts.mjpegPort})`,
    )
  })
  return server
}
