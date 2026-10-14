<p align="center"><img src="assets/icons/mac/macplay.iconset/icon_128x128.png" width="104" alt="MacPlay应用图标"></p>

<h1 align="center">MacPlay（车机浏览器版）</h1>

<p align="center">iPhone → Mac → 车机浏览器：在车载大屏的浏览器里显示和操作 CarPlay。</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-2563eb?style=flat-square" alt="项目许可"></a>
  <a href="#使用条件"><img src="https://img.shields.io/badge/platform-macOS%2014%2B-555555?style=flat-square" alt="运行平台"></a>
</p>

<p align="center"><a href="#快速入门">快速入门</a> · <a href="#车机浏览器">车机浏览器</a> · <a href="#本版特有功能">本版特有功能</a> · <a href="#从源码构建">源码构建</a> · <a href="#致谢">致谢</a> · <a href="#许可">许可</a></p>

## 这是什么

本仓库是 [MacPlay](https://github.com/Roylyl/MacPlay) 的 fork，目标只有一个场景：**把 Mac 变成 CarPlay 接收器，再把画面串流到车机浏览器**。

```
iPhone --(USB/无线 CarPlay)--> Mac --(局域网 http://<Mac-IP>:8080)--> 车机浏览器
```

Mac、iPhone、车机在同一局域网（通常是车机/手机热点）。Mac 负责与 iPhone 建立 CarPlay 连接并解码，车机浏览器只负责显示画面、回传触控、播放声音——车机侧零安装，打开浏览器即可。

相比上游，本版新增：浏览器串流（视频/触控/音频）、无头模式、连接时防休眠、局域网地址展示与防火墙一键放行；并移除了 CarPlay 主屏幕上的 MacPlay 入口图标、默认关闭了自动检查更新。

## 快速入门

### 使用条件

- macOS 14 及以上，Apple Silicon（M 系列）处理器。**目前仅提供 ARM64 构建，Intel 机型需自行从源码编译。**
- 支持 CarPlay 的 iPhone；有线需要 USB 数据线，无线需要蓝牙与允许设备互访的共用 Wi-Fi。
- 车机（或任意设备）浏览器，与 Mac 在同一局域网。

### 安装与启动

```sh
git clone https://github.com/kissggj123/MacPlay-CarBrowser.git
cd MacPlay-CarBrowser
pnpm install
bash scripts/build-macplay.sh
```

构建产物为 `dist/MacPlay.app`，拖入"应用程序"后启动。若 macOS 拦截，在"系统设置 → 隐私与安全性"中允许打开（本地签名，未经 Apple 公证）。

### 连接 iPhone

1. **有线**：USB 连接 iPhone 与 Mac，解锁并"信任此电脑"，在"连接"页选"有线 CarPlay"，点击"启动接收"。
2. **无线**：Mac 与 iPhone 加入同一 Wi-Fi，蓝牙配对，在"连接 → 共用 Wi-Fi"填写 SSID 与密码，点击"启动接收"，在 iPhone 上允许 CarPlay。

连接成功后，Mac 本机会显示 CarPlay 画面（如需隐藏见[无头模式](#无头模式)）。

### 打开车机浏览器

在 MacPlay"设置 → 连接 → 应用 → **车机浏览器**"中查看本机局域网地址（如 `http://192.168.43.10:8080`），在车机浏览器打开即可。页面即全屏式 CarPlay 界面：画面显示、触控操作、声音播放都在浏览器里完成。

## 车机浏览器

### 地址与防火墙

- 设置页列出本机所有局域网 IPv4 地址（Wi-Fi 优先），一键复制。
- 局域网只需放行 **TCP 8080**（画面/触控/音频都走它）。监听的是 `MacPlayReceiver` 进程。
- 若 macOS 防火墙开启且未放行，设置页会提示并提供"一键放行 MacPlayReceiver"（需管理员密码，调用 `socketfilterfw --add`），或手动前往"系统设置 → 网络 → 防火墙"允许。
- iPhone ↔ Mac 的 CarPlay 通道（USB 经系统 usbmuxd、无线经蓝牙/Wi-Fi）走 MacPlay 自身，不受此影响。

### 技术实现

- **视频（零转码）**：GStreamer 管道在 `h264parse` 后直接分流原始 H.264，经 WebSocket `/h264` 送浏览器，用 **WebCodecs** 硬解——Mac 端不解码不重编码，纯转发（M1 的 VideoToolbox 本来也是硬解，但直通连解都省了）。需要 HTTPS（自签证书，首次访问车机浏览器点一次"继续前往"即可），端口 8443。
- **视频（兼容模式）**：浏览器不支持 WebCodecs（如非 HTTPS）时自动回退 MJPEG：GStreamer 内 `tee` 分支出一路 `videoscale → jpegenc`（960px 宽，约 15fps）→ `/mjpeg`。非截屏方案，Mac 熄屏/合盖（接电源）不影响串流。
- **音频**：借鉴 [WheelPlay](https://github.com/fython/wheelplay) 的浏览器音频协议。Rust 端输出各路 CarPlay 音频流解码后的 PCM，经二进制帧（magic `0x31415057` + stream id + 采样率/声道 + 序号 + Int16LE）走 TCP 到 Node，再以 WebSocket 二进制转发；浏览器用 Web Audio API 播放，媒体流约 300ms 缓冲、实时/通话流约 60ms。各流独立，无 Mac 端混音。Web 模式下 Mac 本地不再发声。
- **触控**：浏览器 touch/pointer 事件经 WebSocket `/touch` 回传，调用既有 `sendTouches()`。坐标映射考虑 `object-fit: contain` 的黑边（letterbox-aware），move 事件经 `requestAnimationFrame` 合并，页面隐藏/失焦自动松开触点。
- **键盘旋钮**：方向键 = 旋钮推拉、回车 = 确认、Esc = 返回、H = Home，经 `/touch` 的 `knob` 消息走 HID 上报（借鉴 PlayPort）。
- **状态 HUD**：左上角实时显示当前视频模式（WebCodecs/MJPEG）、帧率、码率。

## 本版特有功能

### 无头模式

"连接 → 应用 → 无头模式（不在 Mac 上显示 CarPlay 画面）"：Rust 端视频管道改用 `fakesink`，Engine 不再创建/显示原生 CarPlay 窗口，画面只在浏览器。切换后重新连接生效。适合把 Mac 藏起来只用车机屏的场景。

### 连接时防止系统休眠

"连接 → 应用 → CarPlay 连接时防止系统休眠"：CarPlay 会话期间自动执行 `caffeinate -s`（阻止系统空闲休眠，允许显示器休眠），断开后自动释放。合盖使用需接电源（macOS 限制）。

另外 `scripts/car-mode.sh` 提供独立两窗口工作流：一个窗口正常配置/运行 MacPlay，另一个窗口运行该脚本（`caffeinate -i` + 立即熄屏），Ctrl-C 退出并唤醒屏幕。

### 精简与省电

- 自动检查更新默认关闭（上游检查的是原仓库，对 fork 无意义，还每 2 小时联网一次）；手动检查改为读取本 fork 的 releases。
- 车机使用建议：帧率选 30fps、分辨率 1280×720——浏览器 MJPEG 本来也就十几帧，更高帧率下 iPhone 渲染/编码与 Mac 解码都是白费电。

### M1 性能优化

- **视频解码**：macOS 下默认走 `vtdec`（VideoToolbox），M1 媒体引擎硬解，CPU 占用极低。
- **零转码模式**："连接 → 应用 → 零转码模式"：跳过 Mac 端视频解码，H.264 直接转发给浏览器 WebCodecs 硬解。需配合无头模式 + Chromium 系浏览器（HTTPS）。此模式下 Mac 视频部分 CPU 占用接近零（纯转发），是 M1 最佳性能/最低功耗组合。
- **音频**：PCM 直发 WebSocket，无重编码，开销可忽略。

## 原生功能（继承自上游）

- USB 直连 / 共用 Wi-Fi 无线连接，蓝牙引导配对，SSID/密码读取（需定位与钥匙串授权）。
- 显示设置：屏幕原生像素（避开刘海）、1280×720 / 1920×1080 / 2560×1440 / 自定义，帧率 30/60/90/120fps（高帧率协商失败自动回退）。
- 音频：媒体/通话音量实时调节，输入/输出设备选择（Web 模式下音量仍作用于浏览器音频）。
- 无线被动断开自动重连、USB 接入自动启动、菜单栏常驻后台运行。
- 跟随系统 / 简体中文 / 繁體中文 / English 四种界面语言。

## 从源码构建

需要 macOS、Xcode 命令行工具、Node.js、pnpm、Rust、pkg-config 及 GStreamer 开发 SDK。将 SDK 的 `lib/pkgconfig` 加入 `PKG_CONFIG_PATH`，在仓库根目录执行：

```sh
pnpm install
bash scripts/build-macplay.sh
```

构建脚本处理 SwiftUI 应用、蓝牙桥接、Rust 后端、音视频模块和 Node.js 服务，并进行本地签名。TypeScript 严格模式编译与浏览器 JS 语法检查是构建的一部分。

## 常见问题

| 现象 | 处理方法 |
| --- | --- |
| 车机浏览器打不开页面 | 确认车机与 Mac 同一局域网；在 MacPlay 设置"车机浏览器"中复制正确的地址；检查 macOS 防火墙是否放行 TCP 8080 |
| 有画面没声音 | 确认浏览器已允许自动播放/取消静音；Web 模式下声音只在浏览器播放，Mac 本地无声是正常的 |
| 触控位置偏移 | 页面缩放保持 100%；已做黑边适配，如仍偏移请提 issue 附车型浏览器信息 |
| 合盖后断开 | macOS 限制：合盖持续运行需连接电源，并开启"连接时防止系统休眠" |
| 无线一直等待连接 | 检查蓝牙配对、SSID/密码，确认 Wi-Fi 允许设备互访 |

## 致谢

- **[MacPlay](https://github.com/Roylyl/MacPlay)**（Roylyl）：完整的 macOS CarPlay 主机实现（USB/无线传输、GStreamer 音视频管道、SwiftUI 界面）。本项目是其 fork，核心连接与解码能力全部来自上游。
- **[WheelPlay](https://github.com/fython/wheelplay)**（fython）：车载 Android 设备的 CarPlay 接收器。其网页客户端的二进制 PCM 音频协议（WebSocket + Web Audio API）与触控坐标映射思路被本项目移植/借鉴到 Mac 端浏览器串流。
- **[PlayPort](https://github.com/youcci/playport)**（youcci）：macOS 上的无线 CarPlay 浏览器接收器。其 WebCodecs H.264 零转码直通架构（服务端不解码不重编码、浏览器硬解）、显示设置面板、音频混音器、麦克风回传、Focus 模式等设计被本项目借鉴实现。
- 上游依赖：[LIVI](https://github.com/f-io/LIVI)（CarPlay 协议基础）、[DiPlay](https://github.com/shihabal3amri/DiPlay)。

## 许可

沿用上游 GPL-3.0-or-later，见 [LICENSE](LICENSE)；运行库许可位于 `assets/licenses` 与 `assets/gstreamer/LICENSES`。上游版权与来源声明见 [NOTICE](NOTICE)。

第三方组件、认证文件和商标分别适用各自权利条件。本项目是独立 fork，不代表 Apple、上游作者或 WheelPlay 作者，不声称获得 MFi 认证。分发修改版时应保留声明并提供适用许可证要求的对应源码与构建资料。
