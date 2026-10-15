# 菜单栏增强 + 后台性能优化（B 阶段）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 菜单栏补齐状态行/音量滑条/开机自启/复制车机地址，并消除「每条日志重建 NSMenu」的后台高频浪费。

**Architecture:** 全部改动集中在 AppKit 层：`MacPlayApplicationDelegate`（NSStatusItem 菜单）+ `PlayModel`（新增 `setLaunchAtLogin`，SMAppService 单一入口）+ `PlaySettings`（新增 `launchAtLogin` 字段）+ 本地化词条。菜单动态内容只依赖 `running`/`receivingOrWaiting`/`lanAddresses`，`objectWillChange` 回调改为差分比对后才重建菜单。

**Tech Stack:** Swift 5.9 / AppKit（NSStatusItem, NSSlider, NSPasteboard）/ ServiceManagement（SMAppService, macOS 14）/ Combine。

规格：`docs/superpowers/specs/2026-10-15-menubar-background-design.md`

---

## File Structure

| 文件 | 职责 | 改动 |
|---|---|---|
| `native/App/Localization.swift` | L() 词条表 | 新增 4 词条 + 1 正则 pattern |
| `native/App/MacPlay.swift` | PlayModel/PlaySettings | `launchAtLogin` 字段、`launchAtLoginEnabled`、`setLaunchAtLogin(_:)`、连接 Tab Toggle、`import ServiceManagement` |
| `native/App/ApplicationLifecycle.swift` | NSStatusItem 菜单 | 状态行、音量滑条、自启勾选、复制地址、NSMenuDelegate、updateMenus 差分节流 |

测试说明：本仓 SwiftUI/AppKit UI 代码无单测 harness（现有 `.test.swift` 仅覆盖纯逻辑如 ConnectionPolicy）。验证方式为 `swiftc -typecheck` 类型检查 + 完整构建 + 手动上车验证。每个 Task 结束必须通过 typecheck，然后 git commit（用户节奏：每任务一提交，全部完成后打包验证，确认后推送）。

类型检查命令（后续每步复用）：

```bash
cd /Users/yumikotoys/Downloads/MacPlay-CarBrowser && swiftc -parse-as-library -O -target arm64-apple-macosx14.0 -framework SwiftUI -framework AppKit -framework CoreWLAN -framework CoreLocation -framework IOKit -framework IOBluetooth -framework CoreAudio -framework MediaPlayer -typecheck native/App/MacPlay.swift native/App/ApplicationLifecycle.swift native/App/About.swift native/App/Localization.swift native/App/ConnectionPolicy.swift native/App/NowPlayingState.swift native/App/NowPlayingFeed.swift
```

预期输出：无输出、exit 0。

---

### Task 1: 本地化词条

**Files:**
- Modify: `native/App/Localization.swift:282-302`（translations 字典尾部，UI refresh 注释块附近）与 `native/App/Localization.swift:304-313`（patterns 数组）

- [ ] **Step 1: 在 translations 字典尾部（`"信息": ...` 行之后）新增词条**

```swift
        // Menu bar enhancement (2026-10): status line / launch-at-login / copy address.
        "● 接收中": ("● 接收中", "● Receiving"),
        "○ 未连接": ("○ 未連線", "○ Not Connected"),
        "登录时启动": ("登入時啟動", "Launch at Login"),
        "复制车机地址": ("複製車機位址", "Copy Car Browser Address"),
        "登录项注册失败": ("登入項註冊失敗", "Could not register login item"),
```

说明：`媒体音量`、`未连接` 已存在（L169、L285），不重复添加。状态行整体作为 key（含 ● / ○ 前缀），走 L() 精确匹配；带分钟数的动态串走 pattern。

- [ ] **Step 2: 在 patterns 数组尾部（`"会话 (\d+) 分钟"` 行之后）新增 pattern**

```swift
        (try! NSRegularExpression(pattern: "^● 接收中 · (\\d+)分钟$"), "● 接收中 · $1分鐘", "● Receiving · $1 min"),
```

- [ ] **Step 3: 类型检查通过**

Run: 上方类型检查命令
Expected: 无输出，exit 0

- [ ] **Step 4: Commit**

```bash
git add native/App/Localization.swift
git commit -m "feat(menubar): add status line, launch-at-login and copy-address localization entries"
```

---

### Task 2: 开机自启（PlaySettings + PlayModel + 连接 Tab Toggle）

**Files:**
- Modify: `native/App/MacPlay.swift:1-11`（import 区）
- Modify: `native/App/MacPlay.swift:117-161`（PlaySettings）
- Modify: `native/App/MacPlay.swift:363-400`（PlayModel，`applyLiveAudio` 与 `persistPreferences` 附近新增方法）
- Modify: `native/App/MacPlay.swift:1109-1121`（连接 Tab「应用」Section）

- [ ] **Step 1: 文件头 import 区新增 ServiceManagement**

在 `import MediaPlayer` 之后加：

```swift
import ServiceManagement
```

- [ ] **Step 2: PlaySettings 新增字段**

在 `var backgroundEnabled: Bool? = nil` 之后加：

```swift
    var launchAtLogin: Bool? = nil
```

说明：`Bool?` 保证旧 settings.json 解码兼容；nil 视为 false。UI 状态不信任此缓存，以 `SMAppService.mainApp.status` 为准（Step 3），此字段仅作信息落盘。

- [ ] **Step 3: PlayModel 新增状态读取与单一切换入口**

在 `func persistPreferences()` 之前插入：

```swift
    // Fork: launch-at-login. UI state always reads SMAppService directly —
    // never the settings cache. Settings toggle and menu bar checkbox both
    // route through this single entry point.
    var launchAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ enable: Bool) {
        let service = SMAppService.mainApp
        do {
            if enable {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            settings.launchAtLogin = enable
            persistPreferences()
        } catch {
            status = L("登录项注册失败")
            detail = error.localizedDescription
        }
        MacPlayApplicationDelegate.shared?.preferencesChanged()
    }
```

失败时经 `model.status` 提示（错误详情进 `detail`，与现有 status/detail 展示通道一致），并调 `preferencesChanged()` 刷新菜单勾选状态与 UI。

- [ ] **Step 4: 连接 Tab「应用」Section 新增 Toggle**

在 `Toggle(L("允许后台运行"),...)` 行之后加：

```swift
                            Toggle(L("登录时启动"),isOn:Binding(get:{model.launchAtLoginEnabled},set:{model.setLaunchAtLogin($0)}))
```

- [ ] **Step 5: 类型检查通过**

Run: 类型检查命令
Expected: 无输出，exit 0

- [ ] **Step 6: Commit**

```bash
git add native/App/MacPlay.swift
git commit -m "feat(menubar): launch-at-login via SMAppService with shared toggle entry point"
```

---

### Task 3: 菜单增强（状态行 / 音量滑条 / 自启勾选 / 复制地址）

**Files:**
- Modify: `native/App/ApplicationLifecycle.swift:4`（类声明，加 NSMenuDelegate）
- Modify: `native/App/ApplicationLifecycle.swift:9-13`（属性区）
- Modify: `native/App/ApplicationLifecycle.swift:60-107`（menu() 与 @objc actions）

- [ ] **Step 1: 类声明加 NSMenuDelegate**

```swift
@MainActor final class MacPlayApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
```

- [ ] **Step 2: 属性区新增状态行弱引用**

在 `private var statusItem: NSStatusItem?` 之后加：

```swift
    private weak var statusLineItem: NSMenuItem?
```

- [ ] **Step 3: 重写 menu() 并新增辅助方法与 actions**

将现有 `menu()`（L60-73）整体替换为：

```swift
    private func statusTitle() -> String {
        guard let model, model.running else {return L("○ 未连接")}
        if let start=model.sessionStart {
            let minutes=max(0,Int(Date().timeIntervalSince(start)/60))
            return L("● 接收中 · \(minutes)分钟")
        }
        return L("● 接收中")
    }
    private func menu() -> NSMenu {
        let menu=NSMenu()
        menu.delegate=self
        guard let model else {return menu}
        // Read-only status line; minutes refreshed on open (menuWillOpen).
        let statusLine=NSMenuItem(title:statusTitle(),action:nil,keyEquivalent:"")
        statusLine.isEnabled=false
        menu.addItem(statusLine)
        statusLineItem=statusLine
        menu.addItem(.separator())
        func item(_ title:String,_ action:Selector,enabled:Bool=true) {
            let item=NSMenuItem(title:L(title),action:action,keyEquivalent:"")
            item.target=self;item.isEnabled=enabled;menu.addItem(item)
        }
        item("显示NIO Play",#selector(showMain))
        item("显示CarPlay",#selector(showCarPlay),enabled:model.running)
        menu.addItem(.separator())
        if model.running {menu.addItem(volumeItem())}
        item(model.receivingOrWaiting ? "停止接收" : "启动接收",#selector(toggleReceiver))
        menu.addItem(.separator())
        let launchItem=NSMenuItem(title:L("登录时启动"),action:#selector(toggleLaunchAtLogin),keyEquivalent:"")
        launchItem.target=self
        launchItem.state=model.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)
        let copyItem=NSMenuItem(title:L("复制车机地址"),action:#selector(copyCarAddress),keyEquivalent:"")
        copyItem.target=self
        copyItem.isEnabled=model.lanAddresses.contains{$0.iphoneUSB == false}
        menu.addItem(copyItem)
        menu.addItem(.separator())
        item("退出NIO Play",#selector(quit))
        return menu
    }
    // View-based slider sharing the audio tab's exact channel:
    // settings.volume (0-1) + sendAudioCommand() per tick (no file write).
    private func volumeItem() -> NSMenuItem {
        let item=NSMenuItem(title:L("媒体音量"),action:nil,keyEquivalent:"")
        let container=NSView(frame:NSRect(x:0,y:0,width:240,height:24))
        let slider=NSSlider(value:(model?.settings.volume ?? 1)*100,minValue:0,maxValue:100,target:self,action:#selector(volumeChanged(_:)))
        slider.frame=NSRect(x:12,y:4,width:216,height:18)
        slider.isContinuous=true
        slider.setAccessibilityLabel(L("媒体音量"))
        container.addSubview(slider)
        item.view=container
        return item
    }
    @objc private func volumeChanged(_ sender:NSSlider) {
        guard let model else {return}
        model.settings.volume=sender.doubleValue/100
        model.sendAudioCommand()
    }
    @objc private func toggleLaunchAtLogin() {
        guard let model else {return}
        model.setLaunchAtLogin(!model.launchAtLoginEnabled)
    }
    @objc private func copyCarAddress() {
        guard let model,let address=model.lanAddresses.first(where:{$0.iphoneUSB == false})?.address else {return}
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://\(address):8443",forType:.string)
    }
    // MARK: NSMenuDelegate
    func menuWillOpen(_ menu:NSMenu) {statusLineItem?.title=statusTitle()}
    func menuDidClose(_ menu:NSMenu) {model?.persistPreferences()}
```

要点：
- 复制地址带 `:8443`（与连接 Tab 复制按钮惯例一致，规格中的裸地址是笔误）。
- 音量项仅 `running == true` 时插入，不显示灰滑条。
- `menu.delegate=self` 同时作用于状态栏菜单与 Dock 菜单（`applicationDockMenu` 复用 `menu()`）；`menuDidClose` 落盘最终音量，委托方法对两类菜单幂等。
- `NSControl.target` 为弱引用，`MacPlayApplicationDelegate` 是 NSApp 级长生命周期单例，无循环引用。

- [ ] **Step 4: 类型检查通过**

Run: 类型检查命令
Expected: 无输出，exit 0

- [ ] **Step 5: Commit**

```bash
git add native/App/ApplicationLifecycle.swift
git commit -m "feat(menubar): status line, volume slider, launch checkbox and copy-address menu items"
```

---

### Task 4: 后台性能修复（updateMenus 差分节流）

**Files:**
- Modify: `native/App/ApplicationLifecycle.swift:10-13`（属性区，新增缓存）
- Modify: `native/App/ApplicationLifecycle.swift:31-34`（install() 的 sink）
- Modify: `native/App/ApplicationLifecycle.swift:75`（updateMenus()）

- [ ] **Step 1: 属性区新增上次菜单内容缓存**

在 `private var statusLineItem` 之后加：

```swift
    // Last menu content cache — objectWillChange fires for every @Published
    // change (`logs` alone ticks many times/second while streaming); the menu
    // only depends on these three.
    private var lastMenuRunning=false
    private var lastMenuReceiving=false
    private var lastMenuAddressCount=0
    private var lastMenuAddressKey=""
```

- [ ] **Step 2: sink 改为差分判定**

将 install() 中：

```swift
            modelObservation=model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {self?.updateMenus()}
            }
```

改为：

```swift
            modelObservation=model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {self?.updateMenusIfNeeded()}
            }
```

- [ ] **Step 3: 新增 updateMenusIfNeeded()，updateMenus() 首行同步缓存**

将 `private func updateMenus() {statusItem?.menu=menu()}` 替换为：

```swift
    private func updateMenusIfNeeded() {
        guard let model else {return}
        guard model.running != lastMenuRunning
            || model.receivingOrWaiting != lastMenuReceiving
            || model.lanAddresses.count != lastMenuAddressCount
            || model.lanAddresses.first{$0.iphoneUSB == false}?.address != lastMenuAddressKey else {return}
        updateMenus()
    }
    private func updateMenus() {
        if let model {
            lastMenuRunning=model.running
            lastMenuReceiving=model.receivingOrWaiting
            lastMenuAddressCount=model.lanAddresses.count
            lastMenuAddressKey=model.lanAddresses.first{$0.iphoneUSB == false}?.address ?? ""
        }
        statusItem?.menu=menu()
    }
```

说明：`preferencesChanged()` 仍直接调 `updateMenus()`（显式路径不受节流影响），且首行同步缓存保证后续差分基线正确。状态行分钟数走 `menuWillOpen` 刷新，不需要定时器。

- [ ] **Step 4: 类型检查通过**

Run: 类型检查命令
Expected: 无输出，exit 0

- [ ] **Step 5: Commit**

```bash
git add native/App/ApplicationLifecycle.swift
git commit -m "perf(menubar): rebuild NSMenu only when displayed values actually change"
```

---

### Task 5: 构建与交付验证

**Files:** 无代码改动。

- [ ] **Step 1: 后台完整构建**

```bash
bash scripts/build-macplay.sh --arch=arm64
```

Run: 该命令（run_in_background，约 6 分钟）
Expected: exit 0，产物 `dist/NIOPlay-1.2.2-arm64.dmg`

- [ ] **Step 2: 交付用户上车验证**

验证清单（转述给用户）：
1. 菜单栏图标菜单：顶部状态行 `● 接收中 · N分钟` / `○ 未连接`
2. 接收中拖动音量滑条 → 车机音量即时变化，菜单关闭后重启 App 音量保留
3. 「登录时启动」菜单勾选与设置 Tab Toggle 双向一致，系统设置 → 通用 → 登录项同步出现/移除
4. 「复制车机地址」粘贴出来是 `https://<IP>:8443`；无可用地址时该项置灰
5. 性能：串流 + 关闭窗口后台运行，活动监视器 CPU 对比修复前

- [ ] **Step 3: 用户确认后推送**

```bash
git push origin web-streaming
```

---

## Self-Review 记录

- 规格覆盖：§1 状态行→Task 3；§2 音量滑条→Task 3；§3 开机自启→Task 2+3；§4 复制地址→Task 3；§5 性能修复→Task 4；§6 词条→Task 1。无遗漏。
- 占位符扫描：无 TBD/TODO，所有步骤含完整代码。
- 类型一致性：`launchAtLoginEnabled`/`setLaunchAtLogin(_:)`/`statusTitle()`/`volumeItem()`/`updateMenusIfNeeded()` 在 Task 2/3/4 间签名一致；词条 key 与代码中 L() 参数逐字一致（`● 接收中`、`○ 未连接`、`登录时启动`、`复制车机地址`、`登录项注册失败`、pattern `● 接收中 · N分钟`）。
- 已知规格偏差（有意）：复制地址带 `:8443`（对齐现有复制按钮惯例，规格笔误）；`menuDidClose` 落盘方式为整体 `persistPreferences()` 而非仅 volume（settings 是值类型整体编码，等价且更简单）。
