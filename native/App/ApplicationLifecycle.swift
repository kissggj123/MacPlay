import AppKit
import Combine

@MainActor final class MacPlayApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static weak var shared: MacPlayApplicationDelegate?
    private weak var model: PlayModel?
    private weak var mainWindow: NSWindow?
    private var openMainWindow: (() -> Void)?
    private var statusItem: NSStatusItem?
    private weak var statusLineItem: NSMenuItem?
    // Last menu content cache — objectWillChange fires for every @Published
    // change (`logs` alone ticks many times/second while streaming); the menu
    // only depends on these four.
    private var lastMenuRunning=false
    private var lastMenuReceiving=false
    private var lastMenuAddressCount=0
    private var lastMenuAddressKey=""
    private var lastMenuParamsKey=""
    private var modelObservation: AnyCancellable?
    private var windowObservation: NSObjectProtocol?
    private var terminating = false
    private var explicitWindowRequestUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared=self
        windowObservation=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeMainNotification,object:nil,queue:.main) { [weak self] notification in
            Task { @MainActor in
                guard let window=notification.object as? NSWindow,!(window is NSPanel),window.canBecomeMain else {return}
                self?.mainWindow=window
                window.delegate=self
            }
        }
    }

    func install(_ model: PlayModel, openMainWindow: @escaping () -> Void) {
        self.openMainWindow=openMainWindow
        Self.shared=self
        if self.model == nil {
            self.model=model
            modelObservation=model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async {self?.updateMenusIfNeeded()}
            }
        }
        if let window=NSApp.windows.first(where:{!($0 is NSPanel) && $0.canBecomeMain}) {
            mainWindow=window;window.delegate=self
        }
        preferencesChanged()
        model.enableAutomaticUSBStart()
    }

    func preferencesChanged() {
        guard let model else {return}
        model.persistPreferences()
        if model.settings.backgroundEnabled == true {
            if statusItem == nil {
                statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
                let image=NSImage(systemSymbolName:"car.fill",accessibilityDescription:"NIO Play")
                image?.isTemplate=true
                statusItem?.button?.image=image
                statusItem?.button?.toolTip="NIO Play"
            }
        } else if let item=statusItem {
            NSStatusBar.system.removeStatusItem(item);statusItem=nil
            if mainWindow?.isVisible != true {model.showMainWindow()}
        }
        updateMenus()
    }

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
        // Fork: parameter block + click-to-copy car addresses (tray menu and
        // Dock right-click share this builder, so both show them).
        func info(_ title:String) {
            let item=NSMenuItem(title:L(title),action:nil,keyEquivalent:"")
            item.isEnabled=false;menu.addItem(item)
        }
        let phoneID=model.settings.selectedPhone ?? model.settings.lastPhone
        if let phone=model.phoneChoices.first(where:{$0.id==phoneID}),model.receivingOrWaiting {
            info("iPhone：\(phone.name)")
        } else if !model.usbDevices.isEmpty {
            info("iPhone：\(model.usbDevices[0])")
        } else {
            info("iPhone：未检测到")
        }
        info(model.settings.wireless ? "连接：无线 · \(model.settings.ssid)" : "连接：有线 USB")
        info("画面：\(model.settings.width)×\(model.settings.height) · \(model.settings.fps)fps")
        info(pnpLine(model))
        let addresses=model.lanAddresses.filter{$0.iphoneUSB == false}
        if addresses.isEmpty {
            info("车机地址等待网络…")
        }
        for address in addresses {
            let prefix = address.name=="en0" ? "Wi-Fi " : (address.name=="mdns" ? ".local " : (address.name.hasPrefix("bridge") ? L("热点")+" " : address.name+" "))
            let url="https://\(address.address):8443"
            let item=NSMenuItem(title:prefix+url,action:#selector(copyAddressFromMenu(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=url
            item.toolTip=L("点击复制车机地址")
            menu.addItem(item)
        }
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
        let pnpItem=NSMenuItem(title:L("即插即用"),action:#selector(togglePlugAndPlay),keyEquivalent:"")
        pnpItem.target=self
        pnpItem.state=model.plugAndPlayEnabled ? .on : .off
        pnpItem.toolTip=L("插入iPhone后自动共享网络并阻止合盖睡眠")
        menu.addItem(pnpItem)
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
    // 即插即用 summary line; hotspot name is re-read so an externally toggled
    // sharing state doesn't linger in the menu.
    private func pnpLine(_ model: PlayModel) -> String {
        if model.plugAndPlayBusy {return "即插即用：配置中…"}
        if model.plugAndPlayActive {
            let name=PlugAndPlayCore.natConfigNow().networkName
            return name.isEmpty ? "即插即用：已开启" : "即插即用：热点 \(name)"
        }
        return model.plugAndPlayEnabled ? "即插即用：待iPhone插入" : "即插即用：未开启"
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
    @objc private func copyAddressFromMenu(_ sender:NSMenuItem) {
        guard let url=sender.representedObject as? String else {return}
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url,forType:.string)
    }
    @objc private func togglePlugAndPlay() {
        guard let model else {return}
        model.setPlugAndPlay(!model.plugAndPlayEnabled)
    }
    // MARK: NSMenuDelegate
    func menuWillOpen(_ menu:NSMenu) {
        statusLineItem?.title=statusTitle()
        // Addresses move when the shared hotspot assigns DHCP; the 10s timer
        // only runs while the settings window exists, so refresh on open too.
        model?.refreshLanInfo(refreshFirewall:false)
    }
    func menuDidClose(_ menu:NSMenu) {model?.persistPreferences()}

    private func updateMenusIfNeeded() {
        guard let model else {return}
        guard model.running != lastMenuRunning
            || model.receivingOrWaiting != lastMenuReceiving
            || model.lanAddresses.count != lastMenuAddressCount
            || model.lanAddresses.first(where:{$0.iphoneUSB == false})?.address != lastMenuAddressKey
            || paramsKey(model) != lastMenuParamsKey else {return}
        updateMenus()
    }
    // Everything the parameter block renders — phone, link, video geometry,
    // plug-and-play state — so streaming-time @Published churn can't rebuild
    // the menu unless one of these actually moved.
    private func paramsKey(_ model: PlayModel) -> String {
        "\(model.settings.selectedPhone ?? model.settings.lastPhone ?? "")|\(model.usbDevices.joined(separator:","))|\(model.settings.wireless)|\(model.settings.ssid)|\(model.settings.width)x\(model.settings.height)|\(model.settings.fps)|\(model.plugAndPlayEnabled)|\(model.plugAndPlayActive)|\(model.plugAndPlayBusy)|\(model.plugAndPlayStatus)"
    }
    private func updateMenus() {
        if let model {
            lastMenuRunning=model.running
            lastMenuReceiving=model.receivingOrWaiting
            lastMenuAddressCount=model.lanAddresses.count
            lastMenuAddressKey=model.lanAddresses.first{$0.iphoneUSB == false}?.address ?? ""
            lastMenuParamsKey=paramsKey(model)
        }
        statusItem?.menu=menu()
    }
    func applicationDockMenu(_ sender:NSApplication) -> NSMenu? {menu()}
    @objc private func showMain() {
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        model?.showMainWindow()
    }
    func restoreMainWindow() -> Bool {
        guard let openMainWindow else {return false}
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        // SwiftUI can dispose of a closed Window scene. Asking the scene to open
        // also recreates it; enumerating NSApp.windows cannot restore that case.
        openMainWindow()
        NSApp.activate()
        if let window=mainWindow,NSApp.windows.contains(where:{$0 === window}) {
            if window.isMiniaturized {window.deminiaturize(nil)}
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
    @objc private func showCarPlay() {model?.showCarPlayWindow()}
    func prepareCarPlayPresentation() {
        explicitWindowRequestUntil=Date().addingTimeInterval(1)
        // Ordering a minimized window can restore it. Keep the main window's
        // minimized/hidden state when the user only requests the CarPlay window.
        if let window=mainWindow,window.isVisible,!window.isMiniaturized {
            window.orderBack(nil)
        }
    }
    @objc private func toggleReceiver() {
        guard let model else {return}
        if model.receivingOrWaiting {model.stop()} else {model.start()}
    }
    @objc private func quit() {NSApp.terminate(nil)}

    func windowShouldClose(_ sender:NSWindow) -> Bool {
        guard sender === mainWindow,!terminating else {return true}
        if model?.settings.backgroundEnabled == true {
            sender.orderOut(nil)
        } else {NSApp.terminate(nil)}
        return false
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        // A Dock menu selection may also generate a reopen event. Preserve its target.
        guard Date() > explicitWindowRequestUntil else {return false}
        model?.showMainWindow();return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {false}
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        terminating=true
        model?.stop(restoreMain:false)
        // 即插即用还开着：先还原共享与休眠设置再退出（弹一次管理员授权）。
        // 授权被取消时快照保留，下次启动会再次尝试自动恢复。
        if let model,model.plugAndPlayActive,!model.plugAndPlayBusy {
            model.revertBeforeQuit { NSApp.reply(toApplicationShouldTerminate:true) }
            return .terminateLater
        }
        return .terminateNow
    }
}
