# 菜单栏增强 + 后台性能优化设计（B 子项目）

日期：2026-10-15 ｜ 分支：web-streaming ｜ 部署目标：macOS 14.0

## 目标

菜单栏（NSStatusItem）快捷控制补齐，消除后台高频浪费。改动仅 Swift 三文件：
`native/App/ApplicationLifecycle.swift`、`native/App/MacPlay.swift`、`native/App/Localization.swift`。

## 1. 状态行

`menu()` 顶部插入禁用只读项（`isEnabled=false`，不用 action）：

- 接收中（`model.running == true`）：`● 接收中 · {N}分钟`（N 取 `sessionStart` 距今分钟数，向下取整；sessionStart 为 nil 则只显示 `● 接收中`）
- 未连接：`○ 未连接`

不显示设备名（PlayModel 无独立设备名字段，不解析 status/detail 文案）。

## 2. 音量滑条

菜单内 view-based NSMenuItem：

- 内容视图：横向 NSSlider（0...100，continuous），高度约 24pt，左右留白 12pt
- 绑定：`get: model.settings.volume`（0-1），`set: { model.settings.volume = $0; model.sendAudioCommand() }`——与音频 Tab 完全同通道
- 不放标签文字（菜单项自带缩进，滑条即语义）；无障碍 `accessibilityLabel` = 本地化"媒体音量"
- 仅 `model.running == true` 时可用，否则整项移除（不显示灰色滑条）

## 3. 开机自启

- `PlaySettings` 增加 `var launchAtLogin: Bool? = nil`（Codable 兼容旧配置；nil 视为 false）
- 读写走 `SMAppService.mainApp`：开启 `register()`，关闭 `unregister()`；UI 状态以 `SMAppService.mainApp.status` 为准（不信任 settings 缓存），注册失败时 `model.status` 提示
- 入口两处同步：
  - 连接 Tab「应用」区新增 Toggle「登录时启动」
  - 菜单栏勾选项（`state == .on`），切换调同一方法 `model.setLaunchAtLogin(_:)`
- 部署目标 14.0，无需 `@available` guard

## 4. 复制车机地址快捷项

菜单项「复制车机地址」：取 `model.lanAddresses` 第一个 `iphoneUSB == false` 的地址，`NSPasteboard` 写入 `https://{address}`；无可用地址时该项禁用。复制成功不弹 UI（菜单自然关闭即为反馈）。

## 5. 后台性能修复（核心）

现状：`modelObservation = model.objectWillChange.sink { updateMenus() }`——`logs` 是 @Published，串流时每条日志都重建一次 NSMenu（读代码确认的高频浪费）。

修复：sink 中改为 `DispatchQueue.main.async` 后比对缓存值，仅 `running` 或 `receivingOrWaiting` 实际变化时才调 `updateMenus()`；`updateMenus()` 内部首行同步缓存。菜单内的动态内容（状态行、音量项、启动/停止文案、复制项可用性）都只依赖 `running`/`receivingOrWaiting`/`lanAddresses`；`lanAddresses` 变化低频（10s 定时器），将其一并纳入比对（比对元组数组计数 + 首地址字符串即可，避免全量 Equatable）。

## 6. 词条

新增词条进 `Localization.swift`（简/繁/英，`L()` 格式）：

- 接收中 / 未连接（状态行）
- 登录时启动（Toggle + 菜单）
- 复制车机地址
- 媒体音量（无障碍标签）
- 登录项注册失败提示

## 验证

- `bash scripts/build-macplay.sh --arch=arm64` 编译通过（exit 0）
- 手动：菜单各交互项、音量滑条拖动即生效、登录项开关与系统设置「通用-登录项」一致、重启后自启生效
- 性能：串流 + 窗口关闭（后台模式）下活动监视器对比修复前后 CPU
