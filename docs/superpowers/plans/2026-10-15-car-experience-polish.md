# 车机体验优化第二轮 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** webclient.html 六项体验优化：渲染追帧丢弃、触控 rect 缓存、重连退避+toast、音量 OSD、RTT、音频全流自适应缓冲——全部带 HUD 度量。

**Architecture:** 单文件 `native/Engine/webclient.html` 改造。三个计数器（丢帧/欠载/RTT）在 Task 1 一次声明，HUD 输出一次扩展，后续任务只赋值。渲染改为「解码回调存 pendingFrame + rAF 循环画最新帧」。重连抽成 scheduleReconnect/kickReconnect 两函数，退避 2→5→10s 封顶。

**Tech Stack:** 原生 JS（ES5 风格保持一致）、WebCodecs VideoDecoder、WebAudio。验证用 node 提取 `<script>` 语法检查 + 浏览器手测。

**规格:** `docs/superpowers/specs/2026-10-15-car-experience-polish-design.md`

---

### Task 1: 渲染追帧丢弃 + HUD 计数器框架

**Files:**
- Modify: `native/Engine/webclient.html`（行 244-255 计数器与 updateHud；行 534-544 解码回调；行 556-560 startWebCodecs）

- [ ] **Step 1: 声明全局计数器（含后续任务用的 rttMs/audioUnderruns）**

在行 245 `var spsPps=null, frameCount=0, ...` 之后加：

```js
  var droppedFrames=0, rttMs=null, audioUnderruns=0;
```

- [ ] **Step 2: 扩展 updateHud 输出三计数器**

将 updateHud 中：

```js
    hud.textContent=mode+'\n'+fps+' fps  '+kbps+' kbps'+(extra?'\n'+extra:'');
```

替换为：

```js
    var stats='';
    if(droppedFrames>0) stats+='  丢帧'+droppedFrames;
    if(rttMs!==null) stats+='  '+rttMs+'ms';
    if(audioUnderruns>0) stats+='  欠载'+audioUnderruns;
    hud.textContent=mode+'\n'+fps+' fps  '+kbps+' kbps'+stats+(extra?'\n'+extra:'');
```

- [ ] **Step 3: 解码回调改 pendingFrame**

在 `var videoCodec='h264', ts=0;`（行 532）之前加：

```js
  // Spec (2026-10-15 round 2): decode-paced drawing makes recovery look like
  // fast-forward. Keep only the newest frame and paint on rAF instead.
  var pendingFrame=null, renderQueued=false;
  function dropPendingFrame(){ if(pendingFrame){ try{pendingFrame.close();}catch(e){} pendingFrame=null; } }
  function renderLoop(){
    renderQueued=false;
    if(!ctx2d) return;
    var frame=pendingFrame; if(!frame) return;
    pendingFrame=null;
    if(canvas.width!==frame.displayWidth||canvas.height!==frame.displayHeight){
      canvas.width=frame.displayWidth; canvas.height=frame.displayHeight;
    }
    ctx2d.drawImage(frame,0,0); frame.close();
    if(!imgShown){ imgShown=true; waiting.style.display='none'; }
  }
```

将 makeDecoder 的 output 回调：

```js
      output:function(frame){
        if(canvas.width!==frame.displayWidth||canvas.height!==frame.displayHeight){
          canvas.width=frame.displayWidth; canvas.height=frame.displayHeight;
        }
        ctx2d.drawImage(frame,0,0); frame.close();
        if(!imgShown){ imgShown=true; waiting.style.display='none'; }
        frameCount++;
        onFrameDecoded(); // Fork: PlayPort-style keyframe watchdog
      },
```

替换为：

```js
      output:function(frame){
        if(pendingFrame){ droppedFrames++; dropPendingFrame(); }
        pendingFrame=frame;
        if(!renderQueued){ renderQueued=true; requestAnimationFrame(renderLoop); }
        frameCount++;
        onFrameDecoded(); // Fork: PlayPort-style keyframe watchdog
      },
```

- [ ] **Step 4: 重配置路径清空 pendingFrame**

startWebCodecs 的重置行：

```js
    decoderConfigured=false; sawKeyAfterConfig=false; auBuf=[];
```

（仅 startWebCodecs 内这一处，行 559）替换为：

```js
    decoderConfigured=false; sawKeyAfterConfig=false; auBuf=[];
    dropPendingFrame();
```

同样在 codec 变更两处（`spsPps=null; decoderConfigured=false; sawKeyAfterConfig=false; auBuf=[];` 行 576 与 595 附近）末尾追加 ` dropPendingFrame();`。

- [ ] **Step 5: node 语法校验**

```bash
node -e "
const html=require('fs').readFileSync('native/Engine/webclient.html','utf8');
const scripts=[...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m=>m[1]).join('\n');
try{ new Function(scripts); console.log('JS syntax OK'); }catch(e){ console.log('ERROR: '+e.message); process.exit(1); }
"
```

Expected: `JS syntax OK`

- [ ] **Step 6: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(webclient): 渲染追帧丢弃——pendingFrame+rAF 永远画最新帧，HUD 加丢帧计数"
```

---

### Task 2: 触控 rect 缓存

**Files:**
- Modify: `native/Engine/webclient.html`（行 854-862 mapPoint 区域、onPointerDown/onPointerMove；applyMargins）

- [ ] **Step 1: 加缓存函数**

在 `function videoSize(){...}` 之后（行 868 附近）加：

```js
  // Spec: getBoundingClientRect forces layout; cache per element-size and
  // invalidate on resize / safe-margin changes.
  var rectCache={el:null,w:0,h:0,rect:null};
  function videoRect(el,w,h){
    if(!rectCache.rect||rectCache.el!==el||rectCache.w!==w||rectCache.h!==h){
      rectCache={el:el,w:w,h:h,rect:el.getBoundingClientRect()};
    }
    return rectCache.rect;
  }
```

- [ ] **Step 2: 两处调用点换用缓存**

onPointerDown 中：

```js
    var s=videoSize(), p=mapPoint(e.clientX,e.clientY,s.el.getBoundingClientRect(),s.w,s.h,false);
```

替换为：

```js
    var s=videoSize(), p=mapPoint(e.clientX,e.clientY,videoRect(s.el,s.w,s.h),s.w,s.h,false);
```

onPointerMove 中同样把 `s.el.getBoundingClientRect()` 换成 `videoRect(s.el,s.w,s.h)`。

- [ ] **Step 3: 失效点**

applyMargins() 末尾加：

```js
    rectCache.rect=null;
```

window resize 监听（放在 applyMargins() 调用之后）：

```js
  window.addEventListener('resize',function(){ rectCache.rect=null; });
```

- [ ] **Step 4: 确认 touch-action（防漏点）**

已确认 CSS 行 20/22/24 对 img/canvas 均有 `touch-action:none`，无需改动。此步仅验证：

```bash
grep -n "touch-action:none" native/Engine/webclient.html | head -4
```

Expected: 3 行命中。

- [ ] **Step 5: node 语法校验**（同 Task 1 Step 5）→ `JS syntax OK`

- [ ] **Step 6: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "perf(webclient): 触控 rect 缓存——resize/边距变更失效，move 不再每次强制布局"
```

---

### Task 3: 重连退避 + 回前台立即重连 + 横幅计数 + toast

**Files:**
- Modify: `native/Engine/webclient.html`（行 140 banner 标记；行 837-851 connect 区；行 631 h264ws.onclose）

- [ ] **Step 1: banner 文本包一层 span（可编程更新）**

行 140：

```html
<div id="banner"><span class="bdot"></span>连接已断开 · 重连中</div>
```

替换为：

```html
<div id="banner"><span class="bdot"></span><span id="btxt">连接已断开 · 重连中</span></div>
```

- [ ] **Step 2: touch WS 退避重连**

在 `function connect(){`（行 837）之前加：

```js
  // Spec: exponential backoff 2s→5s→10s cap; kick on foreground/online.
  var touchAttempts=0, touchTimer=null;
  function scheduleReconnect(){
    if(touchTimer) return;
    touchAttempts++;
    var btxt=document.getElementById('btxt');
    if(btxt) btxt.textContent='连接已断开 · 正在重连…（第'+touchAttempts+'次）';
    var delay=Math.min(10000,2000*Math.pow(2.5,touchAttempts-1));
    touchTimer=setTimeout(function(){ touchTimer=null; if(!wsReady) connect(); },delay);
  }
  function resetBanner(){ touchAttempts=0; if(touchTimer){clearTimeout(touchTimer);touchTimer=null;} if(banner) banner.classList.remove('show'); showToast('已重新连接'); }
```

- [ ] **Step 3: lazy toast（同 tapHint 风格，cssText 内联）**

在 scheduleReconnect 之前加：

```js
  var toastEl=null;
  function showToast(msg){
    if(!toastEl){
      toastEl=document.createElement('div');
      toastEl.style.cssText='position:fixed;bottom:72px;left:50%;transform:translateX(-50%) translateY(8px);z-index:16;background:rgba(30,30,34,.88);color:#fff;padding:8px 18px;border-radius:20px;font-size:14px;pointer-events:none;opacity:0;transition:opacity .3s,transform .3s;box-shadow:0 4px 16px rgba(0,0,0,.12);';
      document.body.appendChild(toastEl);
    }
    toastEl.textContent=msg;
    toastEl.style.opacity='1'; toastEl.style.transform='translateX(-50%) translateY(0)';
    clearTimeout(showToast._t);
    showToast._t=setTimeout(function(){ toastEl.style.opacity='0'; toastEl.style.transform='translateX(-50%) translateY(8px)'; },2000);
  }
```

- [ ] **Step 4: connect 的 onopen/onclose 接退避**

行 841-842：

```js
    ws.onopen=function(){ wsReady=true; if(banner) banner.classList.remove('show'); };
    ws.onclose=function(){ wsReady=false; if(banner) banner.classList.add('show'); setTimeout(connect,2000); };
```

替换为：

```js
    ws.onopen=function(){ wsReady=true; resetBanner(); };
    ws.onclose=function(){ wsReady=false; if(banner) banner.classList.add('show'); scheduleReconnect(); };
```

- [ ] **Step 5: 回前台/网络恢复立即重连**

在 `connect();`（行 850）之后、`setInterval(...ping...)` 之前加：

```js
  function kickReconnect(){
    if(!wsReady&&(!ws||ws.readyState>=2)){ touchAttempts=0; if(touchTimer){clearTimeout(touchTimer);touchTimer=null;} connect(); }
    if(useWebCodecs&&h264ws&&h264ws.readyState>=2){ videoAttempts=0; startWebCodecs(); }
  }
  document.addEventListener('visibilitychange',function(){ if(!document.hidden) kickReconnect(); });
  window.addEventListener('online',kickReconnect);
```

- [ ] **Step 6: h264 WS 同规则退避**

行 631：

```js
    h264ws.onclose=function(){ setTimeout(startWebCodecs,2000); };
```

替换为：

```js
    h264ws.onclose=function(){ videoAttempts++; var delay=Math.min(10000,2000*videoAttempts*videoAttempts); setTimeout(startWebCodecs,delay); };
```

并在 `h264ws.binaryType='arraybuffer';`（行 563）之后加：

```js
    h264ws.onopen=function(){ videoAttempts=0; };
```

在行 532 `var videoCodec='h264', ts=0;` 后补声明（若无）：

```js
  var videoAttempts=0;
```

- [ ] **Step 7: node 语法校验** → `JS syntax OK`

- [ ] **Step 8: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(webclient): 重连指数退避 2/5/10s + 回前台立即重连 + 横幅计数 + 重连成功 toast"
```

---

### Task 4: 音量 OSD + 键盘调节

**Files:**
- Modify: `native/Engine/webclient.html`（行 718-725 音量滑杆 handler；行 931-947 keydown）

- [ ] **Step 1: lazy OSD 元素**

在音量滑杆循环（行 718）之前加：

```js
  var osdEl=null, osdTimer=null;
  var osdLabels={master:'总音量',media:'媒体',nav:'导航',call:'通话'};
  function showVolumeOsd(kind,val){
    if(!osdEl){
      osdEl=document.createElement('div');
      osdEl.style.cssText='position:fixed;bottom:120px;left:50%;transform:translateX(-50%);z-index:16;display:flex;align-items:center;gap:12px;padding:10px 22px;border-radius:26px;color:#fff;font-weight:bold;pointer-events:none;background-image:linear-gradient(135deg,#ff5f6d,#ffb26b,#ffe66b,#6bd47f,#4fc3f7,#b06bf5);box-shadow:0 6px 20px rgba(0,0,0,.18);opacity:0;transition:opacity .25s;';
      osdEl.innerHTML='<span id="osd-lbl" style="font-size:13px;opacity:.9"></span><span id="osd-pct" style="font-size:24px;min-width:52px;text-align:right"></span><span style="width:90px;height:4px;border-radius:2px;background:rgba(255,255,255,.35);overflow:hidden"><span id="osd-bar" style="display:block;height:100%;width:100%;background:#fff;border-radius:2px"></span></span>';
      document.body.appendChild(osdEl);
    }
    osdEl.querySelector('#osd-lbl').textContent=osdLabels[kind]||kind;
    osdEl.querySelector('#osd-pct').textContent=val;
    osdEl.querySelector('#osd-bar').style.width=val+'%';
    osdEl.style.opacity='1'; clearTimeout(osdTimer);
    osdTimer=setTimeout(function(){ osdEl.style.opacity='0'; },2000);
  }
```

- [ ] **Step 2: 滑杆 input 触发 OSD**

行 720-723：

```js
    el.addEventListener('input',function(){
      volLevels[k]=el.value/100; v.textContent=el.value; applyVolumes();
      try{ localStorage.setItem('macplay-vol-'+k, el.value); }catch(e){}
    });
```

替换为：

```js
    el.addEventListener('input',function(){
      volLevels[k]=el.value/100; v.textContent=el.value; applyVolumes();
      showVolumeOsd(k,el.value);
      try{ localStorage.setItem('macplay-vol-'+k, el.value); }catch(e){}
    });
```

- [ ] **Step 3: 键盘 -/= 调总音量**

在 keydown switch（行 935 附近，`case ' ': sendKnob(...)` 之前）加两个 case：

```js
      case '=': case '+': setMasterVolume(Math.min(100,Math.round(volLevels.master*100)+5)); break;
      case '-': case '_': setMasterVolume(Math.max(0,Math.round(volLevels.master*100)-5)); break;
```

并在 keydown 段之前加：

```js
  function setMasterVolume(v){
    volLevels.master=v/100; applyVolumes();
    try{ localStorage.setItem('macplay-vol-master', v); }catch(e){}
    var el=document.getElementById('vol-master'), vv=document.getElementById('vol-master-v');
    if(el) el.value=v;
    if(vv) vv.textContent=v;
    showVolumeOsd('master',v);
  }
```

- [ ] **Step 4: node 语法校验** → `JS syntax OK`

- [ ] **Step 5: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(webclient): 音量彩虹 OSD——滑杆/键盘(-/=)调节即时反馈 2s 淡出"
```

---

### Task 5: RTT 测量进 HUD

**Files:**
- Modify: `native/Engine/webclient.html`（行 847 ws.onmessage JSON 分支；行 851 ping interval）

- [ ] **Step 1: 记录发送时间**

行 851：

```js
  setInterval(function(){ send({t:'ping'}); },20000);
```

替换为：

```js
  var pingSentAt=0, rttSamples=[];
  setInterval(function(){ if(wsReady){ pingSentAt=Date.now(); send({t:'ping'}); } },20000);
```

（rttMs 全局已在 Task 1 声明。）

- [ ] **Step 2: onmessage 处理 pong**

行 847 JSON 分支：

```js
      try{ var m=JSON.parse(ev.data); if(m&&m.t==='ping'){ send({t:'pong'}); return; } if(m&&m.t==='displayProbe'){ probeAnswered=!!m.switchable; return; } }catch(e){}
```

替换为：

```js
      try{ var m=JSON.parse(ev.data);
        if(m&&m.t==='ping'){ send({t:'pong'}); return; }
        if(m&&m.t==='pong'&&pingSentAt){ var r=Date.now()-pingSentAt; pingSentAt=0;
          rttSamples.push(r); if(rttSamples.length>5) rttSamples.shift();
          rttMs=Math.round(rttSamples.reduce(function(a,b){return a+b;},0)/rttSamples.length); return; }
        if(m&&m.t==='displayProbe'){ probeAnswered=!!m.switchable; return; } }catch(e){}
```

- [ ] **Step 3: node 语法校验** → `JS syntax OK`

- [ ] **Step 4: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(webclient): HUD 显示触控通道 RTT（ping/pong 5 次滑动平均）"
```

---

### Task 6: 音频全流自适应缓冲 + 欠载计数

**Files:**
- Modify: `native/Engine/webclient.html`（行 741-745 jitterFor；行 754-755 调用处；行 761 underrun 加深；行 789 回落）

- [ ] **Step 1: jitterFor 支持按流类型的起步值与地板**

行 741-745：

```js
  var jitterTargets={};
  function jitterFor(stream){
    var j=jitterTargets[stream];
    if(!j) j=jitterTargets[stream]={target:0.35,healthySince:0};
    return j;
  }
```

替换为：

```js
  var jitterTargets={};
  function jitterFor(stream,kind){
    var j=jitterTargets[stream];
    if(!j){
      // Spec: per-kind floor — call is latency-sensitive, media prioritizes
      // smoothness; underruns deepen from the same base and decay back.
      var base=kind==='media'?0.35:(kind==='nav'?0.15:0.06);
      j=jitterTargets[stream]={target:base,floor:base,healthySince:0};
    }
    return j;
  }
```

- [ ] **Step 2: 调用处全流启用**

行 753-755：

```js
    var now=audioCtx.currentTime;
    var j=frame.media?jitterFor(frame.stream):null;
    var delay=j?j.target:0.06, maxAhead=frame.media?delay+1.65:0.25;
```

替换为：

```js
    var now=audioCtx.currentTime;
    var kind=streamKind(frame.stream);
    var j=jitterFor(frame.stream,kind);
    var delay=j.target, maxAhead=kind==='media'?delay+1.65:0.25;
```

- [ ] **Step 3: underrun 分支计数**

行 761：

```js
      if(j){ j.target=Math.min(1,j.target+0.1); j.healthySince=now; }
```

替换为：

```js
      audioUnderruns++;
      j.target=Math.min(1,j.target+0.1); j.healthySince=now;
```

- [ ] **Step 4: 回落使用各自地板**

行 789：

```js
    if(j&&now-j.healthySince>20&&j.target>0.3){ j.target=Math.max(0.3,j.target-0.02); j.healthySince=now; }
```

替换为：

```js
    if(now-j.healthySince>20&&j.target>j.floor){ j.target=Math.max(j.floor,j.target-0.02); j.healthySince=now; }
```

- [ ] **Step 5: node 语法校验** → `JS syntax OK`

- [ ] **Step 6: Commit**

```bash
git add native/Engine/webclient.html
git commit -m "feat(webclient): 音频全流自适应 jitter（媒体0.35/导航0.15/通话0.06）+ HUD 欠载计数"
```

---

### Task 7: 打包验证

- [ ] **Step 1: 全量语法校验**（同 Task 1 Step 5 命令）→ `JS syntax OK`

- [ ] **Step 2: 构建arm64 DMG**

```bash
bash scripts/build-macplay.sh --arch=arm64
```

Expected: exit 0，`dist/NIOPlay-1.2.2-arm64.dmg` 更新。

- [ ] **Step 3: 通知用户上车验证**（按规格测试节：断连退避/OSD/HUD 计数/导航语音）

---

## Self-Review 记录

- 规格覆盖：6 项均有对应 Task（1→渲染、2→触控、3→重连、4→OSD、5→RTT、6→音频）；HUD 三计数器在 Task 1 框架内。✓
- 占位符：无 TBD/TODO；所有代码块完整。✓
- 类型一致性：`jitterFor(stream,kind)` 签名 Task 6 内两处一致；`showToast`/`showVolumeOsd`/`setMasterVolume`/`kickReconnect`/`scheduleReconnect` 均在使用前定义或为提升的 function 声明；`videoAttempts` 在 Task 3 Step 6 声明、Step 5 kickReconnect 引用（var 提升，安全）。✓
- 风险点：Task 3 Step 5 kickReconnect 中 `h264ws.readyState>=2` 避免与 in-flight 连接重复；`useWebCodecs` 为既有全局。✓
