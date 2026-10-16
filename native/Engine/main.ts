import { Discovery } from './discovery'
import fs from 'node:fs'
import path from 'node:path'
import net from 'node:net'
import { spawn, type ChildProcess } from 'node:child_process'
import readline from 'node:readline'
import { CpStack } from './protocol/cpStack'
import { loadOrCreateIdentity, accessoryDeviceId } from './protocol/identity'
import { CpHelperSock } from './CpHelperSock'
import { dataDir } from './storage'
import { addon, setVideoCallback, pollVideoReady, showVideoWindow } from './media'
import { displayConfig } from './display'
import { FrameRateFallback, VideoWaitDeadline } from './frameRateFallback'
import { acceptsPhone } from './phoneSelection'
import { audioLevel, disconnectedAfterSession } from './runtimeControls'
import { startWebServer } from './webserver'

const resources=process.env.MACPLAY_RESOURCES!
const settings=JSON.parse(fs.readFileSync(process.env.MACPLAY_SETTINGS_PATH || path.join(dataDir,'settings.json'),'utf8'))
// Sizzle hunt (resolved in 8919): the engine can archive its merged PCM
// (first ~2 min per run) for offline diffing — off by default now that the
// root cause is fixed; set MACPLAY_AUDIO_DUMP=<path> to re-enable.
const attempt=process.env.MACPLAY_ATTEMPT||'unknown',began=Date.now()
const diagnostic=(stage:string,detail:unknown='')=>console.log(JSON.stringify({attempt,elapsedMs:Date.now()-began,stage,detail}))
const log=(status:string,detail:string='')=>{diagnostic(status,detail);process.stdout.write(JSON.stringify({status,detail})+'\n')}
let discovery:Discovery|undefined
let handoffStarted=false,networkConnected=false
let disconnectReason='连接已断开'
const videoDeadline=new VideoWaitDeadline(settings.fps>=90?25000:45000,()=>{
 if(!videoReady&&!stopping){disconnectReason=sessionReady?'CarPlay视频连接超时':'iPhone网络连接超时';diagnostic('handoff-summary',discovery?.summary());log(disconnectReason);process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}
})
const armDeadline=()=>{if(!videoReady)videoDeadline.arm()}

const usb=(usbStatus:string,usbError:string='')=>process.stdout.write(JSON.stringify({usbStatus,usbError})+'\n')
diagnostic('starting',{wireless:settings.wireless,interface:settings.wifiInterface,channel:settings.channel,width:settings.width,height:settings.height,fps:settings.fps})
const identity=loadOrCreateIdentity()
// Fork: no OEM icon on the CarPlay homescreen. Upstream loaded macplay-256/512.png
// here and declared them via oemIconVisible/oemIcons in iAP2 identification; the
// icon's only function was opening the MacPlay window from CarPlay, which the
// browser-client setup doesn't need. To restore: load the PNGs as upstream did.
const icons:{widthPixels:number;heightPixels:number;data:Buffer}[]=[256,512].map(size=>({widthPixels:size,heightPixels:size,data:fs.readFileSync(path.join(resources,'icons',`nio-${size}.png`))}))
const helperControl=new CpHelperSock()
const config={deviceName:'NIO Play',deviceId:accessoryDeviceId(identity.pubRaw),btMac:settings.bluetoothMAC||'02:4d:50:00:00:02',sourceVersion:'950.7.1',hevc:settings.webCodec?settings.webCodec!=='h264':true,h264:true,main:displayConfig(settings),port:17000,entertainmentSampleRate:48000 as const,
 // Fork: audio ALWAYS advertised to the iPhone — the browser streaming mode is
 // the point, and where the sound plays is handled downstream (browser PCM or a
 // media-key pause when no browser is attached). With disableAudioOutput=true
 // the /info response omits audioFormats, the phone never opens an audio
 // stream (audioPackets stayed 0) and keeps playing on its own speaker.
 disableAudioOutput:false,audioVolume:(type:number)=>type===2 ? settings.callVolume??1 : type===3 ? settings.volume??1 : 1,audioDevice:()=>settings.outputDevice||undefined,audioInputDevice:()=>settings.inputDevice||undefined,mfi:helperControl,oemLabel:'NIO Play',icons,rightHandDrive:false}
const sessions=new Set<CpStack>()
let active: CpStack|undefined
let wiredReady=false
// Fork: toggling cellular data or flipping low-power-mode re-enumerates the
// iPhone's USB composite device — usbmuxd reports "unplugged" even though the
// phone re-attaches within ~100ms and CarPlay re-establishes on its own
// (carkit up → iAP2 → session in ~3s). Shutting down on that line killed the
// receiver for a bounce the user never caused. Treat the unplug as final only
// if the device does NOT return within this grace window.
let wiredReplugTimer:ReturnType<typeof setTimeout>|undefined
let videoReady=false
let sessionReady=false
let phoneInfo: {name:string;deviceId:string}|undefined
const frameRateGuard=new FrameRateFallback(settings.fps,fps=>{
 if(stopping||videoReady)return
 process.stdout.write(JSON.stringify({fallbackFps:String(fps),status:`${settings.fps}fps协商未启动视频，改用${fps}fps重连`,detail:"将自动降低帧率请求并重新连接。"})+"\n")
})
addon.macplaySelectDisplayOptions(settings.displayID||0)
addon.macplaySetWindowLanguage(process.env.MACPLAY_LANGUAGE||'system')
addon.macplayConfigureWindowOptions(settings.width,settings.height,settings.screenPixelWidth,settings.screenPixelHeight,settings.resolution==='native',settings.strictPixels===true)
setVideoCallback(()=>{frameRateGuard.videoStarted();videoDeadline.cancel();disarmStartupDeadline();const firstVideo = !videoReady;videoReady=true;if(firstVideo&&process.env.MACPLAY_HEADLESS!=='1')process.stdout.write(JSON.stringify({showCarPlay:true})+'\n');if(phoneInfo?.deviceId){settings.targetBluetooth=phoneInfo.deviceId.replace(/-/g,':').toLowerCase();process.stdout.write(JSON.stringify({connectedPhone:phoneInfo.deviceId,phoneName:phoneInfo.name,connectedUSB:settings.wireless?'':settings.targetUSB||''})+'\n');}log('CarPlay已连接','首帧已解码，CarPlay画面窗口已打开');if(wiredReady)usb('已接收CarPlay视频，画面窗口已打开')},settings.width/settings.height)
const authDir=path.join(dataDir,'authentication')
if (!fs.existsSync(path.join(authDir,'identity.pk8')) || !fs.existsSync(path.join(authDir,'certificate.p7b'))) {
 log('缺少认证文件','请在关于页面打开认证目录，放入有使用权限的配套文件。');process.exit(2)
}
const helper=spawn(path.join(resources,'driver/livi-helperd'),[],{env:{...process.env,MACPLAY_AUTH_DIR:authDir,MACPLAY_WIFI_SSID:settings.ssid||'',MACPLAY_EXTERNAL_DISCOVERY:settings.wireless?'1':'0',LIVI_CP_NAME:'NIO ET5',MACPLAY_SERIAL:'MACPLAY-'+identity.pairingId.toUpperCase(),LIVI_CP_DEVICE_ID:config.deviceId,LIVI_CP_AP_MAC:settings.wireless ? settings.accessPointMAC||'' : '',LIVI_CP_BT_MAC:config.btMac,LIVI_CP_PK:identity.pkHex,LIVI_CP_PI:identity.pairingId,LIVI_CP_AIRPLAY_PORT:'17000',LIVI_CP_WIRELESS:settings.wireless?'1':'0',LIVI_WIFI_IFACE:settings.wifiInterface||'en0',MACPLAY_TARGET_BT:settings.targetBluetooth||'',MACPLAY_TARGET_USB:settings.targetUSB||'',LIVI_PASSPHRASE:settings.password||'',LIVI_CHANNEL:String(settings.channel||36),MACPLAY_WEB_PORT:process.env.MACPLAY_WEB_PORT||'18081',MACPLAY_H264_PORT:process.env.MACPLAY_H264_PORT||'18083',MACPLAY_NO_DECODE:process.env.MACPLAY_NO_DECODE||'',MACPLAY_HEADLESS:process.env.MACPLAY_HEADLESS||''},stdio:['ignore','pipe','pipe']})
for(const stream of [helper.stdout,helper.stderr]) readline.createInterface({input:stream!}).on('line',line=>{
 console.error(line)
 if(!videoReady && line.includes('Bluetooth SDP timed out')) log('蓝牙握手未完成','请在iPhone蓝牙页面与Mac完成配对，并确认两端配对码。')
 if(!videoReady && line.includes('Bluetooth RFCOMM timed out')) log('蓝牙重连超时','正在刷新iPhone服务信息，请保持iPhone蓝牙开启。')
 if(!videoReady && /failed|unavailable|error|refused|needs the shared/i.test(line) && !line.includes('iAP2 already runs over USB carkit')) log('连接需要检查',line)
 if(!videoReady && line.includes('MFi auth succeeded')) log('配件认证已通过','正在协商CarPlay连接')
 if(!videoReady && line.includes('CarPlayStartSession sent')) {handoffStarted=true;discovery?.announce();diagnostic('network-handoff-started');frameRateGuard.negotiationStarted();armDeadline();log('已发送连接参数','等待iPhone连接接收端')}
 if(line.includes('usbmuxd carkit up')) {if(wiredReplugTimer){clearTimeout(wiredReplugTimer);wiredReplugTimer=undefined;log('iPhone已恢复','等待CarPlay自动重连')}wiredReady=true;armStartupDeadline();usb('USB通信已建立，正在识别配件')}
 if(line.includes('wired: identification accepted')) usb('iPhone已接受配件识别')
 if(line.includes('wired: MFi auth succeeded')) usb('配件认证已通过，正在建立CarPlay会话')
 if(line.includes('wired: CarPlayStartSession sent')) usb('已发送CarPlay连接参数')
 if(line.includes('usbmuxd carkit failed')) usb('USB通信失败','无法打开iPhone的CarPlay服务，请解锁并确认信任后重新连接。')
 if(line.includes('unplugged')) {const hadWired=wiredReady;wiredReady=false;usb('iPhone已拔出');
  // Fork: cellular/low-power toggles bounce USB for ~100ms — keep the engine
  // alive for the re-plug; only a device that stays gone stops the receiver.
  if(!settings.wireless && hadWired && (videoReady||sessionReady)){
   if(wiredReplugTimer)clearTimeout(wiredReplugTimer)
   wiredReplugTimer=setTimeout(()=>{wiredReplugTimer=undefined;if(!wiredReady){process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}},5000)
  }}
})
helper.on('error',e=>log('连接后端启动失败',e.message))
helper.on('exit',code=>{if(!stopping){log('连接后端已退出',String(code));process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}})
// Fork: settings.json path for the web client's display changes (declared before
// the server below so the display-persist closure can reference it).
const settingsFile = process.env.MACPLAY_SETTINGS_PATH || path.join(dataDir,'settings.json')
// Fork: a browser-driven display change drops the live session by design; the
// phone is expected to reconnect and renegotiate at the new resolution. Track
// it so session-ended restarts the wait instead of shutting the engine down
// (without this the receiver dies mid-session — 画面卡死 — and the phone
// falls back to its own speaker).
let displayRestartPending=false
const server=net.createServer(socket=>{
 networkConnected=true;armStartupDeadline();discovery?.networkConnected();
 socket.once('close',()=>{if(!active&&!stopping){networkConnected=false;discovery?.announce()}})
 const usbSession=wiredReady && !socket.remoteAddress?.endsWith('%'+settings.wifiInterface)
 diagnostic('control-connected',{family:socket.remoteFamily});if(!videoReady)log('收到连接请求','正在协商认证与音视频')
 const stack=new CpStack(config);sessions.add(stack)
 // Fork: persist web-requested display/codec changes so an engine restart keeps them,
 // and apply them to the live in-memory config so the NEXT session (the phone
 // reconnects after the drop) negotiates the new resolution natively.
 stack.onDisplayChange=cfg=>{
  // Fork: veto the LIVE switch on wired USB — the phone never reconnects after
  // a dropped wired session. Still persist the change: the new resolution
  // applies at the next receiver start ("saved for next time", not a fake
  // success). Wireless sessions persist AND apply live (the phone returns).
  const wired=!!usbSession
  if(wired)log('有线连接不在线切换分辨率','新分辨率已保存，重新启动接收后生效')
  try{
   const cur=JSON.parse(fs.readFileSync(settingsFile,'utf8'))
   cur.width=cfg.width;cur.height=cfg.height;cur.fps=cfg.fps;cur.webCodec=cfg.codec
   fs.writeFileSync(settingsFile, JSON.stringify(cur,null,2))
  }catch(e){console.error('[engine] persist display settings failed:',(e as Error).message)}
  if(wired)return false
  try{
   settings.width=cfg.width;settings.height=cfg.height;settings.fps=cfg.fps
   config.main=displayConfig(settings)
   config.hevc=cfg.codec!=='h264'
  }catch(e){console.error('[engine] apply display settings failed:',(e as Error).message)}
  displayRestartPending=true
 }
 stack.deviceFilter=id=>acceptsPhone(settings.targetBluetooth,id,!!active && active!==stack)
 stack.on('device-info',(info:{name:string;deviceId:string})=>{active=stack;phoneInfo=info})
 stack.setVideoActive(true);stack.setAudioActive(settings.audioEnabled!==false&&browserClientCount()>0)
 stack.on('session-active',()=>{sessionReady=true;frameRateGuard.negotiationStarted();armDeadline();stack.setStreamVolume(3,settings.volume??1,0);stack.setStreamVolume(2,settings.callVolume??1,0);if(!videoReady)log('CarPlay会话已建立','等待视频流');if(usbSession)usb('CarPlay会话已建立，等待视频流');syncSleepAssertion();
  // Fork: session may come up with no browser attached (audio starts into
  // nowhere) — pause the phone once the HID channel is ready. Conversely,
  // after a resolution renegotiation (or a fresh session with the browser
  // already open) resume playback so audio follows the display seamlessly.
  if(browserClientCount()===0)setTimeout(()=>{if(browserClientCount()===0){try{stack.sendMedia(2)}catch{}}},1500)
  else if(settings.audioEnabled!==false&&settings.autoResumeOnBrowser!==false)setTimeout(()=>{
   if(browserClientCount()===0)return
   // Fork: after a USB re-enumeration (cellular-data toggle / low-power-mode
   // flip bounces the iPhone's USB composite device) the phone can come back
   // "playing" but never re-SETUP the audio stream in the new session — a bare
   // Play is a no-op while already playing. Only when the session still has no
   // audio stream, toggle pause→play to force the audio re-route (same effect
   // as replugging a Bluetooth headphone). A healthy session has its streams
   // within ~1s and is left untouched.
   if(stack.audioStreamCount>0)return
   try{stack.sendMedia(2)}catch{}
   setTimeout(()=>{try{stack.sendMedia(1)}catch{}},200)
  },2500)})
 stack.on('disconnect-reason',(reason:string)=>{disconnectReason=reason})
 stack.on('session-ended',()=>{const hadVideo=videoReady;frameRateGuard.failed();sessions.delete(stack);if(active===stack){active=undefined;videoReady=false;sessionReady=false;syncSleepAssertion();
  // Fork: a browser-driven display change intentionally drops the session so
  // the phone renegotiates at the new resolution. Stay alive and let it
  // reconnect — shutting down here killed the receiver mid-use (画面卡死)
  // and pushed audio back to the iPhone speaker.
  if(displayRestartPending&&!stopping&&hadVideo){displayRestartPending=false;log('正在应用新的显示分辨率','等待iPhone重新连接…');if(usbSession)usb('分辨率已更新，等待iPhone自动重连');return}
  // Fork: a USB re-enumeration bounce (cellular/low-power toggle) tears the
  // session down but the phone re-attaches within the unplug grace window —
  // hold the receiver open and let carkit up re-arm it, like displayRestart.
  if(wiredReplugTimer&&!stopping&&hadVideo){log('USB重新枚举中','等待iPhone恢复连接…');if(usbSession)usb('USB重新枚举中，等待iPhone恢复连接');return}
  log(disconnectReason,'重新启动接收可再次连接');if(disconnectedAfterSession(hadVideo,stopping,settings.fps)){process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}}
  if(usbSession)usb('CarPlay会话已断开，可点击“应用并重新连接”')})
 stack.on('host-ui-requested',()=>{process.stdout.write(JSON.stringify({showMain:true})+'\n');diagnostic('show-main')})
 stack.on('error',(e:Error)=>{diagnostic('session-error',e.message);if(!videoReady)log('会话错误',e.message)})
 stack.attachSocket(socket)
})
server.on('error',e=>{log('接收服务启动失败',e.message);shutdown()})
server.listen({port:17000,host:'::',ipv6Only:false},()=>{
 if(settings.wireless)discovery=new Discovery(settings.wifiInterface||'en0',{deviceId:config.deviceId,pk:identity.pkHex,pi:identity.pairingId,btMac:config.btMac},settings.targetBluetooth||'',()=>handoffStarted&&!networkConnected&&!stopping,s=>diagnostic('network-discovery',s))
 // Fork: with no phone attached yet the running engine IS the web service —
 // frame the idle state that way instead of a pending CarPlay failure, so
 // starting the receiver without a cable is a usable state (browser streaming
 // works immediately). CarPlay begins automatically on phone contact.
 log('Web 服务已就绪',settings.wireless?'iPhone通过蓝牙配对并接入共用Wi-Fi后自动开始CarPlay。':'iPhone插入USB数据线后自动开始CarPlay。')
})
// Fork: browser re-stream for the car head-unit browser over LAN.
// Serves the touch-enabled client on 0.0.0.0:<httpPort> (MJPEG fallback) and
// 0.0.0.0:<httpsPort> (WebCodecs H.264 passthrough, zero-transcode).
// Proxies video from the Rust helper's web taps (127.0.0.1:<mjpegPort> and
// 127.0.0.1:<h264Port>).
// Env overrides: MACPLAY_WEB_HTTP_PORT (default 8080),
// MACPLAY_WEB_HTTPS_PORT (default 8443), MACPLAY_WEB_PORT (default 18081),
// MACPLAY_H264_PORT (default 18083).
// Fork: web streaming is always on in this fork. The Rust pipelines (video AND
// audio) run inside THIS Node process via the livi-gst-video addon, so the env
// vars must be set here — passing them only to the livi-helperd child (below)
// does nothing for pipeline_desc(), which reads them at pipeline build time.
process.env.MACPLAY_WEB_PORT ||= '18081'
process.env.MACPLAY_WEB_AUDIO_PORT ||= '18082'
process.env.MACPLAY_H264_PORT ||= '18083'
// Fork: settings.json mjpegFallback=false (default true) kills the MJPEG
// fallback branch entirely — pipeline_desc() skips the always-on software
// convert+scale+jpeg-encode tail and the receiver saves the CPU.
if (settings.mjpegFallback === false) process.env.MACPLAY_WEB_NO_MJPEG = '1'
process.env.MACPLAY_MIC_PORT ||= '18084'
// Fork: MJPEG via GStreamer internal stream (websink).
// The pipeline taps decoded frames directly (MACPLAY_WEB_PORT mode),
// no external screencapture needed.
const webServer=startWebServer({
  httpPort:Number(process.env.MACPLAY_WEB_HTTP_PORT||'8080'),
  httpsPort:Number(process.env.MACPLAY_WEB_HTTPS_PORT||'8443'),
  mjpegPort:Number(process.env.MACPLAY_WEB_PORT||'18081'),
  audioPort:Number(process.env.MACPLAY_WEB_AUDIO_PORT||'18082'),
  h264Port:Number(process.env.MACPLAY_H264_PORT||'18083'),
  micPort:Number(process.env.MACPLAY_MIC_PORT||'18084'),
  certDir:path.join(dataDir,'certs'),
  // Fork: gst_video addon for the /rtc WebRTC signaling channel.
  rtcAddon:()=>addon,
  getStack:()=>active,
  isVideoReady:()=>videoReady,
  // Fork: the browser device IS the audio output — the Mac never plays
  // locally. The audio session tracks /touch clients: no browser anywhere =
  // no audio route for the iPhone = playback pauses (like a disconnected
  // Bluetooth headphone); whichever device opens a browser gets the sound.
  // Fork: display switching only works on wireless (wired sessions veto it).
  displaySwitchable:()=>!!settings.wireless,
  onBrowserClients:(connected)=>{
    // Fork: setAudioActive is the LOCAL forwarding gate (appsink on/off), pure
    // local state with no protocol side effects. The session starts with the
    // gate closed (no browser yet); without reopening it here every packet stays
    // gated (forwarded:0) and the browser never gets audio. The TEARDOWN seen
    // on pause is the phone's own behavior, not caused by this gate.
    for(const stack of sessions){try{stack.setAudioActive(connected)}catch(e){console.error('[audio-route]',e)}}
    // Pause/resume via CarPlay media HID keys: 1=Play 0xB0, 2=Pause 0xB1.
    // Leaving always pauses; on attach we only auto-resume when the user
    // hasn't opted to respect a manual pause (设置：打开浏览器时自动恢复播放).
    try{
      if(!connected)active?.sendMedia(2)
      else if(settings.autoResumeOnBrowser!==false)active?.sendMedia(1)
    }catch(e){console.error('[audio-key]',e)}
  },
  // Fork: /mjpeg proxies the Rust GStreamer websink (internal stream).
  // No getScreenFrame = use internal pipeline, not external screencapture.
})
const browserClientCount=():number=>{try{return (webServer as unknown as {browserClientCount?:()=>number}).browserClientCount?.()??0}catch{return 0}}
// Fork: optional no-sleep while CarPlay is connected
// (settings: preventSleepWhenConnected, toggled in the app's settings UI).
// Holds a `caffeinate -s` assertion: PreventSystemSleep, which also covers
// lid-closed operation while on AC power. Display sleep is unaffected
// (deliberately no -d): closing the lid just turns the display off.
let sleepBlocker: ChildProcess | undefined
function sleepSettingOn(): boolean {
  try {
    return JSON.parse(fs.readFileSync(settingsFile,'utf8')).preventSleepWhenConnected === true
  } catch { return false }
}
function syncSleepAssertion(): void {
  const want = !stopping && sleepSettingOn() && (videoReady || sessionReady)
  if (want && !sleepBlocker) {
    try {
      sleepBlocker = spawn('caffeinate', ['-s'], {stdio:'ignore'})
      sleepBlocker.on('error', ()=>{ sleepBlocker=undefined })
      sleepBlocker.on('exit', ()=>{ sleepBlocker=undefined })
      diagnostic('sleep-assertion-on')
    } catch { sleepBlocker = undefined }
  } else if (!want && sleepBlocker) {
    try { sleepBlocker.kill() } catch {}
    sleepBlocker = undefined
    diagnostic('sleep-assertion-off')
  }
}
let sleepWatchTimer: NodeJS.Timeout | undefined
// Fork (headless): mirror the `headless` setting into the env so the Rust
// video pipeline (fakesink) and media.ts (no window) pick it up. Re-read on
// every settings change; takes effect on the next video session.
function syncHeadlessEnv(): void {
  try {
    const s=JSON.parse(fs.readFileSync(settingsFile,'utf8'))
    if (s.headless === true) process.env.MACPLAY_HEADLESS='1'
    else delete process.env.MACPLAY_HEADLESS
    // Fork (M1): zero-transcode mode — skip video decode entirely.
    // Requires headless + WebCodecs browser; no MJPEG fallback.
    if (s.zeroTranscode === true) process.env.MACPLAY_NO_DECODE='1'
    else delete process.env.MACPLAY_NO_DECODE
  } catch {}
}
syncHeadlessEnv()
try {
  // Pick up the toggle being flipped while connected, without an Engine restart.
  fs.watch(settingsFile, (event) => {
    if (event !== 'change') return
    clearTimeout(sleepWatchTimer)
    sleepWatchTimer = setTimeout(()=>{syncSleepAssertion();syncHeadlessEnv()}, 500)
  })
} catch { /* settings file may not exist yet */ }
let mediaTicks=0,lastCounts=[0,0]
const mediaStats=setInterval(()=>{
 const counts:number[]=addon.mediaActivity();mediaTicks++
 if(counts[0]>0 && lastCounts[0]===0){
   diagnostic('first-video-packet')
   // Fork: in headless/zero-transcode mode, video packets arriving means
   // the stream is live (no local decode to wait for). Mark video ready
   // to avoid the connection timeout.
   if(!videoReady && (process.env.MACPLAY_HEADLESS==='1' || process.env.MACPLAY_NO_DECODE==='1')){
     videoReady=true
     videoDeadline.cancel()
     frameRateGuard.videoStarted()
     log('CarPlay已连接','视频流已接收（无头模式，转发到浏览器）')
   }
 }
 if(counts[1]>0 && lastCounts[1]===0)diagnostic('first-audio-packet')
 if(mediaTicks%30===0){diagnostic('media-statistics',{videoPackets:counts[0],audioPackets:counts[1]});diagnostic('audio-statistics',JSON.parse(addon.audioStatistics()))}
 lastCounts=counts
},1000)
const pump=setInterval(()=>{
 try {
  pollVideoReady()
  const events:number[]=addon.macplayPumpEvents()
  for(let i=0;i<events.length;i+=3)active?.sendTouches([{x:events[i],y:events[i+1],down:events[i+2]===1,id:0}])
  if(addon.macplayTakeWindowAction()===1 && !stopping){process.stdout.write(JSON.stringify({disconnected:true,manual:true,reason:'主动断开连接'})+'\n');shutdown()}
 }catch(e){console.error(e)}
},8)
readline.createInterface({input:process.stdin}).on('line',line=>{
 if(line==='show'){if(videoReady)showVideoWindow();else log('等待CarPlay视频','视频尚未建立，暂不打开空白画面窗口。')}
 try {
  const update=JSON.parse(line)
  if(update.command==='language' && typeof update.language==='string')addon.macplaySetWindowLanguage(update.language)
  if(update.command==='seek' && active && videoReady && phoneInfo?.deviceId) {
   const ms=Number(update.positionMs),id=String(update.requestId||'')
   if(Number.isInteger(ms)&&ms>=0&&ms<=0xffffffff&&id) {
    helperControl.seekPlayback(phoneInfo.deviceId,ms,id,typeof update.trackId==='string'?update.trackId:undefined)
     .catch(()=>process.stdout.write(JSON.stringify({type:'seekResult',requestId:id,sent:false})+'\n'))
   }
  }
  if(update.command==='audio') {
   settings.volume=audioLevel(update.volume,settings.volume??1)
   settings.callVolume=audioLevel(update.callVolume,settings.callVolume??1)
   settings.audioEnabled=!!update.enabled
   for(const stack of sessions){stack.setStreamVolume(3,settings.volume,0);stack.setStreamVolume(2,settings.callVolume,0);stack.setAudioActive(settings.audioEnabled&&browserClientCount()>0)}
  }
 } catch {}
 if(line.startsWith('media ')){const index=Number(line.slice(6));if(Number.isInteger(index)&&index>=1&&index<=5)active?.sendMedia(index)}
 if(line==='stop')shutdown()
})
// Fork: the 90s startup budget measures first phone contact → video, not engine
// start → video. Wired mode legitimately waits (indefinitely) for the USB cable;
// arming at engine start turned "please connect the USB cable" into a misleading
// 连接启动超时 after 90s (e.g. Mac on the iPhone hotspot while no cable is plugged).
let startupDeadline:ReturnType<typeof setTimeout>|undefined
let startupArmed=false
function armStartupDeadline(){
 if(startupArmed||videoReady||stopping)return
 startupArmed=true
 startupDeadline=setTimeout(()=>{if(!stopping&&!videoReady){disconnectReason='连接启动超时';diagnostic('handoff-summary',discovery?.summary());log(disconnectReason);process.stdout.write(JSON.stringify({disconnected:true,reason:disconnectReason})+'\n');shutdown()}},90000)
}
function disarmStartupDeadline(){if(startupDeadline){clearTimeout(startupDeadline);startupDeadline=undefined}startupArmed=false}
let stopping=false
function shutdown(){if(stopping)return;stopping=true;syncSleepAssertion();discovery?.destroy();clearTimeout(startupDeadline);videoDeadline.cancel();frameRateGuard.cancel();clearInterval(pump);clearInterval(mediaStats);for(const s of sessions)s.stop();addon.macplayCloseVideoWindow();server.close();helper.kill('SIGTERM');setTimeout(()=>process.exit(0),300).unref()}
process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);process.stdin.on('end',shutdown)
