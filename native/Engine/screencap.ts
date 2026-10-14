/**
 * screencap.ts — fork addition: screen-capture fallback for browser streaming.
 *
 * When the H.265/WebCodecs passthrough path can't be used (e.g. the iPhone
 * won't send video slices, or the car browser lacks WebCodecs), this module
 * captures the native CarPlay video window ("MacPlay · CarPlay") with the
 * macOS `screencapture` tool and serves the JPEGs as MJPEG.
 *
 * Trade-off vs passthrough: ~200-500ms latency, 8-12 fps, but works with any
 * browser that can display MJPEG (no WebCodecs needed) and doesn't depend on
 * the iPhone sending a clean H.265 stream.
 *
 * macOS only. No new npm dependencies: uses /usr/sbin/screencapture and
 * /usr/bin/osascript (both shipped with macOS).
 */

import { execFile } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const WINDOW_TITLE = 'MacPlay · CarPlay'
// Target ~10 fps; screencapture takes ~60-120ms per shot on Apple Silicon.
const CAPTURE_INTERVAL_MS = 100

let timer: NodeJS.Timeout | null = null
let latestFrame: Buffer | null = null
let windowId: number | null = null
let running = false
let tmpFile: string

function tmpPath(): string {
  return path.join(os.tmpdir(), `macplay-screencap-${process.pid}.jpg`)
}

/**
 * Find the CGWindowID of the CarPlay video window via AppleScript.
 * Returns null if not found (e.g. video not started yet).
 */
function findWindowId(): Promise<number | null> {
  return new Promise((resolve) => {
    const script = `
      tell application "System Events"
        try
          set p to first process whose name contains "MacPlay"
          set w to first window of p whose name is "${WINDOW_TITLE}"
          return id of w
        on error
          return 0
        end try
      end tell
    `
    execFile('/usr/bin/osascript', ['-e', script], { timeout: 5000 }, (err, stdout) => {
      if (err) { resolve(null); return }
      const id = parseInt(stdout.trim(), 10)
      resolve(Number.isFinite(id) && id > 0 ? id : null)
    })
  })
}

/**
 * Capture the window to a JPEG file. Resolves with the JPEG bytes,
 * or null on failure.
 */
function captureOnce(id: number): Promise<Buffer | null> {
  return new Promise((resolve) => {
    // -l <id>: capture window by CGWindowID
    // -x: no sound, -t jpg: JPEG format
    execFile('/usr/sbin/screencapture', ['-l', String(id), '-x', '-t', 'jpg', tmpFile], { timeout: 8000 }, (err) => {
      if (err) { resolve(null); return }
      fs.readFile(tmpFile, (readErr, data) => {
        if (readErr) { resolve(null); return }
        resolve(data)
      })
    })
  })
}

async function tick(): Promise<void> {
  if (!running) return
  try {
    // Re-resolve the window ID periodically (window may be recreated on reconnect).
    if (windowId === null) {
      windowId = await findWindowId()
      if (windowId === null) {
        // No video window yet; keep polling.
        return
      }
      console.error(`[screencap] found window "${WINDOW_TITLE}" id=${windowId}`)
    }
    const frame = await captureOnce(windowId)
    if (frame && frame.length > 1024) {
      latestFrame = frame
    } else {
      // Window may have closed; re-resolve next tick.
      windowId = null
    }
  } catch {
    // Ignore transient failures; keep the loop alive.
  }
}

/**
 * Start the screen-capture loop. Safe to call multiple times.
 */
export function startScreenCapture(): void {
  if (running) return
  if (process.platform !== 'darwin') {
    console.error('[screencap] only supported on macOS')
    return
  }
  running = true
  tmpFile = tmpPath()
  console.error('[screencap] starting capture loop (target ~10 fps)')
  const loop = async () => {
    if (!running) return
    await tick()
    if (running) timer = setTimeout(loop, CAPTURE_INTERVAL_MS)
  }
  loop()
}

/**
 * Stop the capture loop and clean up.
 */
export function stopScreenCapture(): void {
  running = false
  if (timer) { clearTimeout(timer); timer = null }
  latestFrame = null
  windowId = null
  try { fs.unlinkSync(tmpFile) } catch { /* ignore */ }
  console.error('[screencap] stopped')
}

/**
 * Return the most recent captured JPEG, or null if none yet.
 */
export function getLatestFrame(): Buffer | null {
  return latestFrame
}

/**
 * Whether the capture loop is active.
 */
export function isCapturing(): boolean {
  return running
}
