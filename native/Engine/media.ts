import { waitForMicrophone } from './microphonePermission'
import fs from 'node:fs'
import path from 'node:path'
const root = process.env.MACPLAY_RESOURCES || path.resolve(__dirname, '../..')
const archDir = process.arch === 'x64' ? 'macos-x64' : 'macos-arm64'
let gst = path.join(root, 'gstreamer', archDir)
if (!fs.existsSync(gst)) {
  const armFallback = path.join(root, 'gstreamer/macos-arm64')
  if (fs.existsSync(armFallback)) {
    gst = armFallback
  } else {
    gst = path.join(root, 'gstreamer/macos')
  }
}
process.env.GST_PLUGIN_SYSTEM_PATH = ''
process.env.GST_PLUGIN_PATH = path.join(gst,'lib/gstreamer-1.0')
process.env.GST_PLUGIN_SCANNER = path.join(gst,'libexec/gstreamer-1.0/gst-plugin-scanner')
export const addon: any = require('livi-gst-video')
export const VIDEO_PLANE_MAIN = 1, VIDEO_PLANE_CLUSTER_RECV = 2
export type CpAudioCodec = 'aac-lc'|'opus'|'pcm'
export const gstHost: any = { onAudioStarted: () => {} }
let started: ((id:number,sample:number)=>void)|undefined
let windowHandle: Buffer | undefined
let player: any, aspect=16/9
let videoGeneration=0, firstFramePending=false, presented=false
const receivers=new Map<number,object>()
export let onVideo: (()=>void)|undefined
export function setVideoCallback(callback:()=>void, ratio:number) { onVideo=callback; aspect=ratio }
// Fork (headless): when MACPLAY_HEADLESS=1 the Rust pipeline uses fakesink
// (see codec sink_chain) and no native window is created or presented.
function headless(){ return process.env.MACPLAY_HEADLESS==='1' }
function noDecode(){ return process.env.MACPLAY_NO_DECODE==='1' }
export function openScreenReceiver(id:number,key:Buffer):number {
 const token={};receivers.set(id,token)
 return addon.openVideoReceiver(id,key,(codec:number,atom:Buffer)=>{
  if(receivers.get(id)!==token)return
  videoGeneration++;firstFramePending=true
  if(player) addon.stop(player)
  // Fork: zero-transcode mode uses the direct H.264 forwarder (h264direct),
  // no GStreamer pipeline needed at all.
  if(noDecode()){
    player=0
    return
  }
  // Fork: headless mode still creates the GStreamer pipeline (for H.264
  // parsing and web forwarding), but with no native window. The Rust
  // Player::new handles MACPLAY_NO_DECODE by skipping the decoder.
  const handle=headless()?Buffer.alloc(0):(windowHandle ?? (windowHandle=addon.macplayPrepareVideoWindow(aspect)))
  player=addon.createPlayer(codec===1?'h265':'h264',handle,atom,id)
  if(!player) throw new Error('无法创建CarPlay视频解码器')
  if(!headless()){ addon.start(player); addon.setContentRegion(player,0,0,aspect*1000,1000,aspect*1000,1000) }

 })
}
export function closeScreenReceiver(id:number) { receivers.delete(id);videoGeneration++;firstFramePending=false;presented=false; addon.closeVideoReceiver(id); if(player){addon.stop(player);player=null} if(!headless())addon.macplayCloseVideoWindow(); windowHandle=undefined }
export function onAudioReceiverStarted(cb:(id:number,sample:number)=>void) {started=cb}
export function openAudioReceiver(key:Buffer,o:any):any {
 return addon.openAudioReceiver(key,o.codec,o.payloadType,o.clockRate,o.channels,o.latencyMs,o.realtime,o.device,(id:number,sample:number)=>started?.(id,sample))
}
export function closeAudioReceiver(id:number) {addon.closeAudioReceiver(id)}
export function setAudioReceiverActive(id:number,active:boolean) {addon.setAudioReceiverActive(id,active)}
export function setAudioReceiverVolume(id:number,level:number,ms:number) {addon.setAudioReceiverVolume(id,level,ms)}
export async function openMicUplink(key:Buffer,o:any,current:()=>boolean):Promise<number|null> {
 if(!await waitForMicrophone(current,()=>addon.microphonePermission())) {
  if(current())console.warn('[cp_mic] microphone permission denied')
  return null
 }
 if(!current())return null
 return addon.openMicUplink(key,o.codec,o.payloadType,o.sampleRate,o.channels,o.bitrate,o.frameMs,o.port,o.phone,o.device)
}
export function closeMicUplink(id:number){addon.closeMicUplink(id)}

// Called from the main-thread event pump. Decoder buffers are observed on the
// decoder output pad, never inferred from codec configuration or TCP packets.
export function pollVideoReady() {
 if(!player||!firstFramePending)return
 const generation=videoGeneration, current=player
 const [width,height]:number[]=addon.decodedVideoSize(current)
 if(width<=0||height<=0||generation!==videoGeneration||current!==player)return
 firstFramePending=false;aspect=width/height
 addon.setContentRegion(player,0,0,width,height,width,height)
 if(headless()){/* no native window in headless mode */}
 else if(!presented){addon.macplayWindowHandle(aspect);presented=true}
 else addon.macplayPrepareVideoWindow(aspect)
 console.log(JSON.stringify({stage:'first-decoded-frame',width,height}))
 onVideo?.()
}

export function showVideoWindow(){if(presented&&player)addon.macplayWindowHandle(aspect)}
