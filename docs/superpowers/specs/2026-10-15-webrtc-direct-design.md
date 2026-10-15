# WebRTC 直通设计（A 子项目 · WheelPlay 二期）

日期：2026-10-15 ｜ 分支：web-streaming ｜ 分三阶段实施

## 目标

Mac→车机视频通路增加 WebRTC 直通分支：H.264 经 GStreamer `webrtcbin` 打包 RTP 直推浏览器 `RTCPeerConnection`，**零解码零编码零中转拷贝**（M1 满血形态）。拥塞自适应（GCC/TWCC）、丢包重传（NACK/RTX）、getStats 健康监控。

## 范围与取舍（YAGNI）

- **仅 H.264**：浏览器 WebRTC 不支持 HEVC；h265 模式继续走现有 WS/WebCodecs，不做转码兼容
- **仅局域网 host candidates**：车机热点场景无 NAT 穿越需求，不需要 STUN/TURN
- **不做 JPEG 兜底**：现有 WS/MJPEG 与 WS/WebCodecs 本身就是兜底路径，WebRTC 失败自动降级即可
- 音频不走 WebRTC：现有 /touch WS 音频链路已带自适应 jitter 缓冲且工作良好，避免双通路时钟冲突

## 阶段 1 · Homebrew 环境验证（Rust + webclient + 信令）

### Rust 管线（native/livi-gst-video/rust/addon）

- 现有 tap 分支不变，新增 webrtcbin 分支：`appsink/identity` 直出的 H.264 Annex B → `h264parse config-interval=-1` → `rtph264pay` → `webrtcbin`（`bundle`、`media/video`，direction=sendonly）
- 不插入解码器/编码器/videorate——字节直通，CPU 仅 RTP 打包
- webrtcbin `on-need-offer`（Mac 侧主动）或浏览器侧先发 offer 二选一：**采用浏览器先发 offer**（webclient 建立 RTCPeerConnection → createOffer → 经 /rtc WS 发给 Rust → Rust `set-remote-description` → `create-answer` 回传），ICE candidate 双向 JSON 透传
- 信令格式（/rtc WS，全 JSON）：`{t:"offer"|"answer"|"ice", sdp?, candidate?}`
- Rust 侧不引入额外依赖，用 gstreamer-rs 已有 webrtc 特性

### webserver.ts（信令通道）

- 新增 WS 路径 `/rtc`：接受单个浏览器客户端（多客户端排队拒绝，同 h264 tap 策略），消息原样转发给 Rust 的 rtc 命令通道；Rust 侧 SDP/ICE 事件回推
- 与现有 `/h264`、`/touch` 并存；Webrtc 会话活跃时视频 WS 客户端不主动踢除（降级期间两者可能并存数秒）

### webclient.html

- 启动优先尝试 WebRTC：建 RTCPeerConnection → offer → /rtc WS 交换 → `ontrack` 接 video → `<video>` 元素替换 `<canvas>` 显示（video 支持同样的双击专注/触控事件，触控 rect 计算适配 video）
- 健康判定（getStats，1s 轮询）：`framesDecoded` 停滞 5s → 发 PLI（`pc.getSenders()` 不可用时通过 /rtc 发 `{t:"pli"}` 让 Rust 侧 force-key-unit）→ 再停滞 5s → **降级回 WS/WebCodecs**（关闭 pc，走现有路径，不改协议）
- 降级后本次会话不再自动尝试 WebRTC（存 sessionStorage 标记，手动刷新重试）
- HUD 增加 `WebRTC` 标记 + getStats 的丢包/RTT 摘要

## 阶段 2 · 捆绑包插件补齐

- `scripts/build-macplay.sh`：将 Homebrew gst 插件目录中 `libgstnice`、`libgstdtls`、`libgstsrtp`、`libgstrtpmanager`、`libgstrtp` 一并打入 bundle 插件目录，并对 `.dylib`/`.so` 做 `@rpath` 改写与 `codesign`（沿用 media.ts 现有捆绑改写逻辑的模式）
- libnice 自身依赖（glib 已有）核对：`gio`、`gssdp` 不需要；仅 nice 本体 + gnutls（Homebrew 已随 gst 依赖存在，需确认打进 Frameworks）
- 验证方式：捆绑环境下 `gst-inspect-1.0 nice dtls srtp` 全部命中（新增构建自检步骤）

## 阶段 3 · 上车打磨

- getStats 数据进 HUD：`packetsLost`、`jitter`、`rtt`、`framesPerSecond`
- 静帧容忍阈值按车机实测调参（阶段 1 的 5s 起步值可调）
- webrtcbin 拥塞控制验证：若 GCC 压码率过激（车机 WiFi 带宽足），在 answer SDP 固定 `x-google-max-bitrate`（沿用设置页当前码率值）

## 错误处理

- /rtc WS 连接失败或 3s 内未完成 SDP 交换 → 直接走现有路径（视为功能不存在）
- Rust 侧 webrtcbin 创建失败（插件缺失）→ 日志记录，页面照常走 WS/WebCodecs，/rtc WS 返回 `{t:"unsupported"}`
- ICE 连接状态 failed/disconnected → 触发与「静帧容忍」相同的降级流程

## 验证

- 阶段 1：Homebrew 环境 `gst-inspect` 有 webrtcbin；浏览器 `chrome://webrtc-internals` 确认 RTP 直通帧率、零转码 CPU；拔线/杀接收端触发降级回退
- 阶段 2：捆绑 DMG 在干净机器（无 Homebrew gst）上同上验证 + 构建自检通过
- 阶段 3：上车实测 HUD 丢包/RTT 数值、降级触发日志
