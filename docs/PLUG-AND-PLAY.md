# 即插即用（CarPlay 盒子模式）+ 菜单栏参数区 — 维护交接文档

> 面向后续维护者（人或模型）。读完本文即可接手这两个功能的维护，无需重新考古。
> 对应代码版本：1.3.3（构建 8930 之后）、分支 `web-streaming`。

---

## 一、功能是什么

### 1. 即插即用（Plug & Play）

用户在系统设置里**一次性**配好「互联网共享」（iPhone USB → Wi-Fi 热点，名称密码由用户配置）后，本功能让 Mac 表现得像个 CarPlay 盒子：

**插入 iPhone → 自动执行三步：**
1. 断开当前 Wi-Fi（`CWWiFiClient.interface().disassociate()`）
2. 开启互联网共享（改 `com.apple.nat.plist` 两个 Enabled 键 + `launchctl kickstart` 共享守护进程）
3. 开启合盖不休眠（`pmset -a disablesleep 1`，合盖熄屏但系统继续运行）

**还原时机（按启用前快照逐项写回，不是一刀切全关）：**
- 拔出 iPhone（6 秒宽限，避免切蜂窝/低电量导致的 USB 重枚举误触发）
- 用户关闭即插即用开关（设置页或菜单栏）
- 应用退出（`applicationShouldTerminate` 返回 `.terminateLater`，还原完再退）

**管理员授权：** 开启、还原各弹一次 osascript 密码框（与防火墙一键放行同一套路）。用户点掉授权 → 原样回退不留半成品；崩溃/强退 → 快照留在磁盘，下次启动自动继续恢复。

**引导设置（1.3.3 新增）：** 设置页「即插即用」Section 内的 DisclosureGroup。展示 nat.plist 实时状态（热点名称 / Wi-Fi 共享段 / 共享开关，绿=就绪 橙=缺失）+ 激活后的热点网关地址；一键跳转系统设置互联网共享面板（`x-apple.systempreferences:com.apple.preferences.sharing?internetSharing`，macOS 27.2 实测可用）；「重新检测」重读 nat.plist 与 bridge IP。数据源是 `PlayModel.pnpGuideConfig / pnpGuideBridgeIP`（@Published），由 `refreshPnpGuide()` 刷新——`pnpRefreshLanInfo()`（控制器激活/还原后调用）与按钮都会触发。

### 2. 菜单栏 / Dock 右键菜单增强

菜单结构（两个入口共用同一个构建器）：

```
● 接收中 · N分钟              ← 状态行（灰）
iPhone：xxx                   ← 参数区（灰）
连接：无线 · SSID / 有线 USB
画面：1280×720 · 60fps
即插即用：热点 paocailaosiji
Wi-Fi https://192.168.2.1:8443      ← 点击复制（黑色可点）
热点 https://...  / .local https://...local:8443
────────────────
显示NIO Play / 显示CarPlay
媒体音量滑杆（仅接收中）
启动/停止接收
────────────────
☑ 即插即用    ☑ 登录时启动    复制车机地址
────────────────
退出NIO Play
```

---

## 二、代码地图

| 文件 | 职责 |
| --- | --- |
| `native/App/PlugAndPlay.swift` | **全部即插即用逻辑**。分三层：`PlugAndPlayCore`（纯函数：plist 解析、shell 脚本拼装、状态探测，无 AppKit 依赖）、`PnpState`（快照 Codable）、`PlugAndPlayController`（@MainActor 状态机） |
| `native/App/PlugAndPlayPolicy.test.swift` | Core 层单测（@main 直跑，非 XCTest） |
| `native/App/MacPlay.swift` | `PlaySettings.plugAndPlay` 持久化开关；`PlayModel` 三个 @Published（active/busy/status）+ 引导设置两个 @Published（pnpGuideConfig/pnpGuideBridgeIP）与 `refreshPnpGuide()`；`extension PlayModel: PlugAndPlayHost`；`refreshUSB()` 末尾触发；连接页「即插即用」Section（含引导设置 DisclosureGroup）；`revertBeforeQuit` |
| `native/App/ApplicationLifecycle.swift` | 托盘/Dock 菜单构建器 `menu()`、参数区、地址点击复制、`togglePlugAndPlay`、`paramsKey` 菜单重建缓存、退出时还原钩子 |
| `native/App/Localization.swift` | 新增字符串 + 4 条正则模式（`^iPhone：`、`^连接：无线 ·`、`^画面：`、`^即插即用：热点` 等，含插值的都走 pattern） |

构建：`scripts/build-macplay.sh` 第 13 行的 swiftc 源文件清单已包含 `PlugAndPlay.swift`。

单测跑法（约 2 秒）：

```bash
swiftc -O native/App/PlugAndPlay.swift native/App/PlugAndPlayPolicy.test.swift \
  -o /tmp/pnp-test -framework Foundation -framework AppKit -framework CoreWLAN && /tmp/pnp-test
```

整体 typecheck（用构建脚本原参数，不产出文件）：

```bash
swiftc -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -framework CoreWLAN -framework CoreLocation \
  -framework IOKit -framework IOBluetooth -framework CoreAudio -framework MediaPlayer \
  native/App/MacPlay.swift native/App/ApplicationLifecycle.swift native/App/About.swift \
  native/App/Localization.swift native/App/ConnectionPolicy.swift native/App/PlugAndPlay.swift \
  native/App/NowPlayingState.swift native/App/NowPlayingFeed.swift -o /dev/null
```

---

## 三、关键设计决策（为什么这么做）

### 状态机与数据流

```
refreshUSB()（每3秒，MacPlay.swift）
  └→ plugAndPlay.usbPresenceChanged(hasPhone:)
       ├ 插入沿(且有开关/不忙/未激活) → activate()
       ├ 拔出沿(且激活中) → 6秒宽限定时器 → revert()
       └ 宽限期内插回 → 取消定时器，仅刷新状态行
```

- `PlugAndPlayHost` 协议隔离了控制器对 `PlayModel` 的全部依赖（enabled/busy/active/status/密码表/刷新LAN），便于单测与解耦。
- **activate() 先拍快照再动系统**：快照同步写 `~/Library/Application Support/MacPlay/pnp-state.json`（0600 目录），还原彻底成功才删文件；授权取消/失败时保留，下次启动 `restoreIfStaleIfNeeded()` 兜底（延迟 1.5 秒让窗口先绘制）。
- **disableRequested() 里自旋等 busy**：用户在激活进行中关开关时，若直接 revert 会撞 busy 被静默跳过，留下「开关关了但共享还开着」。现在轮询 300ms 直到激活收尾再还原。
- `runAdmin` 判定 `-128`（osascript 用户取消错误码）区分 canceled / failed，两者 UI 提示与善后不同（canceled=未执行任何命令直接清理；failed=命令已跑，保留状态）。

### 互联网共享怎么开关的（新版 macOS 知识点）

- **服务名已变**：老资料里的 `com.apple.InternetSharing` 在新 macOS 上是 `com.apple.NetworkSharing`（plist 仍指向 `/usr/libexec/InternetSharing`）。kickstart 失败时 fallback 到 `bootstrap system <plist路径>`。
- **改 plist 不生效**：共享守护进程是按需启动的 MachService，改完 `com.apple.nat.plist` 必须 `launchctl kickstart -k` 让它重读。启用脚本里 kick 后轮询 `ifconfig bridge100` 最多 4 轮×3 秒；AP 接管前 Wi-Fi 被自动重连抢占时，多次 kick 也是重试接管。
- **桥接口即热点网关**：共享激活后 `bridge100` 持有 `192.168.2.1`（这就是车机该访问的 Mac 地址）。`sharedBridgeIPv4()` 扫所有 `bridge*` 接口取 IPv4。
- **PlistBuddy 写法**：`Set ... || Add ...` 兜底（键可能不存在）；NAT 主开关和 AirPort 段分开写，**未配置 AirPort 段的机器绝不碰 AirPort 键**（enableScript/restoreScript 的 `airportConfigured` 参数）。
- **密码字段**：`NetworkPassword` 在这台机器（macOS 27.2）上为空但热点带密码，新版 macOS 已不在 nat.plist 存明文/密文密码——**不要尝试从 nat.plist 读密码或往里写密码**，那是系统设置的事。

### 合盖不休眠

- `pmset -a disablesleep 1/0`，当前值从 `pmset -g` 首段 `SleepDisabled` 行解析。
- 快照里 `sleepDisabledWas == true` 的机器还原时**不写 0**（保持无副作用）；只有我们改过的才改回去。
- 与设置页原有的「CarPlay连接时防止系统休眠」（引擎侧 `caffeinate -s`，见 `native/Engine/main.ts:250` 附近）是**两套机制**：后者只在 CarPlay 会话期间、不合盖；即插即用的 disablesleep 是系统级、合盖也不睡。互不干扰，不要合并。

### 菜单重建缓存（性能关键）

`PlayModel.objectWillChange` 在流媒体期间每秒触发多次（logs 就占大头）。菜单重建由 `paramsKey` 把守——只有 phone/连接方式/分辨率/帧率/即插即用态/地址数量/首选地址 变了才重建。**给菜单加新条目时，同步把相关字段加进 `paramsKey`**，否则要么不刷新要么每秒重建。

`menuWillOpen` 里调 `refreshLanInfo(refreshFirewall:false)` 刷新 DHCP 变动地址是安全的：objectWillChange 的 sink 是 `DispatchQueue.main.async`，菜单跟踪模式下不执行，重建发生在菜单关闭后。

### Wi-Fi 还原

`rejoinWiFi`：快照记了原接口名+SSID，还原后用 `scanForNetworks(withName:)` + `associate(to:password:)` 抢一次重连，密码优先用 `settings.wifiProfiles`（本地缓存）。失败不重试——macOS 自己会重连；定位权限缺失时扫描会失败，静默放弃即可。

---

## 四、本机环境事实（2026-10 实测）

| 项 | 值 |
| --- | --- |
| macOS | 27.2 (26B5112a)，arm64 |
| 共享源接口 | `en5`（iPhone USB） |
| 热点名 | `paocailaosiji`（nat.plist NetworkName） |
| 共享守护进程 | `com.apple.NetworkSharing`，kickstart 可用 |
| pmset | `SleepDisabled` 可读，`disablesleep` 在 `pmset -g cap` 能力列表中 |
| 应用数据目录 | `~/Library/Application Support/MacPlay/`（settings.json / pnp-state.json / MacPlay.log） |

---

## 五、已知边界与待办

1. **插入前就开着共享**：快照 `natEnabledWas=true`，还原时保持开——设计如此（还原到用户原状），不是 bug。
2. **启动时 iPhone 已插着且开关开**：init 的 `refreshUSB()` 触发首次 usbPresenceChanged，`changed=true` 会直接激活——预期行为（开机即盒子模式）。
3. **授权取消后的 Wi-Fi**：仅 disassociate 过，`rejoinWiFi` 会尝试重连；失败由系统自动重连兜底。
4. **退出时正在忙**（busy）：跳过还原直接退出，靠下次启动的 stale 恢复。
5. **菜单地址含 utun 排除逻辑**：`lanIPv4Addresses()` 过滤 lo0/utun*/awdl0/llw0，bridge 接口**保留**（这是特性，别当垃圾接口过滤掉）。
6. 若未来要加「自动关闭即插即用时也停接收」之类的联动，入口在 `setPlugAndPlay`（MacPlay.swift），别散落多处。

## 六、验证清单（改完跑一遍）

1. `swiftc` 单测命令（上文）→ 输出 `PlugAndPlay: ... passed`
2. 整体 typecheck → exit 0（存量 3 个 deprecation 警告属正常：activateIgnoringOtherApps、SecKeychain×2）
3. `npm run build` 全量构建成功
4. 手工冒烟（可选，需 iPhone）：开关开→插线→输管理员密码→手机搜到热点；拔线 6 秒→再输密码→共享关闭、原 Wi-Fi 回来、`pmset -g` 里 SleepDisabled 归位
